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

// SetSession starts the child in a session of its own, which also makes it its own process group
// leader, so KillProcessGroup and KillProcessGroupHard reach its whole tree. With no controlling
// terminal, an ssh it starts can't prompt on (or be stopped by) the caller's terminal: it fails
// instead. (Setpgid as well would make the start fail: a session leader can't change its group.)
func SetSession(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

// KillProcessGroup terminates the child's whole group. Best-effort: it may already be gone.
func KillProcessGroup(cmd *exec.Cmd) {
	if cmd.Process != nil {
		// Negative pid = the whole group.
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
}

// KillProcessGroupHard SIGKILLs the child's whole group, for what ignored KillProcessGroup's
// SIGTERM. Best-effort: it may already be gone.
func KillProcessGroupHard(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}
