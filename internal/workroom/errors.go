package workroom

import "github.com/joelmoss/workroom/internal/errs"

// Re-export errors for convenience.
var (
	ErrInWorkroom          = errs.ErrInWorkroom
	ErrUnsupportedVCS      = errs.ErrUnsupportedVCS
	ErrInvalidName         = errs.ErrInvalidName
	ErrDirExists           = errs.ErrDirExists
	ErrGitWorktreeExists   = errs.ErrGitWorktreeExists
	ErrGitWorktreeNotFound = errs.ErrGitWorktreeNotFound
	ErrSetup               = errs.ErrSetup
	ErrTeardown            = errs.ErrTeardown
	ErrConfirmMismatch     = errs.ErrConfirmMismatch
	ErrCancelled           = errs.ErrCancelled
	ErrVCSCommand          = errs.ErrVCSCommand
	ErrRemoteWorkroom      = errs.ErrRemoteWorkroom
)
