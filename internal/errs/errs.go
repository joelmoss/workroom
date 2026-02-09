package errs

import "errors"

var (
	ErrInWorkroom          = errors.New("looks like you are already in a workroom. Run this command from the root of your main development directory, not from within an existing workroom")
	ErrUnsupportedVCS      = errors.New("no supported VCS detected in this directory. Workroom requires either Git or Jujutsu to manage workspaces")
	ErrInvalidName         = errors.New("workroom name must be alphanumeric (dashes and underscores allowed), and must not start or end with a dash or underscore")
	ErrDirExists           = errors.New("workroom directory already exists")
	ErrJJWorkspaceExists   = errors.New("JJ workspace already exists")
	ErrGitWorktreeExists   = errors.New("Git worktree already exists")
	ErrJJWorkspaceNotFound = errors.New("JJ workspace does not exist")
	ErrGitWorktreeNotFound = errors.New("Git worktree does not exist")
	ErrSetup               = errors.New("setup script failed")
	ErrTeardown            = errors.New("teardown script failed")
)
