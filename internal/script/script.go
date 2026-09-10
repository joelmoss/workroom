package script

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"github.com/joelmoss/workroom/internal/errs"
)

// Run executes a user script in the given workroom directory with environment variables set.
// Combined stdout+stderr is always captured and returned. When stream is non-nil it also
// receives that output live as the script runs, letting callers render a log panel.
//
// The script (setup or teardown) runs with its working directory set to the workroom, and with
// these environment variables available:
//
//	WORKROOM_NAME        the workroom's name
//	WORKROOM_PATH        absolute path to the workroom directory
//	WORKROOM_ROOT_PATH   absolute path to the root project the workroom belongs to
//	WORKROOM_PARENT_DIR  deprecated alias for WORKROOM_ROOT_PATH (kept for existing scripts)
//
// On failure the returned error embeds the captured output only when stream is nil; when a
// stream was provided the output has already been shown, so the error stays concise to avoid
// printing it twice.
func Run(scriptType, scriptPath, workroomDir, name, rootPath string, stream io.Writer) (string, error) {
	if _, err := os.Stat(scriptPath); os.IsNotExist(err) {
		return "", nil
	}

	cmd := exec.Command(scriptPath)
	// Give the script its own process group so it can be killed as a TREE. A setup script is
	// typically a shell that forks further (npm, bundle, cargo); killing only the script's own pid
	// leaves those grandchildren writing the worktree. The macOS app relies on this: its CLI call has
	// a timeout, and on expiry it terminates THIS process — after which it treats the worktree as
	// settled and re-allows deletion. Without the group, a quiet installer outlived that and kept
	// writing files a teardown was already removing.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Dir = workroomDir
	cmd.Env = append(os.Environ(),
		"WORKROOM_NAME="+name,
		"WORKROOM_PATH="+workroomDir,
		"WORKROOM_ROOT_PATH="+rootPath,
		// Deprecated: superseded by WORKROOM_ROOT_PATH; kept so existing scripts keep working.
		"WORKROOM_PARENT_DIR="+rootPath,
	)

	var buf bytes.Buffer
	var sink io.Writer = &buf
	if stream != nil {
		sink = io.MultiWriter(&buf, stream)
	}
	cmd.Stdout = sink
	cmd.Stderr = sink

	if err := cmd.Start(); err != nil {
		return "", err
	}
	// Take the script's whole process group down with us when we're terminated. `Setpgid` above only
	// makes the tree killable; nothing kills it unless we ask, and the default SIGTERM disposition
	// exits this process immediately — orphaning the group to keep writing. Installed only for the
	// script's lifetime, and stopped in every exit path so a long-lived caller keeps its own default
	// handling. SIGKILL cannot be caught, which is why the app's timeout sends SIGTERM first.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	done := make(chan struct{})
	go func() {
		select {
		case sig := <-sigs:
			if cmd.Process != nil {
				// Negative pid = the whole group. Best-effort: the group may already be gone.
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
			}
			signal.Stop(sigs)
			// Re-raise so the caller's own exit status still reflects the signal it was sent.
			if s, ok := sig.(syscall.Signal); ok {
				_ = syscall.Kill(os.Getpid(), s)
			}
		case <-done:
		}
	}()

	err := cmd.Wait()
	close(done)
	signal.Stop(sigs)
	output := buf.String()

	if err != nil {
		sentinel := errs.ErrSetup
		if scriptType != "setup" {
			sentinel = errs.ErrTeardown
		}
		if stream != nil {
			return output, fmt.Errorf("%w: %s returned a non-zero exit code", sentinel, scriptPath)
		}
		return output, fmt.Errorf("%w: %s returned a non-zero exit code.\n%s", sentinel, scriptPath, output)
	}

	return output, nil
}
