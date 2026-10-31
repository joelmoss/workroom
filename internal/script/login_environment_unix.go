//go:build !windows

package script

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// spawnPath is what the shell starts from, so a login shell composes PATH as it would in a terminal:
// path_helper appends the PATH it's handed, which would push Homebrew behind /usr/bin.
const spawnPath = "/usr/bin:/bin:/usr/sbin:/sbin"

// maxLoginOutput caps what's kept of the shell's output, should an rc print without end.
const maxLoginOutput = 1 << 20

// loginReadTimeout matches workroomd run-script's: slow rc files cost one wait, and a script runs once.
var loginReadTimeout = 10 * time.Second

// loginEnvironment reads what the user's login shell sets up in dir, as a terminal opened there would
// (#560): one bounded `<shell> -lic` printing `env -0` between markers, the way ShellEnvironment.probe
// and `workroomd run-script` read it. A read rather than running the script through the shell, because
// an rc that ends in `exec` or `exit` would then skip the script and still report success.
//
// Only call it for a script that has passed the trust check: the rc can read dir's local tool config.
// Any failure returns this process's own environment and the reason, so the script still runs.
func loginEnvironment(dir string) (env []string, problem string) {
	probed, problem := readLoginShell(dir, os.Getenv("SHELL"))
	if problem != "" {
		return os.Environ(), problem
	}
	return mergeLoginEnvironment(probed), ""
}

func readLoginShell(dir, shell string) (map[string]string, string) {
	mark := rand.Text()
	line := "printf '%s' '" + mark + "'; env -0; printf '%s' '" + mark + "'"

	ctx, cancel := context.WithTimeout(context.Background(), loginReadTimeout)
	defer cancel()
	program, flag := loginShellInvocation(shell)
	cmd := exec.CommandContext(ctx, program, flag, line)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "PATH="+spawnPath, "WORKROOM_SHELL_PROBE=1")
	// A new session, not just a new group: an interactive shell in a background group of a terminal
	// is stopped by SIGTTOU, which would hang `workroom create`. With no terminal it can't be.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	// A background job the rc started can hold the pipe open after the shell exits.
	cmd.WaitDelay = time.Second
	var out cappedBuffer
	cmd.Stdout = &out // stdin and stderr stay nil, /dev/null: an rc can prompt, and its noise isn't ours

	if err := cmd.Start(); err != nil {
		return nil, "spawnFailed"
	}
	err := cmd.Wait()
	switch {
	case ctx.Err() != nil:
		return nil, "timedOut"
	case err != nil && !errors.Is(err, exec.ErrWaitDelay):
		return nil, "nonZeroExit"
	}
	probed := parseLoginOutput(out.Bytes(), mark)
	if probed == nil {
		return nil, "noMarkers"
	}
	if _, ok := probed["PATH"]; !ok {
		return nil, "noPath"
	}
	return probed, ""
}

// loginShellInvocation is `shell -lic` when it is a shell known to take that, else a login /bin/sh, as
// ShellEnvironment.posixShells and workroomd's probe_invocation decide it.
func loginShellInvocation(shell string) (program, flag string) {
	switch filepath.Base(shell) {
	case "zsh", "bash", "sh", "dash", "ksh":
		return shell, "-lic"
	}
	return "/bin/sh", "-lc"
}

// parseLoginOutput returns the variables between the first marker and the next, or nil. rc noise
// arrives on both sides of them.
func parseLoginOutput(data []byte, mark string) map[string]string {
	_, rest, ok := bytes.Cut(data, []byte(mark))
	if !ok {
		return nil
	}
	payload, _, ok := bytes.Cut(rest, []byte(mark))
	if !ok {
		return nil
	}
	vars := map[string]string{}
	for entry := range bytes.SplitSeq(payload, []byte{0}) {
		if name, value, ok := strings.Cut(string(entry), "="); ok && name != "" {
			vars[name] = value
		}
	}
	return vars
}

// mergeLoginEnvironment drops the probe shell's own state, keeps git's safety settings from any rc,
// and adds this process's PATH after the shell's so the script loses nothing it had.
func mergeLoginEnvironment(probed map[string]string) []string {
	path := unionPath(probed["PATH"], os.Getenv("PATH"))
	for _, name := range []string{"PWD", "OLDPWD", "SHLVL", "_", "WORKROOM_SHELL_PROBE"} {
		delete(probed, name)
	}
	for _, name := range []string{"GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS"} {
		if value, ok := os.LookupEnv(name); ok {
			probed[name] = value
		}
	}
	probed["PATH"] = path
	env := make([]string, 0, len(probed))
	for name, value := range probed {
		env = append(env, name+"="+value)
	}
	return env
}

func unionPath(first, second string) string {
	seen := map[string]bool{}
	var entries []string
	for entry := range strings.SplitSeq(first+":"+second, ":") {
		if entry != "" && !seen[entry] {
			seen[entry] = true
			entries = append(entries, entry)
		}
	}
	return strings.Join(entries, ":")
}

// cappedBuffer keeps the first maxLoginOutput bytes and drains the rest, so the shell never blocks.
type cappedBuffer struct{ bytes.Buffer }

func (b *cappedBuffer) Write(p []byte) (int, error) {
	if room := maxLoginOutput - b.Len(); room > 0 {
		b.Buffer.Write(p[:min(room, len(p))])
	}
	return len(p), nil
}
