package workroom

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/namegen"
	"github.com/joelmoss/workroom/internal/vcs"
)

var validNameRe = regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?$`)

// PromptFunc abstracts interactive prompts for testability.
type PromptFunc func(message string, options []string) ([]string, error)
type ConfirmFunc func(message string) (bool, error)

// Service orchestrates workroom create/delete/list operations.
type Service struct {
	Config         *config.Config
	VCS            vcs.VCS
	Pretend        bool
	PromptFn       PromptFunc
	ConfirmFn      ConfirmFunc
	NameGenFunc    func() string                   // override for testing
	VCSForTypeFunc func(vcs.Type) (vcs.VCS, error) // override for testing (used by ListData)

	// Status, when set, receives a progress step as it happens: a short status word and what was
	// done, e.g. ("setup", "Running <script> from <dir>"). --verbose prints them.
	Status func(status, msg string)
	// SkipTeardown deletes without running the teardown script: a GUI's Delete Anyway, after the
	// script failed. Everything else a delete does still runs.
	SkipTeardown bool
	// SkipSetup creates without judging or running the setup script: the app's Continue Without
	// Script, for one this Mac has not approved. Nothing is recorded, so the next create asks again.
	SkipSetup bool
	// ScriptLogWriter, when set, receives setup/teardown script output as it runs.
	// It is the --json mode sink (an NDJSON event stream on stderr) and takes the
	// place of the human terminal log panel. The captured output is still returned,
	// but on failure the surfaced error stays concise (the output already streamed).
	ScriptLogWriter io.Writer
	// ScriptOutput, when set and ScriptLogWriter is not, opens a place for a teardown script's
	// output as it runs, under title: it returns the writer for that output and a function to call
	// once the script ends, with whether it passed. The human CLI shows a log panel. With neither,
	// the script's output stays in the error a failing script returns.
	ScriptOutput func(title string) (io.Writer, func(ok bool))
	// OnReady, when set, is called once the workroom exists (VCS workspace + config
	// written) but before the setup script runs. --json mode uses it to emit an early
	// "created" event so a GUI can mount the new workroom and stream the setup log
	// beneath its terminal from the start.
	OnReady func(CreateResult)
	// OnStep, when set, reports each step of a create (fetch, worktree, script) as it changes
	// state: running, done, warning, skipped or failed. detail is the warning text, the skip
	// reason or the failure message.
	OnStep func(id, state, detail string)
	// ApproveScriptFn, when set, is shown a setup or teardown script this Mac has not approved and
	// answers whether to approve and run it (#363). Unset, such a script is refused.
	ApproveScriptFn func(Script) (bool, error)
	// Start is where a create starts when the main checkout has work the remote's copy of the base
	// branch lacks: commits not pushed, or uncommitted changes. "" asks ChooseStartFn when set, and
	// otherwise starts from the remote's copy with a warning.
	Start Start
	// ChooseStartFn, when set, is told the local work a create would leave out and answers where it
	// starts. A person at a terminal is asked.
	ChooseStartFn func(vcs.LocalWork) (Start, error)
	// StartCommit, when set, is the start point a create question was asked about (the commit a
	// vcs.QuestionError reported): the create answering it fetches nothing and starts there
	// (ADR 0059). One it can't use is ErrStartCommitUnusable.
	StartCommit string
}

func (s *Service) sayStatus(status, msg string) {
	if s.Status != nil {
		s.Status(status, msg)
	}
}

// CheckNotInWorkroom checks if the current directory is already a workroom.
func (s *Service) CheckNotInWorkroom(dir string) error {
	if _, err := os.Stat(filepath.Join(dir, ".Workroom")); err == nil {
		return ErrInWorkroom
	}
	return nil
}

// detectVCS detects the VCS in the given directory and sets s.VCS.
func (s *Service) detectVCS(dir string) error {
	if s.VCS != nil {
		return nil
	}
	v, err := vcs.Detect(dir)
	if err != nil {
		return err
	}
	s.VCS = v
	s.sayStatus("repo", fmt.Sprintf("Detected %s", s.VCS.Label()))
	return nil
}

func (s *Service) vcsName(name string) string {
	return "workroom/" + name
}

func (s *Service) workroomPath(name string) (string, error) {
	dir, err := s.Config.WorkroomsDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, name), nil
}

func (s *Service) generateName() string {
	if s.NameGenFunc != nil {
		return s.NameGenFunc()
	}
	return namegen.Generate()
}

// vcsForType constructs a VCS from a stored type string, allowing tests to inject a
// mock executor (the real path uses vcs.New with a RealExecutor).
func (s *Service) vcsForType(t vcs.Type) (vcs.VCS, error) {
	if s.VCSForTypeFunc != nil {
		return s.VCSForTypeFunc(t)
	}
	return vcs.New(t)
}

// effectiveVCS returns the project's real VCS type, preferring live on-disk detection over
// the stored type so a project whose stored type is stale (e.g. "jj", from before Jujutsu
// support was removed, on a repo that also has .git) is reported correctly. It falls back to `stored` when
// the directory is absent or has no supported VCS — preserving the ability to list a project
// whose directory is gone. When persist is true and the detected type differs from stored, it
// heals the config (best-effort: the returned type is already correct even if the write fails).
func (s *Service) effectiveVCS(path, stored string, persist bool) string {
	v, err := vcs.Detect(path)
	if err != nil {
		return stored
	}
	detected := string(v.Type())
	if detected != stored && persist {
		_ = s.Config.SetProjectVCS(path, detected)
	}
	return detected
}

// vcsWorkspaceSet lists a project's VCS workspaces exactly once and returns them as a
// membership set. It returns nil on any error (empty type, unknown type, non-repo directory,
// or a failed VCS command) to signal "couldn't determine" — callers must treat a nil set as
// "don't warn" (fail-open), distinct from a non-nil empty set which authoritatively means the
// repo has no workspaces. git lists bare worktree basenames.
func (s *Service) vcsWorkspaceSet(path, vcsType string) map[string]bool {
	if vcsType == "" {
		return nil
	}
	v, err := s.vcsForType(vcs.Type(vcsType))
	if err != nil {
		return nil
	}
	listed, err := v.ListWorkrooms(path)
	if err != nil {
		return nil
	}
	set := make(map[string]bool, len(listed))
	for _, w := range listed {
		set[w] = true
	}
	return set
}

func (s *Service) step(id, state, detail string) {
	if s.OnStep != nil {
		s.OnStep(id, state, detail)
	}
}
