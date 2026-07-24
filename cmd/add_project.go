package cmd

import (
	"errors"
	"fmt"
	"io"
	"os"
	"syscall"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

// addProjectCreate backs the --create flag: when set, add-project will create
// (and git-initialize) the directory if it does not already exist, instead of
// requiring an existing Git/JJ repo. Set per-invocation by the macOS app's
// "Create new directory…" mode (issue #103).
var addProjectCreate bool

// addProjectCmd is an internal, app-only command: it registers an empty project
// (one with no workrooms yet) so the macOS app's sidebar can show it. The human
// CLI never needs it — `create` auto-registers a project on first use, and the
// human `list` only shows projects that have workrooms — so it is hidden and
// available solely in --json mode, which is how the app invokes it.
//
// By default the PATH must already be a Git/JJ repo (repo-only). With --create,
// a missing directory is created and git-initialized so it is immediately usable
// as a project — see runAddProjectCreate.
var addProjectCmd = &cobra.Command{
	Use:    "add-project [PATH]",
	Short:  "Register a project (internal; used by the macOS app via --json)",
	Hidden: true,
	Args:   cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "add-project"
		if !jsonOutput {
			return fmt.Errorf("add-project is only available in --json mode")
		}
		svc, err := newService()
		if err != nil {
			return err
		}
		if len(args) != 1 {
			return fmt.Errorf("a path argument is required")
		}

		canon, err := config.CanonicalPath(args[0])
		if err != nil {
			return err
		}

		if addProjectCreate {
			return runAddProjectCreate(svc, canon, os.Stdout)
		}
		return runAddProjectExisting(svc, canon, os.Stdout)
	},
}

// runAddProjectExisting is the default (repo-only) path: PATH must already be a
// Git/JJ repo, else ErrUnsupportedVCS. Detection still runs under --pretend (so
// a bad path still errors), but the config write is skipped and a dry-run
// envelope is reported instead, mirroring runAddProjectCreate's --pretend
// contract.
func runAddProjectExisting(svc *workroom.Service, canon string, out io.Writer) error {
	v, err := vcs.Detect(canon) // rejects non-VCS directories with ErrUnsupportedVCS
	if err != nil {
		return err
	}
	vcsType := string(v.Type())

	if pretend {
		return writeJSONSuccess(out, "add-project", map[string]any{
			"path": canon, "vcs": vcsType, "would_create": false,
		})
	}

	if err := svc.Config.AddProject(canon, vcsType); err != nil {
		return err
	}
	return writeJSONSuccess(out, "add-project", map[string]any{
		"path": canon, "vcs": vcsType,
	})
}

// runAddProjectCreate handles `add-project --create`: it resolves PATH to a
// usable Workroom project, creating and git-initializing the directory when it
// does not yet exist.
//
//	stat(canon)
//	 ├── exists && !IsDir ─────────────► ErrNotDirectory
//	 ├── !exists ──► MkdirAll(0o755)               (created = true)
//	 │                 └─ ENOTDIR ──────► ErrNotDirectory   (a file in a parent component)
//	 │                 └─ re-canonicalize (now the dir exists, resolve symlinks)
//	 └── exists && IsDir ──────────────┐
//	                                   ▼
//	                             Detect(canon)
//	                              ├── ok (git|jj repo) ─► register, no init
//	                              └── not a repo
//	                                   ├── empty* ─► git init + initial commit ─► register git
//	                                   └── non-empty ──────────► ErrUnsupportedVCS
//	    (*empty ignores .DS_Store / .localized — a Finder-touched folder still counts as empty)
//
// On any error after we created the directory it is removed, so a retry starts
// clean; a pre-existing directory is never removed. With --pretend nothing is
// mutated: it reports the action that would be taken and returns.
func runAddProjectCreate(svc *workroom.Service, canon string, out io.Writer) (retErr error) {
	info, statErr := os.Stat(canon)
	switch {
	case statErr == nil && !info.IsDir():
		return errs.ErrNotDirectory
	case statErr != nil && errors.Is(statErr, syscall.ENOTDIR):
		// A parent component is a file (e.g. /some/file/child): not a directory.
		return errs.ErrNotDirectory
	case statErr != nil && !os.IsNotExist(statErr):
		return statErr
	}
	exists := statErr == nil

	if pretend {
		vcsType := "git"
		if exists {
			if v, err := vcs.Detect(canon); err == nil {
				vcsType = string(v.Type())
			}
		}
		return writeJSONSuccess(out, "add-project", map[string]any{
			"path": canon, "vcs": vcsType, "would_create": !exists,
		})
	}

	created := false
	if !exists {
		if err := os.MkdirAll(canon, 0o755); err != nil {
			if errors.Is(err, syscall.ENOTDIR) {
				return errs.ErrNotDirectory
			}
			return fmt.Errorf("%w: create directory %s: %v", errs.ErrConfigWrite, canon, err)
		}
		created = true
		// The directory now exists, so re-resolve it: a path under a symlinked
		// parent must be stored in its symlink-evaluated form, matching how an
		// existing project's path is canonicalized.
		if resolved, err := config.CanonicalPath(canon); err == nil {
			canon = resolved
		}
	}

	// Roll back the directory we created on any failure past this point so a
	// retry starts from a clean slate (e.g. an aborted init must not leave a
	// committed-less repo that Detect would later treat as a valid project).
	defer func() {
		if retErr != nil && created {
			_ = os.RemoveAll(canon)
		}
	}()

	v, detErr := vcs.Detect(canon)
	if detErr != nil {
		// Not a repo. Initialize Git only when the directory is empty (newly
		// created, or a pre-existing empty/junk-only folder); never init over
		// existing files.
		empty, err := dirIsEmpty(canon)
		if err != nil {
			return err
		}
		if !empty {
			return errs.ErrUnsupportedVCS
		}
		if err := vcs.InitGit(canon); err != nil {
			return fmt.Errorf("%w: git init %s: %v", errs.ErrVCSCommand, canon, err)
		}
		if v, detErr = vcs.Detect(canon); detErr != nil {
			return detErr
		}
	}

	vcsType := string(v.Type())
	if err := svc.Config.AddProject(canon, vcsType); err != nil {
		return err
	}

	return writeJSONSuccess(out, "add-project", map[string]any{
		"path": canon, "vcs": vcsType,
	})
}

// dirIsEmpty reports whether dir contains no entries other than ignorable macOS
// junk (.DS_Store, .localized), so a folder created or visited in Finder still
// counts as empty for the git-init gate.
func dirIsEmpty(dir string) (bool, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false, err
	}
	for _, e := range entries {
		switch e.Name() {
		case ".DS_Store", ".localized":
			continue
		default:
			return false, nil
		}
	}
	return true, nil
}

func init() {
	addProjectCmd.Flags().BoolVar(&addProjectCreate, "create", false,
		"Create and git-initialize the directory if it does not already exist")
	rootCmd.AddCommand(addProjectCmd)
}
