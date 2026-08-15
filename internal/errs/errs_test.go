package errs

import (
	"fmt"
	"testing"
)

func TestCodeAndExitCode(t *testing.T) {
	for _, c := range registry {
		t.Run(c.code, func(t *testing.T) {
			// Wrapped, not the bare sentinel, so the errors.Is path is exercised the same way
			// production call sites (fmt.Errorf("...: %w", ErrX)) actually construct these.
			wrapped := fmt.Errorf("wrap: %w", c.err)
			if got := Code(wrapped); got != c.code {
				t.Fatalf("Code() = %q, want %q", got, c.code)
			}
			if got := ExitCode(wrapped); got != c.exitCode {
				t.Fatalf("ExitCode() = %d, want %d", got, c.exitCode)
			}
		})
	}
}

func TestCodeAndExitCodeNil(t *testing.T) {
	if got := Code(nil); got != "" {
		t.Fatalf("Code(nil) = %q, want empty", got)
	}
	if got := ExitCode(nil); got != 0 {
		t.Fatalf("ExitCode(nil) = %d, want 0", got)
	}
}

func TestCodeAndExitCodeUnrecognized(t *testing.T) {
	err := fmt.Errorf("something else entirely")
	if got := Code(err); got != "InternalError" {
		t.Fatalf("Code() = %q, want InternalError", got)
	}
	if got := ExitCode(err); got != 1 {
		t.Fatalf("ExitCode() = %d, want 1", got)
	}
}

func TestRegistryCoversEveryPublicSentinel(t *testing.T) {
	// Every exported Err* var must have a registry entry — a new sentinel added without one
	// would silently fall through to InternalError/exit 1.
	sentinels := []error{
		ErrInWorkroom, ErrUnsupportedVCS, ErrNotDirectory, ErrInvalidName, ErrDirExists,
		ErrJJWorkspaceExists, ErrGitWorktreeExists, ErrJJWorkspaceNotFound, ErrGitWorktreeNotFound,
		ErrSetup, ErrTeardown, ErrConfirmMismatch, ErrUnsafeDeletePath, ErrCancelled,
		ErrConfigRead, ErrConfigWrite, ErrVCSCommand,
	}
	if len(registry) != len(sentinels) {
		t.Fatalf("registry has %d entries, expected %d (one per exported sentinel)", len(registry), len(sentinels))
	}
	for _, s := range sentinels {
		if _, ok := classify(s); !ok {
			t.Fatalf("sentinel %v has no registry entry", s)
		}
	}
}
