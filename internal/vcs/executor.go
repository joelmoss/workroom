package vcs

import (
	"os/exec"
	"strings"
)

// CommandExecutor abstracts shell command execution for testability.
type CommandExecutor interface {
	Run(dir string, name string, args ...string) (string, error)
}

// RealExecutor runs actual shell commands.
type RealExecutor struct{}

func (r *RealExecutor) Run(dir string, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}
