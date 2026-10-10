package workroom

import (
	"errors"
	"fmt"
	"io"
	"iter"
	"math/rand/v2"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/namegen"
	"github.com/joelmoss/workroom/internal/script"
	"github.com/joelmoss/workroom/internal/ui"
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
	Out            io.Writer
	Pretend        bool
	PromptFn       PromptFunc
	ConfirmFn      ConfirmFunc
	NameGenFunc    func() string                   // override for testing
	VCSForTypeFunc func(vcs.Type) (vcs.VCS, error) // override for testing (used by ListData)

	// Status, when set, receives a progress step as it happens: a short status word and what was
	// done, e.g. ("setup", "Running <script> from <dir>"). --verbose prints them.
	Status func(status, msg string)
	// KeepEmptyProject leaves a project registered after its last workroom is
	// deleted. Set by GUI callers that pin empty projects in the sidebar.
	KeepEmptyProject bool
	// ScriptLogWriter, when set, receives setup/teardown script output as it runs.
	// It is the --json mode sink (an NDJSON event stream on stderr) and takes the
	// place of the human terminal log panel. The captured output is still returned,
	// but on failure the surfaced error stays concise (the output already streamed).
	ScriptLogWriter io.Writer
	// OnReady, when set, is called once the workroom exists (VCS workspace + config
	// written) but before the setup script runs. --json mode uses it to emit an early
	// "created" event so a GUI can mount the new workroom and stream the setup log
	// beneath its terminal from the start.
	OnReady func(CreateResult)
}

func (s *Service) output() io.Writer {
	if s.Out != nil {
		return s.Out
	}
	return os.Stdout
}

func (s *Service) say(msg string) {
	fmt.Fprintln(s.output(), msg)
}

func (s *Service) sayColor(msg, colorName string) {
	w := s.output()
	switch colorName {
	case "green":
		fmt.Fprintln(w, ui.Green(msg))
	case "red":
		fmt.Fprintln(w, ui.Red(msg))
	case "yellow":
		fmt.Fprintln(w, ui.Yellow(msg))
	case "blue":
		fmt.Fprintln(w, ui.Blue(msg))
	default:
		fmt.Fprintln(w, msg)
	}
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

// CreateResult describes a newly created workroom. SetupOutput is captured for the
// human renderer and is not part of the machine payload. HasSetup reports whether a
// setup script exists for the project (resolved before OnReady fires) so a GUI can
// decide to block on the setup log; it too stays out of the machine payload.
type CreateResult struct {
	Name    string `json:"name"`
	Path    string `json:"path"`
	VCS     string `json:"vcs"`
	Project string `json:"project"`
	// Warning is for the user: non-empty when the workspace started from a ref that may be out
	// of date because the fetch before it failed.
	Warning     string `json:"warning,omitempty"`
	SetupOutput string `json:"-"`
	HasSetup    bool   `json:"-"`
}

// CreateNamed generates a unique name, creates the VCS workspace, updates config,
// and runs the setup script, returning a structured result. It writes nothing to
// stdout; progress steps go to s.Status. The human create (cmd) renders the success
// message and the editor prompt.
//
// If setupOut is non-nil the setup script's output is streamed to it live as the
// script runs; the full output is also captured into res.SetupOutput regardless.
// Machine callers (--json) pass nil.
//
// Create is not transactional: if the setup script fails the workspace and config
// entry already exist, so the returned CreateResult is populated (Name/Path) even
// when err is non-nil, letting callers report "created, but setup failed".
func (s *Service) CreateNamed(dir string, setupOut io.Writer) (CreateResult, error) {
	var res CreateResult
	if err := s.CheckNotInWorkroom(dir); err != nil {
		return res, err
	}
	if err := s.detectVCS(dir); err != nil {
		return res, err
	}

	name, err := s.generateUniqueName(dir)
	if err != nil {
		return res, err
	}

	wrPath, err := s.workroomPath(name)
	if err != nil {
		return res, err
	}

	if !s.Pretend {
		exists, err := s.workroomExists(dir, name)
		if err != nil {
			return res, err
		}
		if exists {
			return res, fmt.Errorf("%w: %s '%s' already exists", ErrGitWorktreeExists, s.VCS.Label(), name)
		}

		if _, err := os.Stat(wrPath); err == nil {
			return res, fmt.Errorf("%w: workroom directory '%s' already exists", ErrDirExists, ui.DisplayPath(wrPath))
		}
	}

	// Create VCS workspace
	var warning string
	if !s.Pretend {
		projects, err := s.Config.AllProjects()
		if err != nil {
			return res, err
		}
		wrDir, err := s.Config.WorkroomsDir()
		if err != nil {
			return res, err
		}
		if err := os.MkdirAll(wrDir, 0o755); err != nil {
			return res, err
		}
		// The project's own base wins; else the global one; else origin's default branch.
		base := projects[dir].BaseBranch
		global := base == ""
		if global {
			base = s.Config.BaseBranch()
		}
		// An app-wide default must not block a project it doesn't fit (`upstream/main` in a
		// repository with no upstream), so it may fall back; a project's own base is an explicit
		// choice and still fails.
		warning, err = s.VCS.Create(dir, s.vcsName(name), wrPath, base, global)
		if errors.Is(err, ErrBaseBranchNotFound) {
			return res, err
		}
		if err != nil {
			return res, fmt.Errorf("%w: %v", ErrVCSCommand, err)
		}
	}

	// Update config
	if !s.Pretend {
		if err := s.Config.AddWorkroom(dir, name, wrPath, string(s.VCS.Type())); err != nil {
			return res, err
		}
	}

	// From here the workroom exists; populate the result so partial-failure callers
	// can still report what was created.
	res = CreateResult{Name: name, Path: wrPath, VCS: string(s.VCS.Type()), Project: dir, Warning: warning}

	// Resolve whether a setup script exists before signalling readiness, so OnReady
	// carries HasSetup and a GUI can decide to block on the setup log up front.
	setupScript, ok := findScript("workroom_setup", wrPath, dir)
	res.HasSetup = ok

	// Signal readiness before the (potentially slow) setup script runs, so a GUI can
	// show the workroom and stream setup output beneath its terminal immediately.
	if !s.Pretend && s.OnReady != nil {
		s.OnReady(res)
	}

	// Run setup script. The human terminal passes a log panel via setupOut; --json
	// mode leaves it nil and routes through ScriptLogWriter (NDJSON on stderr).
	if setupOut == nil {
		setupOut = s.ScriptLogWriter
	}
	if res.HasSetup {
		s.sayStatus("setup", fmt.Sprintf("Running %s from %q", setupScript, wrPath))
		if !s.Pretend {
			out, scriptErr := script.Run("setup", setupScript, wrPath, name, dir, setupOut)
			res.SetupOutput = out
			if scriptErr != nil {
				return res, scriptErr
			}
		}
	}

	return res, nil
}

// findScript is scripts/<name> from the workroom, whose files it sets up or tears down, else from
// the project's root checkout, where a gitignored, local-only script lives. The workroom's copy
// comes first because the workroom can start from a newer commit than the root has out; setup and
// teardown use the same rule so a pair always comes from the same place.
func findScript(name, wrPath, dir string) (string, bool) {
	for _, base := range []string{wrPath, dir} {
		p := filepath.Join(base, "scripts", name)
		if _, err := os.Stat(p); err == nil {
			return p, true
		}
	}
	return filepath.Join(dir, "scripts", name), false
}

// CreateRemote registers a workroom on another host (#253) under a newly generated name, and
// creates nothing on this Mac: no VCS workspace, no directory, no setup script. The app makes the
// host and checks the repository out there; path is the checkout's path on it, and host its
// descriptor, which the app owns. Names are drawn as CreateNamed draws them, so a remote and a
// local workroom never share one.
func (s *Service) CreateRemote(dir, path string, host map[string]any) (CreateResult, error) {
	var res CreateResult
	if err := s.CheckNotInWorkroom(dir); err != nil {
		return res, err
	}
	if err := s.detectVCS(dir); err != nil {
		return res, err
	}
	name, err := s.generateUniqueName(dir)
	if err != nil {
		return res, err
	}
	if !s.Pretend {
		if err := s.Config.AddRemoteWorkroom(dir, name, path, host); err != nil {
			return res, err
		}
	}
	// git: the host's checkout is a clone, whatever the project uses on this Mac.
	return CreateResult{Name: name, Path: path, VCS: string(vcs.TypeGit), Project: dir}, nil
}

func (s *Service) generateUniqueName(dir string) (string, error) {
	// List once for the whole retry loop below, rather than once per candidate name — a
	// membership check against an in-memory set instead of up to 15 VCS shell-outs to answer
	// what is really one question against a list that doesn't change during this operation.
	existing, err := s.VCS.ListWorkrooms(dir)
	if err != nil {
		return "", err
	}
	// A remote workroom is in config but never in the local VCS list, and AddWorkroom replaces an
	// entry of the same name whole, host descriptor included.
	configured, err := s.Config.WorkroomNames(dir)
	if err != nil {
		return "", err
	}
	existing = append(existing, configured...)

	var lastName string

	for range 5 {
		lastName = s.generateName()
		wrPath, err := s.workroomPath(lastName)
		if err != nil {
			return "", err
		}
		if !slices.Contains(existing, lastName) {
			if _, err := os.Stat(wrPath); os.IsNotExist(err) {
				return lastName, nil
			}
		}
	}

	for range 10 {
		candidate := fmt.Sprintf("%s-%d", lastName, rand.IntN(90)+10)
		wrPath, err := s.workroomPath(candidate)
		if err != nil {
			return "", err
		}
		if !slices.Contains(existing, candidate) {
			if _, err := os.Stat(wrPath); os.IsNotExist(err) {
				return candidate, nil
			}
		}
	}

	return "", fmt.Errorf("failed to generate unique workroom name after multiple attempts")
}

// workroomExists reports whether name is among dir's VCS workrooms, listing once. Not a cheap
// single-name probe — ListWorkrooms is the interface's sole membership primitive — so callers
// needing several checks in one operation (e.g. generateUniqueName's retry loops) should list
// once themselves rather than call this per candidate.
func (s *Service) workroomExists(dir, name string) (bool, error) {
	existing, err := s.VCS.ListWorkrooms(dir)
	if err != nil {
		return false, err
	}
	return slices.Contains(existing, name), nil
}

// Listing is what the human `workroom list` shows from a directory.
type Listing struct {
	// InWorkroom is true when the directory is inside a workroom; ParentPath is its project.
	InWorkroom bool
	ParentPath string
	// AtProject is true when the directory is a registered project's root. Projects then yields
	// that project alone, or nothing when it has no workrooms.
	AtProject bool
	// Count is how many projects Projects yields.
	Count int
	// Projects yields the projects to show, sorted by path: each one's path, and a function that
	// runs its checks and returns it with its warnings at WarningsFull. Away from any project it
	// is every project that has workrooms. A caller shows each path before its checks run, and
	// each project before the next one's, so one that stalls (a hung network volume) is named
	// and holds back nothing before it.
	Projects iter.Seq2[string, func() ProjectInfo]
}

// Listing returns what the human list shows from cwd. Unlike ListData it depends on cwd, and away
// from a project it holds only projects with workrooms.
func (s *Service) Listing(cwd string) (Listing, error) {
	projectPath, project, found := s.Config.FindCurrentProject(cwd)

	// Inside a workroom
	if found && projectPath != cwd {
		return Listing{InWorkroom: true, ParentPath: projectPath}, nil
	}

	// Inside a parent project. Its warnings are computed only when it has workrooms: projectInfo
	// may heal the stored VCS type, which an empty project's listing never did.
	if found && project != nil {
		if len(project.Workrooms) == 0 {
			return Listing{AtProject: true, Projects: func(func(string, func() ProjectInfo) bool) {}}, nil
		}
		return Listing{AtProject: true, Count: 1, Projects: func(yield func(string, func() ProjectInfo) bool) {
			yield(projectPath, func() ProjectInfo { return s.projectInfo(projectPath, *project, WarningsFull) })
		}}, nil
	}

	// Neither — list all
	projects, err := s.Config.ProjectsWithWorkrooms()
	if err != nil {
		return Listing{}, err
	}

	paths := make([]string, 0, len(projects))
	for path := range projects {
		paths = append(paths, path)
	}
	sort.Strings(paths)

	return Listing{Count: len(paths), Projects: func(yield func(string, func() ProjectInfo) bool) {
		for _, path := range paths {
			if !yield(path, func() ProjectInfo { return s.projectInfo(path, projects[path], WarningsFull) }) {
				return
			}
		}
	}}, nil
}

// Delete removes a workroom by name.
func (s *Service) Delete(dir, name, confirmValue string) error {
	if err := s.CheckNotInWorkroom(dir); err != nil {
		return err
	}

	if !validNameRe.MatchString(name) {
		return fmt.Errorf("%w: %q", ErrInvalidName, name)
	}

	destroyed, err := s.destroyedRemote(dir, name)
	if err != nil {
		return err
	}

	// A destroyed remote workroom is only dropped from config, which needs no local repository: the
	// project's checkout may be gone by then.
	if !destroyed {
		if err := s.detectVCS(dir); err != nil {
			return err
		}
	}

	orphan := ""
	if !s.Pretend {
		exists := destroyed
		if !destroyed {
			if exists, err = s.workroomExists(dir, name); err != nil {
				return err
			}
		}
		if !exists {
			orphan, err = s.nonGitWorkroomPath(dir, name)
			if err != nil {
				return err
			}
			if orphan == "" {
				return fmt.Errorf("%w: %s '%s' does not exist", ErrGitWorktreeNotFound, s.VCS.Label(), name)
			}
		}

		if confirmValue != "" {
			if confirmValue != name {
				return fmt.Errorf("%w: --confirm value '%s' does not match workroom name '%s'", ErrConfirmMismatch, confirmValue, name)
			}
		} else {
			confirmed, err := s.ConfirmFn(fmt.Sprintf("Are you sure you want to delete workroom '%s'?", name))
			if err != nil {
				return err
			}
			if !confirmed {
				s.sayColor(fmt.Sprintf("Aborting. Workroom '%s' was not deleted.", name), "yellow")
				return nil
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
func (s *Service) forgetNonGitWorkroom(dir, name, path string) error {
	var err error
	if s.KeepEmptyProject {
		err = s.Config.RemoveWorkroomKeepProject(dir, name)
	} else {
		err = s.Config.RemoveWorkroom(dir, name)
	}
	if err != nil {
		return err
	}
	s.sayColor(fmt.Sprintf("Workroom '%s' removed from Workroom. It is not a git worktree, so no git or teardown ran.", name), "green")
	s.say(fmt.Sprintf("Note: its folder was left at %s. Delete it manually if needed.", ui.DisplayPath(path)))
	return nil
}

// InteractiveDelete shows a multi-select prompt for deleting workrooms.
func (s *Service) InteractiveDelete(dir string) error {
	if err := s.CheckNotInWorkroom(dir); err != nil {
		return err
	}

	_, project, found := s.Config.FindCurrentProject(dir)
	if !found || project == nil {
		s.say("No workrooms found for this project.")
		return nil
	}

	if len(project.Workrooms) == 0 {
		s.say("No workrooms found for this project.")
		return nil
	}

	names := make([]string, 0, len(project.Workrooms))
	for name := range project.Workrooms {
		names = append(names, name)
	}

	selected, err := s.PromptFn("Select workrooms to delete:", names)
	if err != nil {
		return err
	}

	if len(selected) == 0 {
		s.sayColor("Aborting. No workrooms were selected.", "yellow")
		return nil
	}

	quotedNames := make([]string, len(selected))
	for i, n := range selected {
		quotedNames[i] = fmt.Sprintf("'%s'", n)
	}
	msg := fmt.Sprintf("Are you sure you want to delete %d workroom(s): %s?", len(selected), strings.Join(quotedNames, ", "))

	confirmed, err := s.ConfirmFn(msg)
	if err != nil {
		return err
	}
	if !confirmed {
		s.sayColor("Aborting. No workrooms were deleted.", "yellow")
		return nil
	}

	if err := s.detectVCS(dir); err != nil {
		return err
	}

	for _, name := range selected {
		// Same rules as Delete: a remote workroom is refused unless its host is destroyed (then
		// deleteByName only forgets it), and a selection git does not list as a worktree may be a
		// workroom Jujutsu made (#266), which is only forgotten.
		if _, err := s.destroyedRemote(dir, name); err != nil {
			return err
		}
		if !s.Pretend {
			orphan, err := s.legacyWorkroomPath(dir, name)
			if err != nil {
				return err
			}
			if orphan != "" {
				if err := s.forgetNonGitWorkroom(dir, name, orphan); err != nil {
					return err
				}
				continue
			}
		}
		if err := s.deleteByName(dir, name); err != nil {
			return err
		}
	}

	return nil
}

// RunTeardown runs the teardown script for a workroom. It resolves the workroom
// directory via the config WorkroomsDir, streams output to the NDJSON log sink (in
// --json mode) or a live log panel (in human mode), and respects Pretend mode.
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

	if teardownScript, ok := findScript("workroom_teardown", wrPath, dir); ok {
		s.sayStatus("teardown", fmt.Sprintf("Running %s from %q", teardownScript, wrPath))
		if !s.Pretend {
			var panel *ui.LogPanel
			stream := s.ScriptLogWriter
			if stream == nil {
				if out := s.output(); out != io.Discard {
					panel = ui.NewLogPanel(out, "Teardown")
					stream = panel
				}
			}
			_, scriptErr := script.Run("teardown", teardownScript, wrPath, name, dir, stream)
			if panel != nil {
				panel.Close(scriptErr == nil)
			}
			if scriptErr != nil {
				return scriptErr
			}
			if panel != nil && panel.Shown() {
				s.say("")
			}
		}
	}
	return nil
}

// destroyedRemote reports whether name is a remote workroom whose host is already destroyed, which
// deleteByName drops from config with nothing to tear down (#253). A remote workroom whose host
// is still there is refused: only the app can destroy it and cancel its grant.
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

func (s *Service) deleteByName(dir, name string) error {
	destroyed, err := s.destroyedRemote(dir, name)
	if err != nil {
		return err
	}
	if destroyed {
		return s.forgetDestroyedRemote(dir, name)
	}

	wrPath, err := s.workroomPath(name)
	if err != nil {
		return err
	}

	// Run teardown script, streaming its output as it runs. --json mode supplies an
	// NDJSON sink (ScriptLogWriter); otherwise the human terminal gets a live log
	// panel. When neither applies (output discarded, no sink) the stream is nil, so
	// script.Run keeps the captured output in the returned error instead of dropping
	// it.
	if err := s.RunTeardown(dir, name); err != nil {
		return err
	}

	// Delete VCS workspace
	if !s.Pretend {
		if _, err := s.VCS.Delete(dir, s.vcsName(name), wrPath); err != nil {
			return fmt.Errorf("%w: %v", ErrVCSCommand, err)
		}
	}

	// Update config
	if !s.Pretend {
		if s.KeepEmptyProject {
			if err := s.Config.RemoveWorkroomKeepProject(dir, name); err != nil {
				return err
			}
		} else {
			if err := s.Config.RemoveWorkroom(dir, name); err != nil {
				return err
			}
		}
	}

	s.sayColor(fmt.Sprintf("Workroom '%s' deleted successfully.", name), "green")

	s.say("")
	s.say(fmt.Sprintf("Note: Git branch '%s' was not deleted.", s.vcsName(name)))
	s.say(fmt.Sprintf("      Delete manually with `git branch -D %s` if needed.", s.vcsName(name)))

	return nil
}

// forgetDestroyedRemote drops the config entry of a remote workroom whose host is gone. Nothing
// runs: there is no box for the teardown script, and no workspace on this Mac.
func (s *Service) forgetDestroyedRemote(dir, name string) error {
	if !s.Pretend {
		remove := s.Config.RemoveWorkroom
		if s.KeepEmptyProject {
			remove = s.Config.RemoveWorkroomKeepProject
		}
		if err := remove(dir, name); err != nil {
			return err
		}
	}
	s.sayColor(fmt.Sprintf("Workroom '%s' deleted successfully.", name), "green")
	return nil
}
