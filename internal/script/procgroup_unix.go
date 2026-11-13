//go:build !windows

package script

import (
	"os/exec"
	"syscall"
)

// SetProcessGroup puts the child in its own process group so it can be killed as a tree.
func SetProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// KillProcessGroup terminates the child's whole group. Best-effort: it may already be gone.
func KillProcessGroup(cmd *exec.Cmd) {
	if cmd.Process != nil {
		// Negative pid = the whole group.
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
}
