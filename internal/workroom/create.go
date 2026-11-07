package workroom

import (
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"

	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/script"
	"github.com/joelmoss/workroom/internal/ui"
	"github.com/joelmoss/workroom/internal/vcs"
)

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
	// of date because the fetch before it failed, or without local work the main checkout has.
	Warning     string `json:"warning,omitempty"`
	SetupOutput string `json:"-"`
	HasSetup    bool   `json:"-"`
	// IncludeWarning and IncludeSkipped are the include step's warning and the symlinks it skipped
	// (#367), for the human create; --json callers read them from the step's events.
	IncludeWarning string   `json:"-"`
	IncludeSkipped []string `json:"-"`
	// ChangesWarning is the warning of the step that copies the main checkout's uncommitted
	// changes, for the human create, as IncludeWarning.
	ChangesWarning string `json:"-"`
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
	var carryChanges bool
	if !s.Pretend {
		base, global, err := s.base(dir)
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
		// Where it starts, and the setup script there, are settled before anything exists, so a
		// refusal leaves nothing behind.
		var refused error
		var leftOut string
		progress := vcs.Progress{Log: s.ScriptLogWriter, Step: s.OnStep, StartCommit: s.StartCommit}
		progress.BeforeWorktree = func(start string, work vcs.LocalWork) (string, error) {
			choice, err := s.chooseStart(work)
			if err != nil {
				refused = err
				return "", err
			}
			switch choice {
			case "":
				if work.Any() {
					leftOut = leftOutWarning(work)
				}
			case StartLocal, StartLocalWithChanges:
				start = "refs/heads/" + work.Branch
				carryChanges = choice == StartLocalWithChanges && work.Uncommitted
			}
			if !s.SkipSetup {
				// At the start chosen: a local branch can carry another setup script, and copied
				// changes can carry an edited one, which is then the one that runs.
				gate := func() error { return s.gateSetup(dir, start) }
				if carryChanges {
					gate = func() error { return s.gateRootSetup(dir) }
				}
				if refused = gate(); refused != nil {
					return "", refused
				}
			}
			return start, nil
		}
		warning, err = s.VCS.Create(dir, s.vcsName(name), wrPath, base, global, progress)
		if refused != nil || errors.Is(err, ErrBaseBranchNotFound) || errors.Is(err, ErrStartCommitUnusable) {
			return res, err
		}
		if err != nil {
			return res, fmt.Errorf("%w: %v", ErrVCSCommand, err)
		}
		if warning == "" {
			warning = leftOut
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

	// The main checkout's uncommitted changes, when the user chose to bring them, then the root's
	// included files, both before the setup script so it can rely on them (#367).
	if carryChanges {
		res.ChangesWarning = s.carryChanges(dir, wrPath)
	}
	if !s.Pretend {
		res.IncludeWarning, res.IncludeSkipped = s.copyIncluded(dir, wrPath)
	}

	// Run setup script. The human terminal passes a log panel via setupOut; --json
	// mode leaves it nil and routes through ScriptLogWriter (NDJSON on stderr).
	if setupOut == nil {
		setupOut = s.ScriptLogWriter
	}
	if res.HasSetup && s.SkipSetup {
		if !s.Pretend {
			s.step("script", "skipped", "Skipped without approval")
		}
	} else if res.HasSetup {
		s.sayStatus("setup", fmt.Sprintf("Running %s from %q", setupScript, wrPath))
		if !s.Pretend {
			s.step("script", "running", "")
			// Again on the file about to run: it is what runs, whatever the early check read.
			if err := s.gateFound(dir, SetupScript, wrPath, setupScript); err != nil {
				s.step("script", "failed", err.Error())
				return res, err
			}
			out, scriptErr := script.Run("setup", setupScript, wrPath, name, dir, setupOut)
			res.SetupOutput = out
			if scriptErr != nil {
				s.step("script", "failed", scriptErr.Error())
				return res, scriptErr
			}
			s.step("script", "done", "")
		}
	} else if !s.Pretend {
		s.step("script", "skipped", "No setup script")
	}

	return res, nil
}

// base is the branch a new workroom of project dir starts from: the project's own, else the
// global one (global is then true), else "" for origin's default branch. An app-wide default must
// not block a project it doesn't fit (`upstream/main` in a repository with no upstream), so it may
// fall back; a project's own base is an explicit choice and still fails.
func (s *Service) base(dir string) (base string, global bool, err error) {
	projects, err := s.Config.AllProjects()
	if err != nil {
		return "", false, err
	}
	base = projects[dir].BaseBranch
	if base == "" {
		return s.Config.BaseBranch(), true, nil
	}
	return base, false, nil
}

// copyIncluded is the create's include step: it copies the root's included files into the new
// workroom at wrPath, logging each one. Nothing that goes wrong here fails the create: the step
// ends as a warning and the create carries on, since a missing file is easy to copy by hand. A
// root with no include file has no step. It returns the step's warning, or "", and the symlinks it
// skipped.
func (s *Service) copyIncluded(root, wrPath string) (string, []string) {
	// Announced before the listing, which takes a second or so in a root with a large ignored tree.
	if !HasIncludeFile(root) {
		return "", nil
	}
	s.step("include", "running", "")
	inc, _, err := IncludedFiles(root)
	warn := func(text string) (string, []string) {
		s.step("include", "warning", text)
		return text, inc.Symlinks
	}
	if err != nil {
		return warn(fmt.Sprintf("Could not list the included files: %v", err))
	}
	if s.ScriptLogWriter != nil {
		for _, f := range inc.Symlinks {
			fmt.Fprintln(s.ScriptLogWriter, SkippedSymlink(f))
		}
	}
	if len(inc.Files) == 0 {
		reason := "No matching files"
		if len(inc.Symlinks) > 0 {
			// Named here, not only in the log: a skipped row's log can't be opened.
			reason = "Only symlinks matched: " + strings.Join(inc.Symlinks, ", ")
		}
		s.step("include", "skipped", reason)
		return "", inc.Symlinks
	}
	res := CopyIncluded(root, wrPath, inc.Files)
	if s.ScriptLogWriter != nil {
		for _, f := range res.Copied {
			fmt.Fprintf(s.ScriptLogWriter, "Copied %s\n", f)
		}
		fmt.Fprintf(s.ScriptLogWriter, "Copied %s (%s)\n", countFiles(len(res.Copied)), byteSize(res.Bytes))
	}
	s.sayStatus("include", fmt.Sprintf("Copied %s from %s", countFiles(len(res.Copied)), IncludeFile))
	if len(res.Failures) > 0 {
		return warn(fmt.Sprintf("Could not copy %s: %s", countFiles(len(res.Failures)), strings.Join(res.Failures, "; ")))
	}
	s.step("include", "done", "")
	return "", inc.Symlinks
}

func countFiles(n int) string {
	if n == 1 {
		return "1 file"
	}
	return fmt.Sprintf("%d files", n)
}

// byteSize is n for a person, in decimal units as Finder shows sizes.
func byteSize(n int64) string {
	if n < 1000 {
		return fmt.Sprintf("%d B", n)
	}
	value, unit := float64(n)/1000, "KB"
	for _, next := range []string{"MB", "GB", "TB"} {
		if value < 1000 {
			break
		}
		value, unit = value/1000, next
	}
	return fmt.Sprintf("%.1f %s", value, unit)
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
func (s *Service) CreateRemote(dir, remotePath string, host map[string]any) (CreateResult, error) {
	return s.createRemote(dir, host, func(string) string { return remotePath })
}

// CreateRemoteInParent reserves a remote workroom in parent/name, where name is chosen by the
// same operation. Parent is an absolute POSIX path already resolved on the host, not on this Mac.
func (s *Service) CreateRemoteInParent(dir, parent string, host map[string]any) (CreateResult, error) {
	if !path.IsAbs(parent) || strings.ContainsRune(parent, '\x00') {
		return CreateResult{}, fmt.Errorf("%w: --host-parent must be an absolute path on the host", errs.ErrInvalidHost)
	}
	return s.createRemote(dir, host, func(name string) string { return path.Join(parent, name) })
}

func (s *Service) createRemote(dir string, host map[string]any, pathForName func(string) string) (CreateResult, error) {
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
	remotePath := pathForName(name)
	if !s.Pretend {
		if err := s.Config.AddRemoteWorkroom(dir, name, remotePath, host); err != nil {
			return res, err
		}
	}
	// git: the host's checkout is a clone, whatever the project uses on this Mac.
	return CreateResult{Name: name, Path: remotePath, VCS: string(vcs.TypeGit), Project: dir}, nil
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
