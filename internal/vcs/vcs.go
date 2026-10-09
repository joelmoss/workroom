package vcs

import (
	"os"
	"path/filepath"

	"github.com/joelmoss/workroom/internal/errs"
)

// Type represents a VCS type.
type Type string

const (
	TypeGit Type = "git"
)

// VCS defines the interface for version control operations on workrooms.
type VCS interface {
	Type() Type
	Label() string
	// Create makes the workspace, starting from base when non-empty, and returns a warning
	// for the user, or "".
	Create(dir, vcsName, path, base string) (string, error)
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
