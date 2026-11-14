//go:build !windows

package workroom

import (
	"errors"
	"syscall"
)

// processAlive reports whether a process with this pid is running. A process this user may not
// signal (EPERM) is running too: the answer errs toward alive, which keeps its staging.
func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
