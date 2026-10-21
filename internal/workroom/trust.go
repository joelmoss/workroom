package workroom

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/vcs"
)

// The project scripts Workroom runs only once this Mac has approved their exact bytes (#363).
const (
	SetupScript    = "workroom_setup"
	TeardownScript = "workroom_teardown"
)

// Where a Script's bytes came from.
const (
	// OriginBase is the base commit, read from git: what a new workroom's checkout will hold.
	OriginBase = "base"
	// OriginRoot is the file in the project's root checkout.
	OriginRoot = "root"
	// OriginWorkroom is the file in a workroom.
	OriginWorkroom = "workroom"
	// OriginStdin is bytes a caller handed over, such as the app with a remote host's copy.
	OriginStdin = "stdin"
)

// Script is a setup or teardown script's bytes as Workroom would run them, judged against the
// project's approvals.
type Script struct {
	Name   string
	Origin string
	// Path is the file, for a root or workroom copy.
	Path   string
	Text   []byte
	SHA256 string
	// Exempt: the bytes are the root's copy and git ignores it there, so no pull ever brought
	// them. Such a script needs no approval.
	Exempt bool
	// Trusted: approved, or Exempt.
	Trusted bool
}

// OriginLabel is where Script came from, for a person.
func (sc Script) OriginLabel() string {
	switch sc.Origin {
	case OriginBase:
		return "from the base commit"
	case OriginWorkroom:
		return "in the workroom"
	case OriginStdin:
		return "as given"
	}
	return "in the project's root"
}

// UntrustedScriptError refuses a script this Mac has not approved. It is ErrScriptNotTrusted.
type UntrustedScriptError struct{ Script Script }

func (e *UntrustedScriptError) Error() string {
	// `workroom trust` judges the base commit's and the root's copies, never a workroom's own.
	how := "Review and approve it with `workroom trust`"
	if e.Script.Origin == OriginWorkroom {
		how = "Run the same command in a terminal to review and approve it"
	}
	return fmt.Sprintf("%v: scripts/%s %s is new, or changed since it was approved. %s",
		errs.ErrScriptNotTrusted, e.Script.Name, e.Script.OriginLabel(), how)
}

func (e *UntrustedScriptError) Unwrap() error { return errs.ErrScriptNotTrusted }

// JudgeScript hashes text, project dir's script name from origin, and says whether it may run:
// approved for the project, or the root's gitignored copy. An unreadable config is an error, so
// nothing runs on a guess.
func (s *Service) JudgeScript(dir, name, origin, path string, text []byte) (Script, error) {
	sum := sha256.Sum256(text)
	sc := Script{Name: name, Origin: origin, Path: path, Text: text, SHA256: hex.EncodeToString(sum[:])}
	projects, err := s.Config.AllProjects()
	if err != nil {
		return sc, err
	}
	sc.Exempt = ignoredRootCopy(dir, name, sc.SHA256)
	sc.Trusted = sc.Exempt || projects[dir].TrustedScripts[name] == sc.SHA256
	return sc, nil
}

// ignoredRootCopy reports whether the root's scripts/<name> is a gitignored regular file holding the
// bytes whose SHA-256 is digest. A workroom's copy can hold them too: the include step copies
// ignored files into a new workroom before its setup script runs. An ignored symlink is not exempt:
// what it points to may be tracked, and a pull can change it.
func ignoredRootCopy(dir, name, digest string) bool {
	rel := filepath.Join("scripts", name)
	path := filepath.Join(dir, rel)
	if info, err := os.Lstat(path); err != nil || !info.Mode().IsRegular() {
		return false
	}
	text, err := readScript(path)
	if err != nil {
		return false
	}
	sum := sha256.Sum256(text)
	return hex.EncodeToString(sum[:]) == digest && vcs.Ignored(dir, rel)
}

// MaxScriptBytes is the largest script Workroom will read to judge: a setup or teardown script is a
// short program, and one that is a link to a device (/dev/zero) or a huge file must not be read
// without end.
const MaxScriptBytes = 1 << 20

// readScript is the regular file at path, following a symlink, refusing anything else or anything
// over MaxScriptBytes.
func readScript(path string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%w: %s is not a regular file", ErrScriptNotTrusted, path)
	}
	if info.Size() > MaxScriptBytes {
		return nil, fmt.Errorf("%w: %s is larger than %d bytes", ErrScriptNotTrusted, path, MaxScriptBytes)
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	text, err := io.ReadAll(io.LimitReader(f, MaxScriptBytes+1))
	if err == nil && len(text) > MaxScriptBytes {
		return nil, fmt.Errorf("%w: %s is larger than %d bytes", ErrScriptNotTrusted, path, MaxScriptBytes)
	}
	return text, err
}

// fileScript judges the script file at path, or reports false when there is none.
func (s *Service) fileScript(dir, name, origin, path string) (Script, bool, error) {
	text, err := readScript(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Script{}, false, nil
	}
	if err != nil {
		return Script{}, false, err
	}
	sc, err := s.JudgeScript(dir, name, origin, path, text)
	return sc, true, err
}

// foundScript judges the file findScript found for a workroom at wrPath.
func (s *Service) foundScript(dir, name, wrPath, path string) (Script, bool, error) {
	origin := OriginRoot
	if filepath.Dir(filepath.Dir(path)) == wrPath {
		origin = OriginWorkroom
	}
	return s.fileScript(dir, name, origin, path)
}

// SetupScriptAt judges the setup script a create starting from start ("" is HEAD) would run: the
// base commit's, which the new checkout holds, else the root's copy. It reports false when neither
// has one.
func (s *Service) SetupScriptAt(dir, start string) (Script, bool, error) {
	text, ok, err := vcs.FileAt(dir, start, "scripts/"+SetupScript)
	if errors.Is(err, vcs.ErrLinkOutside) {
		// Its bytes can't be known until the checkout exists: the check just before it runs judges
		// them.
		return Script{}, false, nil
	}
	if err != nil {
		return Script{}, false, fmt.Errorf("%w: %v", ErrVCSCommand, err)
	}
	if ok {
		// As readScript refuses it later, before a worktree or a host exists rather than after.
		if len(text) > MaxScriptBytes {
			return Script{}, false, fmt.Errorf("%w: scripts/%s in the base commit is larger than %d bytes", ErrScriptNotTrusted, SetupScript, MaxScriptBytes)
		}
		sc, err := s.JudgeScript(dir, SetupScript, OriginBase, "", text)
		return sc, true, err
	}
	return s.fileScript(dir, SetupScript, OriginRoot, filepath.Join(dir, "scripts", SetupScript))
}

// RootScript judges the root's copy of script name, or reports false when it has none.
func (s *Service) RootScript(dir, name string) (Script, bool, error) {
	return s.fileScript(dir, name, OriginRoot, filepath.Join(dir, "scripts", name))
}

// ProjectScripts judges the scripts project dir would run next: the setup script a create would
// run, at the base it resolves and fetches as a create does, and the root's teardown copy. A
// script that is nowhere is left out. A base that cannot be resolved is an error.
func (s *Service) ProjectScripts(dir string) ([]Script, vcs.LocalWork, error) {
	base, global, err := s.base(dir)
	if err != nil {
		return nil, vcs.LocalWork{}, err
	}
	return s.projectScripts(dir, base, global)
}

// ProjectScriptsFrom is ProjectScripts with new workrooms starting from base ("" is origin's
// default branch) rather than the project's: what a remote create checks out, which may differ.
// The local work is what that start leaves out of the main checkout, as a create would find it.
func (s *Service) ProjectScriptsFrom(dir, base string) ([]Script, vcs.LocalWork, error) {
	return s.projectScripts(dir, base, false)
}

func (s *Service) projectScripts(dir, base string, global bool) ([]Script, vcs.LocalWork, error) {
	var work vcs.LocalWork
	if err := s.detectVCS(dir); err != nil {
		return nil, work, err
	}
	start, warning, err := s.VCS.StartPoint(dir, base, global, vcs.Progress{})
	if err != nil {
		return nil, work, err
	}
	// As a create does: not against a start that already warns.
	if warning == "" {
		work = s.VCS.LocalWork(dir, start)
	}
	var scripts []Script
	setup, ok, err := s.SetupScriptAt(dir, start)
	if err != nil {
		return nil, work, err
	}
	if ok {
		scripts = append(scripts, setup)
	}
	teardown, ok, err := s.RootScript(dir, TeardownScript)
	if err != nil {
		return nil, work, err
	}
	if ok {
		scripts = append(scripts, teardown)
	}
	return scripts, work, nil
}

// gateSetup is gate for the setup script a create starting from start would run, if any.
func (s *Service) gateSetup(dir, start string) error {
	sc, ok, err := s.SetupScriptAt(dir, start)
	if err != nil || !ok {
		return err
	}
	return s.gate(dir, sc)
}

// gateRootSetup is gate for the root's working copy of the setup script: what a create that copies
// the main checkout's changes in runs, edits and all, so an edited script is judged, and can be
// approved, before anything exists.
func (s *Service) gateRootSetup(dir string) error {
	sc, ok, err := s.RootScript(dir, SetupScript)
	if err != nil || !ok {
		return err
	}
	return s.gate(dir, sc)
}

// gateFound is gate for the file findScript found, about to run in the workroom at wrPath.
func (s *Service) gateFound(dir, name, wrPath, path string) error {
	sc, ok, err := s.foundScript(dir, name, wrPath, path)
	if err != nil || !ok || sc.Trusted {
		return err
	}
	if err := s.gate(dir, sc); err != nil {
		return err
	}
	// The person read the file while it sat on disk, as long as the prompt stayed open: the bytes
	// that now run must still be the ones they approved.
	now, ok, err := s.foundScript(dir, name, wrPath, path)
	if err != nil || !ok {
		return err
	}
	if now.SHA256 != sc.SHA256 {
		return &UntrustedScriptError{Script: now}
	}
	return nil
}

// gate lets a trusted script through. An untrusted one goes to ApproveScriptFn when there is one,
// whose yes records the approval and whose no cancels; without it, it is refused.
func (s *Service) gate(dir string, sc Script) error {
	if sc.Trusted {
		return nil
	}
	if s.ApproveScriptFn == nil {
		return &UntrustedScriptError{Script: sc}
	}
	ok, err := s.ApproveScriptFn(sc)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("%w: scripts/%s was not approved", ErrCancelled, sc.Name)
	}
	return s.Trust(dir, sc)
}

// Trust records sc's bytes as approved for project dir, registering the project if it is not yet.
func (s *Service) Trust(dir string, sc Script) error {
	if s.Pretend {
		return nil
	}
	if err := s.Config.AddProject(dir, string(vcs.TypeGit)); err != nil {
		return err
	}
	return s.Config.SetTrustedScript(dir, sc.Name, sc.SHA256)
}

// Untrust forgets every approval of project dir's scripts.
func (s *Service) Untrust(dir string) error {
	if s.Pretend {
		return nil
	}
	for _, name := range []string{SetupScript, TeardownScript} {
		if err := s.Config.SetTrustedScript(dir, name, ""); err != nil {
			return err
		}
	}
	return nil
}
