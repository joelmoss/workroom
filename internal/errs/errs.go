package errs

import "errors"

var (
	ErrInWorkroom          = errors.New("looks like you are already in a workroom. Run this command from the root of your main development directory, not from within an existing workroom")
	ErrUnsupportedVCS      = errors.New("no supported VCS detected in this directory. Workroom requires Git to manage workspaces")
	ErrNotDirectory        = errors.New("path exists but is not a directory")
	ErrInvalidName         = errors.New("workroom name must be alphanumeric (dashes and underscores allowed), and must not start or end with a dash or underscore")
	ErrDirExists           = errors.New("workroom directory already exists")
	ErrGitWorktreeExists   = errors.New("git worktree already exists")
	ErrGitWorktreeNotFound = errors.New("git worktree does not exist")
	ErrSetup               = errors.New("setup script failed")
	ErrTeardown            = errors.New("teardown script failed")
	ErrConfirmMismatch     = errors.New("confirmation value does not match the workroom name")
	ErrUnsafeDeletePath    = errors.New("refusing to delete an unsafe or reserved path")
	ErrCancelled           = errors.New("operation cancelled")
	ErrConfigRead          = errors.New("failed to read config")
	ErrConfigWrite         = errors.New("failed to write config")
	ErrVCSCommand          = errors.New("version control command failed")
	ErrRemoteProject       = errors.New("remote projects are not supported: add the project from a local Git repository. A remote workroom belongs to a local project")
	ErrRemoteWorkroom      = errors.New("not supported for a remote workroom yet")
	ErrProjectNotFound     = errors.New("project is not registered")
	ErrWorkroomNotFound    = errors.New("workroom is not registered")
	ErrInvalidHost         = errors.New("a host descriptor must be a JSON object")
	ErrWorkroomExists      = errors.New("a workroom of that name is already registered")
)

// classification is one sentinel error's entry in the registry: its stable --json code and
// its process exit code. Kept in one table (a slice, not a map, so a future error that wraps
// more than one sentinel resolves deterministically to the first match) instead of two
// independently-hand-maintained switches, which had already drifted apart in shape: Code
// switched on the sentinel, ExitCode re-derived its answer from Code's STRING OUTPUT rather
// than the original error.
type classification struct {
	err      error
	code     string
	exitCode int
}

var registry = []classification{
	{ErrInWorkroom, "InWorkroom", 3},
	{ErrUnsupportedVCS, "UnsupportedVCS", 3},
	{ErrNotDirectory, "NotADirectory", 3},
	{ErrInvalidName, "InvalidName", 3},
	{ErrDirExists, "DirExists", 3},
	{ErrGitWorktreeExists, "WorkspaceExists", 3},
	{ErrGitWorktreeNotFound, "WorkspaceNotFound", 3},
	{ErrConfirmMismatch, "ConfirmationMismatch", 2},
	{ErrUnsafeDeletePath, "UnsafeDeletePath", 2},
	{ErrCancelled, "Cancelled", 4},
	{ErrSetup, "SetupScriptFailed", 5},
	{ErrTeardown, "TeardownScriptFailed", 5},
	{ErrConfigRead, "ConfigReadFailed", 6},
	{ErrConfigWrite, "ConfigWriteFailed", 6},
	{ErrVCSCommand, "VCSCommandFailed", 1},
	{ErrRemoteProject, "RemoteProjectUnsupported", 3},
	{ErrRemoteWorkroom, "RemoteWorkroomUnsupported", 3},
	{ErrProjectNotFound, "ProjectNotFound", 3},
	{ErrWorkroomNotFound, "WorkroomNotFound", 3},
	{ErrInvalidHost, "InvalidHostDescriptor", 2},
	{ErrWorkroomExists, "WorkroomExists", 3},
}

func classify(err error) (classification, bool) {
	for _, c := range registry {
		if errors.Is(err, c.err) {
			return c, true
		}
	}
	return classification{}, false
}

// Code returns a stable, machine-readable identifier for an error, suitable for
// inclusion in the --json contract. Downstream consumers branch on the code, not
// the human message (which may change). Unrecognised errors map to "InternalError".
func Code(err error) string {
	if err == nil {
		return ""
	}
	if c, ok := classify(err); ok {
		return c.code
	}
	return "InternalError"
}

// ExitCode maps an error to a stable process exit code so non-interactive callers
// can distinguish failure classes:
//
//	0 success · 2 usage/validation · 3 domain precondition/not-found ·
//	4 cancelled/no-op · 5 setup/teardown · 6 config read/write/parse · 1 internal.
func ExitCode(err error) int {
	if err == nil {
		return 0
	}
	if c, ok := classify(err); ok {
		return c.exitCode
	}
	return 1
}
