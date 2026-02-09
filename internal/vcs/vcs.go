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
	WorkroomExists(dir, name string) (bool, error)
	Create(dir, vcsName, path string) (string, error)
	Delete(dir, vcsName, path string) (string, error)
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
