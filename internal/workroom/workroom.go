package workroom

import (
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"os/exec"
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
	Verbose        bool
	Pretend        bool
	PromptFn       PromptFunc
	ConfirmFn      ConfirmFunc
	NameGenFunc    func() string                   // override for testing
	OpenEditorFunc func(editor, path string) error // override for testing
	VCSForTypeFunc func(vcs.Type) (vcs.VCS, error) // override for testing (used by ListData)

	// SuppressEditor disables the post-create "open in $EDITOR" prompt. Set by
	// --no-editor and implied by --json (a GUI/machine caller must never block).
	SuppressEditor bool
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
	if s.Verbose {
		fmt.Fprintf(s.output(), "%12s  %s\n", status, msg)
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

func (s *Service) openEditor(editor, path string) error {
	if s.OpenEditorFunc != nil {
		return s.OpenEditorFunc(editor, path)
	}
	parts := strings.Fields(editor)
	args := append(parts[1:], path)
	cmd := exec.Command(parts[0], args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
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
// the stored type so a project converted between VCSes (e.g. a colocated jj repo whose .jj
// dir was removed, leaving plain git) is reported correctly. It falls back to `stored` when
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
// repo has no workspaces. git lists bare basenames; jj lists "workroom/<name>" (callers check
// both keys).
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
	Name        string `json:"name"`
	Path        string `json:"path"`
	VCS         string `json:"vcs"`
	Project     string `json:"project"`
	SetupOutput string `json:"-"`
	HasSetup    bool   `json:"-"`
}

// CreateNamed generates a unique name, creates the VCS workspace, updates config,
// and runs the setup script, returning a structured result. It writes nothing to
// stdout beyond verbose status lines (which go to s.Out). The human-facing success
// message and the editor prompt live in the Create wrapper.
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
			if s.VCS.Type() == vcs.TypeJJ {
				return res, fmt.Errorf("%w: %s '%s' already exists", ErrJJWorkspaceExists, s.VCS.Label(), name)
			}
			return res, fmt.Errorf("%w: %s '%s' already exists", ErrGitWorktreeExists, s.VCS.Label(), name)
		}

		if _, err := os.Stat(wrPath); err == nil {
			return res, fmt.Errorf("%w: workroom directory '%s' already exists", ErrDirExists, ui.DisplayPath(wrPath))
		}
	}

	// Create VCS workspace
	if !s.Pretend {
		wrDir, err := s.Config.WorkroomsDir()
		if err != nil {
			return res, err
		}
		if err := os.MkdirAll(wrDir, 0o755); err != nil {
			return res, err
		}
		if _, err := s.VCS.Create(dir, s.vcsName(name), wrPath); err != nil {
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
	res = CreateResult{Name: name, Path: wrPath, VCS: string(s.VCS.Type()), Project: dir}

	// Resolve whether a setup script exists before signalling readiness, so OnReady
	// carries HasSetup and a GUI can decide to block on the setup log up front.
	setupScript := filepath.Join(dir, "scripts", "workroom_setup")
	if _, err := os.Stat(setupScript); err == nil {
		res.HasSetup = true
	}

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

// Create generates a unique name and creates a new workroom (human-facing).
func (s *Service) Create(dir string) error {
	// The setup script's output streams live into this panel as it runs. The panel
	// renders lazily on first output, so a script with no output draws nothing.
	panel := ui.NewLogPanel(s.output(), "Setup")
	res, err := s.CreateNamed(dir, panel)
	panel.Close(err == nil)
	if err != nil {
		return err
	}

	if panel.Shown() {
		s.say("")
	}
	s.sayColor(fmt.Sprintf("Workroom '%s' created successfully at %s.", res.Name, ui.DisplayPath(res.Path)), "green")

	// Offer to open the workroom in the user's editor
	editor := os.Getenv("EDITOR")
	if editor != "" && !s.Pretend && !s.SuppressEditor {
		open, err := s.ConfirmFn(fmt.Sprintf("Open workroom in %s?", editor))
		if err != nil {
			return err
		}
		if open {
			if err := s.openEditor(editor, res.Path); err != nil {
				return fmt.Errorf("failed to open editor: %w", err)
			}
		}
	}

	return nil
}

func (s *Service) generateUniqueName(dir string) (string, error) {
	// List once for the whole retry loop below, rather than once per candidate name — a
	// membership check against an in-memory set instead of up to 15 VCS shell-outs to answer
	// what is really one question against a list that doesn't change during this operation.
	existing, err := s.VCS.ListWorkrooms(dir)
	if err != nil {
		return "", err
	}

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

// List shows workrooms for the current project or all projects.
func (s *Service) List(cwd string) error {
	projectPath, project, found := s.Config.FindCurrentProject(cwd)

	// Inside a workroom
	if found && projectPath != cwd {
		s.sayColor("You are already in a workroom.", "yellow")
		s.say(fmt.Sprintf("Parent project is at %s", ui.DisplayPath(projectPath)))
		return nil
	}

	// Inside a parent project
	if found && project != nil {
		if len(project.Workrooms) == 0 {
			s.say("No workrooms found for this project.")
			return nil
		}

		s.printWorkroomsTable(s.projectInfo(projectPath, *project, WarningsFull))
		return nil
	}

	// Neither — list all
	projects, err := s.Config.ProjectsWithWorkrooms()
	if err != nil {
		return err
	}

	if len(projects) == 0 {
		s.say("No workrooms found.")
		return nil
	}

	paths := make([]string, 0, len(projects))
	for path := range projects {
		paths = append(paths, path)
	}
	sort.Strings(paths)

	for _, path := range paths {
		s.say(fmt.Sprintf("%s:", ui.DisplayPath(path)))
		s.printWorkroomsTable(s.projectInfo(path, projects[path], WarningsFull))
		s.say("")
	}

	return nil
}

// printWorkroomsTable renders one project's already-computed warnings (see projectInfo) as the
// human-readable table.
func (s *Service) printWorkroomsTable(pinfo ProjectInfo) {
	var rows [][]string
	for _, wi := range pinfo.Workrooms {
		row := []string{ui.Bold(wi.Name), ui.Dim(ui.DisplayPath(wi.Path))}
		if len(wi.Warnings) > 0 {
			messages := make([]string, len(wi.Warnings))
			for i, w := range wi.Warnings {
				messages[i] = w.Message
			}
			row = append(row, ui.Yellow(fmt.Sprintf("[%s]", strings.Join(messages, ", "))))
		}
		rows = append(rows, row)
	}
	ui.PrintTable(s.output(), rows, 2)
}

// Delete removes a workroom by name.
func (s *Service) Delete(dir, name, confirmValue string) error {
	if err := s.CheckNotInWorkroom(dir); err != nil {
		return err
	}

	if !validNameRe.MatchString(name) {
		return fmt.Errorf("%w: %q", ErrInvalidName, name)
	}

	if err := s.detectVCS(dir); err != nil {
		return err
	}

	if !s.Pretend {
		exists, err := s.workroomExists(dir, name)
		if err != nil {
			return err
		}
		if !exists {
			if s.VCS.Type() == vcs.TypeJJ {
				return fmt.Errorf("%w: %s '%s' does not exist", ErrJJWorkspaceNotFound, s.VCS.Label(), name)
			}
			return fmt.Errorf("%w: %s '%s' does not exist", ErrGitWorktreeNotFound, s.VCS.Label(), name)
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

	return s.deleteByName(dir, name)
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
func (s *Service) RunTeardown(dir, name string) error {
	wrPath, err := s.workroomPath(name)
	if err != nil {
		return err
	}

	teardownScript := filepath.Join(dir, "scripts", "workroom_teardown")
	if _, err := os.Stat(teardownScript); err == nil {
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

func (s *Service) deleteByName(dir, name string) error {
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

	// Cleanup directory for JJ
	if s.VCS.Type() == vcs.TypeJJ {
		if _, err := os.Stat(wrPath); err == nil {
			if !s.Pretend {
				if err := os.RemoveAll(wrPath); err != nil {
					s.sayColor(fmt.Sprintf("Warning: failed to remove directory %s: %v", wrPath, err), "yellow")
				}
			}
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

	if s.VCS.Type() == vcs.TypeGit {
		s.say("")
		s.say(fmt.Sprintf("Note: Git branch '%s' was not deleted.", s.vcsName(name)))
		s.say(fmt.Sprintf("      Delete manually with `git branch -D %s` if needed.", s.vcsName(name)))
	}

	return nil
}
