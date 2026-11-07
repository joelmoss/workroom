package workroom

import (
	"fmt"
	"strings"

	"github.com/joelmoss/workroom/internal/script"
	"github.com/joelmoss/workroom/internal/vcs"
)

// DeleteOutcome is what Delete did with a workroom.
type DeleteOutcome int

const (
	// Deleted: its teardown ran, its worktree is removed and its entry dropped. Its branch is kept.
	Deleted DeleteOutcome = iota
	// ForgotDestroyedRemote: a remote workroom whose host is gone. Only its entry is dropped.
	ForgotDestroyedRemote
	// ForgotNonGit: not a git worktree. Only its entry is dropped; its folder is left at Path.
	ForgotNonGit
	// Declined: the user declined to confirm, so nothing was done.
	Declined
)

// DeleteResult is what Delete did with workroom Name.
type DeleteResult struct {
	Name    string
	Outcome DeleteOutcome
	// Branch is the git branch a Deleted workroom leaves behind.
	Branch string
	// Path is where a ForgotNonGit workroom's folder was left.
	Path string
}

// Delete removes a workroom by name, asking ConfirmFn first unless confirmValue names it.
func (s *Service) Delete(dir, name, confirmValue string) (DeleteResult, error) {
	if err := s.CheckNotInWorkroom(dir); err != nil {
		return DeleteResult{}, err
	}

	if !validNameRe.MatchString(name) {
		return DeleteResult{}, fmt.Errorf("%w: %q", ErrInvalidName, name)
	}

	destroyed, err := s.destroyedRemote(dir, name)
	if err != nil {
		return DeleteResult{}, err
	}

	// A destroyed remote workroom is only dropped from config, which needs no local repository: the
	// project's checkout may be gone by then.
	if !destroyed {
		if err := s.detectVCS(dir); err != nil {
			return DeleteResult{}, err
		}
	}

	orphan := ""
	if !s.Pretend {
		exists := destroyed
		if !destroyed {
			if exists, err = s.workroomExists(dir, name); err != nil {
				return DeleteResult{}, err
			}
		}
		if !exists {
			orphan, err = s.nonGitWorkroomPath(dir, name)
			if err != nil {
				return DeleteResult{}, err
			}
			if orphan == "" {
				return DeleteResult{}, fmt.Errorf("%w: %s '%s' does not exist", ErrGitWorktreeNotFound, s.VCS.Label(), name)
			}
		}

		if confirmValue != "" {
			if confirmValue != name {
				return DeleteResult{}, fmt.Errorf("%w: --confirm value '%s' does not match workroom name '%s'", ErrConfirmMismatch, confirmValue, name)
			}
		} else {
			confirmed, err := s.ConfirmFn(fmt.Sprintf("Are you sure you want to delete workroom '%s'?", name))
			if err != nil {
				return DeleteResult{}, err
			}
			if !confirmed {
				return DeleteResult{Name: name, Outcome: Declined}, nil
			}
		}
	}

	if orphan != "" {
		return s.forgetNonGitWorkroom(dir, name, orphan)
	}
	return s.deleteByName(dir, name)
}

// legacyWorkroomPath is nonGitWorkroomPath for a workroom git does not list as a worktree, or ""
// when git lists it (an ordinary worktree, deleted the usual way).
func (s *Service) legacyWorkroomPath(dir, name string) (string, error) {
	exists, err := s.workroomExists(dir, name)
	if err != nil || exists {
		return "", err
	}
	return s.nonGitWorkroomPath(dir, name)
}

// nonGitWorkroomPath returns the recorded path of workroom name when it is registered for project
// dir but its folder holds no .git: a workspace Jujutsu made before Workroom dropped it (#266).
// Returns "" when the workroom is unregistered or its folder is a git checkout.
func (s *Service) nonGitWorkroomPath(dir, name string) (string, error) {
	projects, err := s.Config.AllProjects()
	if err != nil {
		return "", err
	}
	wr, ok := projects[dir].Workrooms[name]
	// A remote workroom's path is on its host, so its absent local .git says nothing about it.
	if !ok || wr.Path == "" || wr.IsRemote() {
		return "", nil
	}
	if vcs.IsGitRepo(wr.Path) {
		return "", nil
	}
	return wr.Path, nil
}

// forgetNonGitWorkroom removes a non-git workroom's config entry and nothing else. It runs no git
// (git there would discover an ANCESTOR repository) and no teardown script (which would run in that
// folder), and it leaves the folder for the user to remove.
func (s *Service) forgetNonGitWorkroom(dir, name, path string) (DeleteResult, error) {
	if err := s.Config.RemoveWorkroom(dir, name); err != nil {
		return DeleteResult{}, err
	}
	return DeleteResult{Name: name, Outcome: ForgotNonGit, Path: path}, nil
}

// PickOutcome is how an InteractiveDelete ended.
type PickOutcome int

const (
	// PicksDeleted: every pick was deleted, each reported as it went.
	PicksDeleted PickOutcome = iota
	// NoWorkroomsToPick: the project has no workrooms, so nothing was offered.
	NoWorkroomsToPick
	// NothingPicked: the user picked no workroom.
	NothingPicked
	// PicksDeclined: the user declined to confirm the picks, so nothing was deleted.
	PicksDeclined
)

// InteractiveDelete offers the project's workrooms through PromptFn, confirms the picks through
// ConfirmFn, and deletes each one, handing report its result as soon as it is done.
func (s *Service) InteractiveDelete(dir string, report func(DeleteResult)) (PickOutcome, error) {
	if err := s.CheckNotInWorkroom(dir); err != nil {
		return 0, err
	}

	_, project, found := s.Config.FindCurrentProject(dir)
	if !found || project == nil {
		return NoWorkroomsToPick, nil
	}

	if len(project.Workrooms) == 0 {
		return NoWorkroomsToPick, nil
	}

	names := make([]string, 0, len(project.Workrooms))
	for name := range project.Workrooms {
		names = append(names, name)
	}

	selected, err := s.PromptFn("Select workrooms to delete:", names)
	if err != nil {
		return 0, err
	}

	if len(selected) == 0 {
		return NothingPicked, nil
	}

	quotedNames := make([]string, len(selected))
	for i, n := range selected {
		quotedNames[i] = fmt.Sprintf("'%s'", n)
	}
	msg := fmt.Sprintf("Are you sure you want to delete %d workroom(s): %s?", len(selected), strings.Join(quotedNames, ", "))

	confirmed, err := s.ConfirmFn(msg)
	if err != nil {
		return 0, err
	}
	if !confirmed {
		return PicksDeclined, nil
	}

	if err := s.detectVCS(dir); err != nil {
		return 0, err
	}

	for _, name := range selected {
		// Same rules as Delete: a remote workroom is refused unless its host is destroyed (then
		// deleteByName only forgets it), and a selection git does not list as a worktree may be a
		// workroom Jujutsu made (#266), which is only forgotten.
		if _, err := s.destroyedRemote(dir, name); err != nil {
			return 0, err
		}
		if !s.Pretend {
			orphan, err := s.legacyWorkroomPath(dir, name)
			if err != nil {
				return 0, err
			}
			if orphan != "" {
				res, err := s.forgetNonGitWorkroom(dir, name, orphan)
				if err != nil {
					return 0, err
				}
				report(res)
				continue
			}
		}
		res, err := s.deleteByName(dir, name)
		if err != nil {
			return 0, err
		}
		report(res)
	}

	return PicksDeleted, nil
}

// RunTeardown runs the teardown script for a workroom. It resolves the workroom
// directory via the config WorkroomsDir, streams output to ScriptLogWriter (the
// NDJSON sink in --json mode) or else ScriptOutput (the human log panel), and
// respects Pretend mode and SkipTeardown.
// Returns the script error if the script fails; returns nil when the script is absent.
// deleteByName runs it first, so its remote refusal covers every delete.
func (s *Service) RunTeardown(dir, name string) error {
	if err := s.refuseRemote(dir, name); err != nil {
		return err
	}
	wrPath, err := s.workroomPath(name)
	if err != nil {
		return err
	}

	if teardownScript, ok := findScript("workroom_teardown", wrPath, dir); ok && s.SkipTeardown {
		s.sayStatus("teardown", fmt.Sprintf("Skipping %s, as asked", teardownScript))
	} else if ok {
		s.sayStatus("teardown", fmt.Sprintf("Running %s from %q", teardownScript, wrPath))
		if !s.Pretend {
			if err := s.gateFound(dir, TeardownScript, wrPath, teardownScript); err != nil {
				return err
			}
			stream := s.ScriptLogWriter
			var done func(ok bool)
			if stream == nil && s.ScriptOutput != nil {
				stream, done = s.ScriptOutput("Teardown")
			}
			_, scriptErr := script.Run("teardown", teardownScript, wrPath, name, dir, stream)
			if done != nil {
				done(scriptErr == nil)
			}
			if scriptErr != nil {
				return scriptErr
			}
		}
	}
	return nil
}

// destroyedRemote reports whether name is a remote workroom whose host is already destroyed, which
// deleteByName drops from config with nothing to tear down (#253). A remote workroom whose host
// is still there is refused: only the app can destroy it.
func (s *Service) destroyedRemote(dir, name string) (bool, error) {
	projects, err := s.Config.AllProjects()
	if err != nil {
		return false, err
	}
	w := projects[dir].Workrooms[name]
	if w.IsRemote() && !w.HostDestroyed() {
		return false, fmt.Errorf("%w: workroom '%s' is remote", ErrRemoteWorkroom, name)
	}
	return w.HostDestroyed(), nil
}

// refuseRemote returns ErrRemoteWorkroom when name is a remote workroom of project dir. Each
// local delete step (the teardown script, the VCS removal) works on
// <workrooms_dir>/<name> on this Mac, which is not where a remote workroom lives. Remote deletion
// is its own path (#253).
func (s *Service) refuseRemote(dir, name string) error {
	projects, err := s.Config.AllProjects()
	if err != nil {
		return err
	}
	if projects[dir].Workrooms[name].IsRemote() {
		return fmt.Errorf("%w: workroom '%s' is remote", ErrRemoteWorkroom, name)
	}
	return nil
}

func (s *Service) deleteByName(dir, name string) (DeleteResult, error) {
	destroyed, err := s.destroyedRemote(dir, name)
	if err != nil {
		return DeleteResult{}, err
	}
	if destroyed {
		return s.forgetDestroyedRemote(dir, name)
	}

	wrPath, err := s.workroomPath(name)
	if err != nil {
		return DeleteResult{}, err
	}

	// Run teardown script, streaming its output as it runs. --json mode supplies an
	// NDJSON sink (ScriptLogWriter); otherwise the human terminal gets a live log
	// panel (ScriptOutput). When neither applies the stream is nil, so script.Run
	// keeps the captured output in the returned error instead of dropping it.
	if err := s.RunTeardown(dir, name); err != nil {
		return DeleteResult{}, err
	}

	// Delete VCS workspace
	if !s.Pretend {
		if _, err := s.VCS.Delete(dir, s.vcsName(name), wrPath); err != nil {
			return DeleteResult{}, fmt.Errorf("%w: %v", ErrVCSCommand, err)
		}
	}

	// Update config
	if !s.Pretend {
		if err := s.Config.RemoveWorkroom(dir, name); err != nil {
			return DeleteResult{}, err
		}
	}

	return DeleteResult{Name: name, Outcome: Deleted, Branch: s.vcsName(name)}, nil
}

// forgetDestroyedRemote drops the config entry of a remote workroom whose host is gone. Nothing
// runs: there is no box for the teardown script, and no workspace on this Mac.
func (s *Service) forgetDestroyedRemote(dir, name string) (DeleteResult, error) {
	if !s.Pretend {
		if err := s.Config.RemoveWorkroom(dir, name); err != nil {
			return DeleteResult{}, err
		}
	}
	return DeleteResult{Name: name, Outcome: ForgotDestroyedRemote}, nil
}
