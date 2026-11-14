package workroom

import (
	"errors"
	"os"
	"syscall"
)

// processAlive reports whether a process with this pid is running: Windows opens a handle only to a
// process that exists. A process this user may not open is running too, which keeps its staging.
func processAlive(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return errors.Is(err, syscall.ERROR_ACCESS_DENIED)
	}
	_ = p.Release()
	return true
}
