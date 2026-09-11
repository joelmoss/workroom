//go:build !windows

package script

import (
	"os/exec"
	"syscall"
)

// setProcessGroup puts the script in its own process group so it can be killed as a tree.
func setProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// killProcessGroup terminates the script's whole group. Best-effort: it may already be gone.
func killProcessGroup(cmd *exec.Cmd) {
	if cmd.Process != nil {
		// Negative pid = the whole group.
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
}
