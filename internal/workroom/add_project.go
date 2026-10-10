package workroom

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/vcs"
)

// AddProjectResult is the project AddProject registered, or would register under Pretend.
type AddProjectResult struct {
	Path string
	VCS  string
	// WouldCreate reports, under Pretend, whether AddProject would make the directory.
	WouldCreate bool
}

// AddProject registers an empty project (one with no workrooms yet) so the macOS app's sidebar can
// show it. It refuses a remote path, then registers the local one.
//
// By default path must already be a Git repo (repo-only). With create, a missing directory is
// created and git-initialized so it is immediately usable as a project — see addCreatedProject.
// Under Pretend nothing is written: the result reports what would be registered.
func (s *Service) AddProject(path string, create bool) (AddProjectResult, error) {
	// Before canonicalizing, which would turn "host:repo" into "<cwd>/host:repo".
	if isRemotePath(path) {
		return AddProjectResult{}, fmt.Errorf("%w: %s", errs.ErrRemoteProject, path)
	}
	canon, err := config.CanonicalPath(path)
	if err != nil {
		return AddProjectResult{}, err
	}
	if create {
		return s.addCreatedProject(canon)
	}
	return s.addExistingProject(canon)
}

// isRemotePath reports whether p names a location on another machine: a URL (ssh://host/repo) or
// scp-style host:path. It is git's own test: a colon before the first slash, which an absolute,
// "~/" or "./" path never has.
func isRemotePath(p string) bool {
	if strings.Contains(p, "://") {
		return true
	}
	colon := strings.IndexByte(p, ':')
	slash := strings.IndexByte(p, '/')
	return colon > 0 && (slash == -1 || colon < slash)
}

// addExistingProject is the default (repo-only) path: canon must already be a Git repo, else
// ErrUnsupportedVCS. Detection still runs under Pretend (so a bad path still errors), but the
// config write is skipped, mirroring addCreatedProject's Pretend contract.
func (s *Service) addExistingProject(canon string) (AddProjectResult, error) {
	v, err := vcs.Detect(canon) // rejects non-VCS directories with ErrUnsupportedVCS
	if err != nil {
		return AddProjectResult{}, err
	}
	res := AddProjectResult{Path: canon, VCS: string(v.Type())}

	if s.Pretend {
		return res, nil
	}

	if err := s.Config.AddProject(canon, res.VCS); err != nil {
		return AddProjectResult{}, err
	}
	return res, nil
}

// addCreatedProject handles `add-project --create`: it resolves canon to a usable Workroom
// project, creating and git-initializing the directory when it does not yet exist.
//
//	stat(canon)
//	 ├── exists && !IsDir ─────────────► ErrNotDirectory
//	 ├── !exists ──► MkdirAll(0o755)               (created = true)
//	 │                 └─ ENOTDIR ──────► ErrNotDirectory   (a file in a parent component)
//	 │                 └─ re-canonicalize (now the dir exists, resolve symlinks)
//	 └── exists && IsDir ──────────────┐
//	                                   ▼
//	                             Detect(canon)
//	                              ├── ok (git repo) ─► register, no init
//	                              └── not a repo
//	                                   ├── empty* ─► git init + initial commit ─► register git
//	                                   └── non-empty ──────────► ErrUnsupportedVCS
//	    (*empty ignores .DS_Store / .localized — a Finder-touched folder still counts as empty)
//
// On any error after we created the directory it is removed, so a retry starts clean; a
// pre-existing directory is never removed. Under Pretend nothing is mutated: it reports the action
// that would be taken and returns.
func (s *Service) addCreatedProject(canon string) (_ AddProjectResult, retErr error) {
	info, statErr := os.Stat(canon)
	switch {
	case statErr == nil && !info.IsDir():
		return AddProjectResult{}, errs.ErrNotDirectory
	case statErr != nil && errors.Is(statErr, syscall.ENOTDIR):
		// A parent component is a file (e.g. /some/file/child): not a directory.
		return AddProjectResult{}, errs.ErrNotDirectory
	case statErr != nil && !os.IsNotExist(statErr):
		return AddProjectResult{}, statErr
	}
	exists := statErr == nil

	if s.Pretend {
		vcsType := "git"
		if exists {
			if v, err := vcs.Detect(canon); err == nil {
				vcsType = string(v.Type())
			}
		}
		return AddProjectResult{Path: canon, VCS: vcsType, WouldCreate: !exists}, nil
	}

	created := false
	if !exists {
		if err := os.MkdirAll(canon, 0o755); err != nil {
			if errors.Is(err, syscall.ENOTDIR) {
				return AddProjectResult{}, errs.ErrNotDirectory
			}
			return AddProjectResult{}, fmt.Errorf("%w: create directory %s: %v", errs.ErrConfigWrite, canon, err)
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
			return AddProjectResult{}, err
		}
		if !empty {
			return AddProjectResult{}, errs.ErrUnsupportedVCS
		}
		if err := vcs.InitGit(canon); err != nil {
			return AddProjectResult{}, fmt.Errorf("%w: git init %s: %v", errs.ErrVCSCommand, canon, err)
		}
		if v, detErr = vcs.Detect(canon); detErr != nil {
			return AddProjectResult{}, detErr
		}
	}

	vcsType := string(v.Type())
	if err := s.Config.AddProject(canon, vcsType); err != nil {
		return AddProjectResult{}, err
	}

	return AddProjectResult{Path: canon, VCS: vcsType}, nil
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
