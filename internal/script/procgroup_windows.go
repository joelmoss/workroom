package script

import "os/exec"

// Windows has no process groups in the POSIX sense, so the script gets no group of its own and
// only the script process itself is terminated. Grandchildren an installer forks are left to the
// OS; the caller's timeout still gets its process back.
//
// ponytail: grandchildren orphaned on Windows; Job Objects if it ever matters.
func setProcessGroup(_ *exec.Cmd) {}

func killProcessGroup(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}
