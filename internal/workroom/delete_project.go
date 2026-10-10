package workroom

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
)

// DeleteProjectResult is the project DeleteProject removed from config.
type DeleteProjectResult struct {
	Path string
	// TrashPaths, set only with fromDisk, are the directories the caller moves to the Trash: the
	// project root first, then its workrooms sorted.
	TrashPaths []string
}

// DeleteProject removes a project from the config so the macOS app's sidebar can drop it.
//
// By default it is strictly config-only: the project entry is deleted and NOTHING on disk is
// touched (worktree directories, branches, and files all stay). With withWorkrooms it first tears
// down every registered workroom (the same per-workroom teardown Delete runs: teardown script + VCS
// worktree removal + dir cleanup, streaming script output to ScriptLogWriter), then removes the
// project. Branches are never deleted in either mode: the cascade reuses Delete, whose VCS removal
// (`git worktree remove`) leaves refs intact.
//
// With fromDisk it runs teardown scripts and drops the project from config, then returns the paths
// the caller should move to the Trash. The caller handles the actual filesystem removal; this
// never deletes directories itself in that mode. fromDisk wins over withWorkrooms.
//
// confirm must match path, canonical or as given.
func (s *Service) DeleteProject(path, confirm string, withWorkrooms, fromDisk bool) (DeleteProjectResult, error) {
	// Canonicalize WITHOUT vcs.Detect so a stale or moved project (whose directory
	// no longer exists or is no longer a VCS repo) is still removable from config.
	// CanonicalPath falls back to the absolute path when the dir is absent. The
	// confirm value must match either form.
	canon, err := config.CanonicalPath(path)
	if err != nil {
		canon = path
	}
	if confirm != canon && confirm != path {
		return DeleteProjectResult{}, fmt.Errorf("%w: --confirm <path> is required and must match the project path", errs.ErrConfirmMismatch)
	}

	// Refused in every mode, before anything is torn down. fromDisk's safety gate reasons
	// about local paths and withWorkrooms tears down locally; the config-only mode would drop
	// the only record of a remote machine. Remote deletion is its own path (#253).
	if err := refuseRemoteProject(s.Config, canon); err != nil {
		return DeleteProjectResult{}, err
	}

	if fromDisk {
		// Guard: refuse obviously dangerous paths.
		unsafe, err := unsafeProjectDeletePath(canon, s.Config)
		if err != nil {
			return DeleteProjectResult{}, err
		}
		if unsafe {
			return DeleteProjectResult{}, fmt.Errorf("%w: refusing to delete %q", errs.ErrUnsafeDeletePath, canon)
		}

		// Collect trash paths: project root first, then workroom paths sorted ascending.
		names, err := s.Config.WorkroomNames(canon)
		if err != nil {
			return DeleteProjectResult{}, err
		}
		// Pull the stored path for each workroom from config.
		data, err := s.Config.Read()
		if err != nil {
			return DeleteProjectResult{}, err
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

		// Run teardown scripts. On any failure, return: nothing is removed from config so the
		// operation is retryable.
		for _, name := range names {
			if err := refuseRemoteProject(s.Config, canon); err != nil {
				return DeleteProjectResult{}, err
			}
			if err := s.RunTeardown(canon, name); err != nil {
				return DeleteProjectResult{}, err
			}
		}

		// Drop from config.
		if err := s.Config.RemoveProject(canon); err != nil {
			return DeleteProjectResult{}, err
		}
		return DeleteProjectResult{Path: canon, TrashPaths: trashPaths}, nil
	}

	if withWorkrooms {
		// Cascade: tear down each workroom in full (exactly like Delete). On the first failure,
		// leave the project in config so the user can retry — workrooms torn down before the
		// failure are gone (same as manual per-workroom deletes), and the log shows how far it
		// got.
		names, err := s.Config.WorkroomNames(canon)
		if err != nil {
			return DeleteProjectResult{}, err
		}
		for _, name := range names {
			// Again before each workroom: a descriptor written during the cascade (a base
			// recorded) stops it here rather than after every workroom has gone.
			// RemoveProject checks once more under its own lock; only a descriptor written
			// during one workroom's teardown gets past these.
			if err := refuseRemoteProject(s.Config, canon); err != nil {
				return DeleteProjectResult{}, err
			}
			if _, err := s.Delete(canon, name, name); err != nil {
				return DeleteProjectResult{}, err
			}
		}
	}

	if err := s.Config.RemoveProject(canon); err != nil {
		return DeleteProjectResult{}, err
	}
	return DeleteProjectResult{Path: canon}, nil
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
