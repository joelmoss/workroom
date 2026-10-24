package vcs

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/joelmoss/workroom/internal/errs"
)

// Type represents a VCS type.
type Type string

const (
	TypeGit Type = "git"
)

// Progress receives a create's step events and the git output behind them. Both fields are
// optional. Step states are running, done, warning, skipped and failed; detail is the warning
// text, the skip reason or the failure message.
type Progress struct {
	Log  io.Writer
	Step func(id, state, detail string)
	// BeforeWorktree, when set, is called with the start point once it is resolved and before
	// the workspace exists ("" is HEAD), with the local work that start leaves out. It returns the
	// start to use instead (the local branch, when the user chose it); an error ends the create
	// there.
	BeforeWorktree func(start string, work LocalWork) (string, error)
	// StartCommit, when set, is the start point a create question was asked about, the commit a
	// QuestionError reported (ADR 0059). The answer's create fetches nothing, resolves the start
	// point from the refs already here and starts from this commit instead of where its ref points.
	StartCommit string
}

// LocalWork is what a create starting from a remote's copy of a branch leaves behind in the main
// checkout: commits on the local branch the remote's copy lacks, and uncommitted changes when the
// main checkout has that branch out. Changes on another branch aren't the base branch's, so they
// don't count.
type LocalWork struct {
	// Branch is the base branch's local name, such as master; "" when there is no local branch to
	// compare, and nothing else is set.
	Branch string
	// Remote is the remote whose copy of Branch the create starts from, such as origin.
	Remote string
	// Ahead is how many commits the local branch has that the start lacks.
	Ahead int
	// Uncommitted is true when the main checkout is on Branch with changes git hasn't committed:
	// modified, staged or untracked files.
	Uncommitted bool
	// Behind is how many commits the start has that the local branch lacks: what starting from the
	// local branch would leave out instead.
	Behind int
	// Stale is true when the start already came with a warning (a failed fetch, a fallback), so the
	// counts are against a remote copy that may be out of date: nobody is asked, though a start
	// chosen beforehand still holds.
	Stale bool
}

// Any reports whether there is local work a create would leave out.
func (w LocalWork) Any() bool { return w.Ahead > 0 || w.Uncommitted }

// Summary says what the work is, plainly, for a person: "You have 2 commits on master that you
// haven't pushed yet, and some changes you haven't committed". "" when there is none.
func (w LocalWork) Summary() string {
	commits := "commits"
	if w.Ahead == 1 {
		commits = "commit"
	}
	switch {
	case w.Ahead > 0 && w.Uncommitted:
		return fmt.Sprintf("You have %d %s on %s that you haven't pushed yet, and some changes you haven't committed", w.Ahead, commits, w.Branch)
	case w.Ahead > 0:
		return fmt.Sprintf("You have %d %s on %s that you haven't pushed yet", w.Ahead, commits, w.Branch)
	case w.Uncommitted:
		return fmt.Sprintf("You have changes on %s that you haven't committed yet", w.Branch)
	}
	return ""
}

// BehindNote says, plainly, what including the work would leave out instead, when the local branch
// lacks commits the remote has: "Your master is also 3 commits behind origin, so including your
// work starts from your older copy.". "" when it isn't behind.
func (w LocalWork) BehindNote() string {
	if w.Behind == 0 {
		return ""
	}
	commits := "commits"
	if w.Behind == 1 {
		commits = "commit"
	}
	return fmt.Sprintf("Your %s is also %d %s behind %s, so including your work starts from your older copy.", w.Branch, w.Behind, commits, w.Remote)
}

func (p Progress) step(id, state, detail string) {
	if p.Step != nil {
		p.Step(id, state, detail)
	}
}

// VCS defines the interface for version control operations on workrooms.
type VCS interface {
	Type() Type
	Label() string
	// Create makes the workspace, starting from base when non-empty, and returns a warning
	// for the user, or "". fallback marks base as the app-wide default, which gives way to
	// origin's default branch in a project it doesn't fit.
	Create(dir, vcsName, path, base string, fallback bool, progress Progress) (string, error)
	// StartPoint resolves, fetching first, where Create would start from base, without making
	// anything: the ref ("" is HEAD) and a warning for the user, or "".
	StartPoint(dir, base string, fallback bool, progress Progress) (start, warning string, err error)
	// LocalWork is what starting from start, a resolved start point, leaves out of the main
	// checkout at dir. Empty unless start is a remote's branch.
	LocalWork(dir, start string) LocalWork
	Delete(dir, vcsName, path string) (string, error)
	// ListWorkrooms is the sole membership primitive: a caller that needs an existence check
	// lists once and does an in-memory lookup, rather than the interface exposing a second
	// method that looks like a cheap single-name check but is secretly a full list-and-scan.
	ListWorkrooms(dir string) ([]string, error)
}

// Detect returns the Git VCS when dir is itself a git repository (see IsGitRepo).
func Detect(dir string) (VCS, error) {
	if IsGitRepo(dir) {
		return &Git{Executor: &RealExecutor{}}, nil
	}
	return nil, errs.ErrUnsupportedVCS
}

// IsGitRepo reports whether dir is itself a git repository root, by the same rule git applies
// before it would otherwise walk up to an ancestor: a .git directory holding HEAD, objects/ and
// refs/, or a .git file (a linked worktree) that starts with "gitdir:". An empty or partial .git
// (e.g. one Jujutsu left before #266) is not one.
func IsGitRepo(dir string) bool {
	gitPath := filepath.Join(dir, ".git")
	info, err := os.Stat(gitPath)
	if err != nil {
		return false
	}
	if info.Mode().IsRegular() {
		f, err := os.Open(gitPath)
		if err != nil {
			return false
		}
		defer f.Close()
		head := make([]byte, len("gitdir:"))
		n, _ := f.Read(head)
		return string(head[:n]) == "gitdir:"
	}
	if !info.IsDir() {
		return false
	}
	if head, err := os.Stat(filepath.Join(gitPath, "HEAD")); err != nil || !head.Mode().IsRegular() {
		return false
	}
	for _, sub := range []string{"objects", "refs"} {
		if d, err := os.Stat(filepath.Join(gitPath, sub)); err != nil || !d.IsDir() {
			return false
		}
	}
	return true
}

// InitGit initializes a new Git repository at dir with an initial empty commit,
// so the directory is immediately usable as a Workroom project (workrooms can be
// created without the user first making a commit). The empty commit's identity
// and signing are pinned so it succeeds with no global git config — see
// (*Git).InitialCommit. Returns the raw command error for the caller to wrap.
func InitGit(dir string) error {
	g := &Git{Executor: &RealExecutor{}}
	if _, err := g.Init(dir); err != nil {
		return err
	}
	_, err := g.InitialCommit(dir)
	return err
}

// New constructs a VCS implementation from a stored type string (e.g. the "vcs"
// field persisted in config), without touching the filesystem. Used when listing
// workrooms for a project whose directory may not currently exist.
func New(t Type) (VCS, error) {
	switch t {
	case TypeGit:
		return &Git{Executor: &RealExecutor{}}, nil
	default:
		return nil, errs.ErrUnsupportedVCS
	}
}
