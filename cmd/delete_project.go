package cmd

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

var (
	deleteProjectConfirm  string
	deleteProjectWithWR   bool
	deleteProjectFromDisk bool
)

// deleteProjectCmd is an internal, app-only command: it removes a project from the
// config so the macOS app's sidebar can drop it. The human CLI never needs it — a
// project disappears on its own once its last workroom is deleted — so it is hidden
// and available solely in --json mode, which is how the app invokes it.
//
// By default it is strictly config-only: the project entry is deleted and NOTHING on
// disk is touched (worktree directories, branches, and files all stay). With
// --with-workrooms it first tears down every registered workroom (the same per-
// workroom teardown the `delete` command runs: teardown script + VCS worktree/
// workspace removal + dir cleanup, streaming NDJSON logs), then removes the project.
// Branches/bookmarks are never deleted in either mode — the cascade reuses
// Service.Delete, whose VCS removal (`git worktree remove`)
// leaves refs intact.
//
// With --from-disk the CLI runs teardown scripts and drops the project from config,
// then returns the list of paths the macOS app should move to the Trash. The app
// handles the actual filesystem removal; the CLI never deletes directories itself in
// this mode.
var deleteProjectCmd = &cobra.Command{
	Use:    "delete-project [PATH]",
	Short:  "Remove a project (internal; used by the macOS app via --json)",
	Hidden: true,
	Args:   cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "delete-project"
		svc, err := newService()
		if err != nil {
			return err
		}
		return runDeleteProject(svc, jsonOutput, deleteProjectConfirm, deleteProjectWithWR, deleteProjectFromDisk, args, os.Stdout, os.Stderr)
	},
}

// runDeleteProject holds the command body, decoupled from cobra globals and os
// streams so it is unit-testable with an injected Service (temp config + mock VCS).
// stdout receives the single JSON success envelope; logSink receives NDJSON teardown
// log events during a cascade.
func runDeleteProject(svc *workroom.Service, jsonMode bool, confirm string, withWorkrooms bool, fromDisk bool, args []string, stdout, logSink io.Writer) error {
	if !jsonMode {
		return fmt.Errorf("delete-project is only available in --json mode")
	}
	if len(args) != 1 {
		return fmt.Errorf("a path argument is required")
	}
	path := args[0]

	// Canonicalize WITHOUT vcs.Detect so a stale or moved project (whose directory
	// no longer exists or is no longer a VCS repo) is still removable from config.
	// CanonicalPath falls back to the absolute path when the dir is absent. The
	// --confirm value must match either form.
	canon, err := config.CanonicalPath(path)
	if err != nil {
		canon = path
	}
	if confirm != canon && confirm != path {
		return fmt.Errorf("%w: --confirm <path> is required and must match the project path", errs.ErrConfirmMismatch)
	}

	// Refused in every mode, before anything is torn down. --from-disk's safety gate reasons
	// about local paths and --with-workrooms tears down locally; the config-only mode would drop
	// the only record of a remote machine. Remote deletion is its own path (#253).
	if err := refuseRemoteProject(svc.Config, canon); err != nil {
		return err
	}

	if fromDisk {
		// Guard: refuse obviously dangerous paths.
		unsafe, err := unsafeProjectDeletePath(canon, svc.Config)
		if err != nil {
			return err
		}
		if unsafe {
			return fmt.Errorf("%w: refusing to delete %q", errs.ErrUnsafeDeletePath, canon)
		}

		// Collect trash paths: project root first, then workroom paths sorted ascending.
		names, err := svc.Config.WorkroomNames(canon)
		if err != nil {
			return err
		}
		// Pull the stored path for each workroom from config.
		data, err := svc.Config.Read()
		if err != nil {
			return err
		}
		wroomPaths := make([]string, 0, len(names))
		if proj, ok := data[canon].(map[string]any); ok {
			if workrooms, ok := proj["workrooms"].(map[string]any); ok {
				for _, name := range names {
					if entry, ok := workrooms[name].(map[string]any); ok {
						if p, ok := entry["path"].(string); ok && p != "" {
							wroomPaths = append(wroomPaths, p)
						}
					}
				}
			}
		}
		sort.Strings(wroomPaths)
		trashPaths := append([]string{canon}, wroomPaths...)

		// Run teardown scripts. On any failure, flush and return — nothing is removed
		// from config so the operation is retryable.
		logWriter := newJSONLogWriter(logSink, "teardown")
		svc.ScriptLogWriter = logWriter
		for _, name := range names {
			if err := refuseRemoteProject(svc.Config, canon); err != nil {
				logWriter.Flush()
				return err
			}
			if err := svc.RunTeardown(canon, name); err != nil {
				logWriter.Flush()
				return err
			}
		}
		logWriter.Flush()

		// Drop from config.
		if err := svc.Config.RemoveProject(canon); err != nil {
			return err
		}

		return writeJSONSuccess(stdout, "delete-project", map[string]any{
			"path":        canon,
			"from_disk":   true,
			"trash_paths": trashPaths,
		})
	}

	if withWorkrooms {
		// Cascade: tear down each workroom in full, streaming teardown output as
		// NDJSON log events on logSink (exactly like `delete`). On the first failure,
		// leave the project in config so the user can retry — workrooms torn down
		// before the failure are gone (same as manual per-workroom deletes), and the
		// error log shows how far it got.
		names, err := svc.Config.WorkroomNames(canon)
		if err != nil {
			return err
		}
		logWriter := newJSONLogWriter(logSink, "teardown")
		svc.ScriptLogWriter = logWriter
		for _, name := range names {
			// Again before each workroom: a descriptor written during the cascade (a base
			// recorded) stops it here rather than after every workroom has gone.
			// RemoveProject checks once more under its own lock; only a descriptor written
			// during one workroom's teardown gets past these.
			if err := refuseRemoteProject(svc.Config, canon); err != nil {
				logWriter.Flush()
				return err
			}
			if err := svc.Delete(canon, name, name); err != nil {
				logWriter.Flush()
				return err
			}
		}
		logWriter.Flush()
	}

	if err := svc.Config.RemoveProject(canon); err != nil {
		return err
	}

	return writeJSONSuccess(stdout, "delete-project", map[string]any{
		"path": canon, "with_workrooms": withWorkrooms,
	})
}

// unsafeProjectDeletePath returns true when canon looks dangerous to delete: empty,
// not absolute, root ("/"), the user home directory, equal to workrooms_dir, or an
// ancestor of another registered project or of workrooms_dir. Returns an error only
// when a config or home-dir lookup itself fails.
func unsafeProjectDeletePath(canon string, cfg *config.Config) (bool, error) {
	if canon == "" || !filepath.IsAbs(canon) || canon == "/" {
		return true, nil
	}
	// Canonicalize defensively so symlink-heavy paths (e.g. /var → /private/var on
	// macOS) compare correctly against config keys and other canonical paths.
	if resolved, err := config.CanonicalPath(canon); err == nil {
		canon = resolved
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return false, fmt.Errorf("determine home directory: %w", err)
	}
	homeCanon, _ := config.CanonicalPath(home)
	if canon == homeCanon || canon == home {
		return true, nil
	}

	workroomsDir, err := cfg.WorkroomsDir()
	if err != nil {
		return false, err
	}
	workroomsDirCanon, _ := config.CanonicalPath(workroomsDir)

	// Refuse exact equality with workrooms_dir.
	if canon == workroomsDirCanon || canon == workroomsDir {
		return true, nil
	}
	// Refuse being an ancestor of workrooms_dir.
	if isAncestor(canon, workroomsDirCanon) {
		return true, nil
	}

	// Check against other registered projects. A scalar setting's key (base_branch) is no path:
	// taken as one, it resolves under the current directory.
	projects, err := cfg.AllProjects()
	if err != nil {
		return false, err
	}
	for key := range projects {
		if key == canon {
			continue
		}
		otherCanon, _ := config.CanonicalPath(key)
		// Refuse exact equality with another project.
		if canon == otherCanon {
			return true, nil
		}
		// Refuse being an ancestor of another registered project.
		if isAncestor(canon, otherCanon) {
			return true, nil
		}
	}

	return false, nil
}

// isAncestor reports whether parent is a strict ancestor directory of child
// (i.e. child lives under parent, but parent != child).
func isAncestor(parent, child string) bool {
	rel, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	return rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func init() {
	deleteProjectCmd.Flags().StringVar(&deleteProjectConfirm, "confirm", "", "Required in --json mode; must match the project path")
	deleteProjectCmd.Flags().BoolVar(&deleteProjectWithWR, "with-workrooms", false, "Also tear down every workroom (worktree dirs + files; branches kept)")
	deleteProjectCmd.Flags().BoolVar(&deleteProjectFromDisk, "from-disk", false, "App-only: runs teardowns, drops config, returns trash_paths; the caller (macOS app) moves those dirs to the Trash")
	rootCmd.AddCommand(deleteProjectCmd)
}

// refuseRemoteProject refuses a project with remote workrooms, or with its own descriptor, which
// records its base machine (#252): either is the only record of a remote machine.
func refuseRemoteProject(cfg *config.Config, canon string) error {
	projects, err := cfg.AllProjects()
	if err != nil {
		return err
	}
	if remote := projects[canon].RemoteWorkroomNames(); len(remote) > 0 {
		return fmt.Errorf("%w: %s has remote workrooms: %s", errs.ErrRemoteWorkroom, canon, strings.Join(remote, ", "))
	}
	if projects[canon].Host != nil {
		return fmt.Errorf("%w: %s has a remote host (its base machine)", errs.ErrRemoteWorkroom, canon)
	}
	return nil
}
