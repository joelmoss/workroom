package workroom

import "github.com/joelmoss/workroom/internal/errs"

// Re-export errors for convenience.
var (
	ErrInWorkroom          = errs.ErrInWorkroom
	ErrUnsupportedVCS      = errs.ErrUnsupportedVCS
	ErrInvalidName         = errs.ErrInvalidName
	ErrDirExists           = errs.ErrDirExists
	ErrJJWorkspaceExists   = errs.ErrJJWorkspaceExists
	ErrGitWorktreeExists   = errs.ErrGitWorktreeExists
	ErrJJWorkspaceNotFound = errs.ErrJJWorkspaceNotFound
	ErrGitWorktreeNotFound = errs.ErrGitWorktreeNotFound
	ErrSetup               = errs.ErrSetup
	ErrTeardown            = errs.ErrTeardown
)
