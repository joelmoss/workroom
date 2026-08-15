package vcs

import (
	"os"
	"path/filepath"

	"github.com/joelmoss/workroom/internal/errs"
)

// Type represents a VCS type.
type Type string

const (
	TypeJJ  Type = "jj"
	TypeGit Type = "git"
)

// VCS defines the interface for version control operations on workrooms.
type VCS interface {
	Type() Type
	Label() string
	Create(dir, vcsName, path string) (string, error)
	Delete(dir, vcsName, path string) (string, error)
	// ListWorkrooms is the sole membership primitive: a caller that needs an existence check
	// lists once and does an in-memory lookup, rather than the interface exposing a second
	// method that looks like a cheap single-name check but is secretly a full list-and-scan.
	ListWorkrooms(dir string) ([]string, error)
}

// Detect determines the VCS type by checking for .jj then .git directories.
func Detect(dir string) (VCS, error) {
	if info, err := os.Stat(filepath.Join(dir, ".jj")); err == nil && info.IsDir() {
		return &JJ{Executor: &RealExecutor{}}, nil
	}
	if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
		// .git can be a directory (normal repo) or a file (worktree)
		return &Git{Executor: &RealExecutor{}}, nil
	}
	return nil, errs.ErrUnsupportedVCS
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
	case TypeJJ:
		return &JJ{Executor: &RealExecutor{}}, nil
	case TypeGit:
		return &Git{Executor: &RealExecutor{}}, nil
	default:
		return nil, errs.ErrUnsupportedVCS
	}
}
