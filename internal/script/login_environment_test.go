//go:build !windows

package script

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// loginShellWith makes bash the user's shell, with `profile` as its login profile in a fresh HOME.
func loginShellWith(t *testing.T, profile string) {
	t.Helper()
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".bash_profile"), []byte(profile), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("SHELL", "/bin/bash")
}

// A workroom script that prints the given lines, one shell word each.
func scriptPrinting(t *testing.T, dir string, lines ...string) string {
	t.Helper()
	body := "#!/bin/sh\n"
	for _, line := range lines {
		body += "echo \"" + line + "\"\n"
	}
	// Outside the workroom's own listing, as a root's script is; the name doesn't matter to Run.
	path := filepath.Join(t.TempDir(), "workroom_script")
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func workroomDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// #560: what a directory-aware shell integration selects for the workroom is what the script gets,
// as it would from a terminal opened there.
func TestRunGivesTheScriptWhatTheLoginShellSelectsInTheWorkroom(t *testing.T) {
	for _, scriptType := range []string{"setup", "teardown"} {
		t.Run(scriptType, func(t *testing.T) {
			loginShellWith(t, "export SELECTED_FOR=\"$(pwd -P)\"\n")
			dir := workroomDir(t)

			output, err := Run(scriptType, scriptPrinting(t, dir, "selected=$SELECTED_FOR"), dir, "wr", "/root", nil)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if want := "selected=" + dir + "\n"; output != want {
				t.Fatalf("the script saw %q, want %q", output, want)
			}
		})
	}
}

// An rc that takes the shell over, ends it or fails must not cost the script its run. Run through
// the shell, these would skip it and report success, so the fallback is the point: see loginEnvironment.
func TestRunStillRunsTheScriptWhenTheLoginShellMisbehaves(t *testing.T) {
	for name, tc := range map[string]struct{ profile, reason string }{
		"exec":    {"exec /usr/bin/true\n", "noMarkers"},
		"exit":    {"exit 0\n", "noMarkers"},
		"failure": {"exit 3\n", "nonZeroExit"},
		"hang":    {"sleep 30\n", "timedOut"},
	} {
		t.Run(name, func(t *testing.T) {
			loginShellWith(t, tc.profile)
			previous := loginReadTimeout
			loginReadTimeout = time.Second
			t.Cleanup(func() { loginReadTimeout = previous })
			t.Setenv("FROM_THE_CALLER", "kept")
			dir := workroomDir(t)

			var streamed bytes.Buffer
			output, err := Run("teardown", scriptPrinting(t, dir, "ran with $FROM_THE_CALLER"), dir, "wr", "/root", &streamed)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !strings.HasSuffix(output, "ran with kept\n") {
				t.Fatalf("the script didn't run with the caller's environment: %q", output)
			}
			if !strings.Contains(streamed.String(), "couldn't read the login shell's environment ("+tc.reason+")") {
				t.Fatalf("the log doesn't say why: %q", streamed.String())
			}
		})
	}
}

func TestRunKeepsTheLoginShellsOutputOutOfTheLog(t *testing.T) {
	loginShellWith(t, "echo welcome to this machine\necho on stderr >&2\n")
	dir := workroomDir(t)

	output, err := Run("setup", scriptPrinting(t, dir, "ran"), dir, "wr", "/root", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if output != "ran\n" {
		t.Fatalf("the log has %q", output)
	}
}

func TestRunScriptNeverSeesTheProbeMarker(t *testing.T) {
	loginShellWith(t, "")
	dir := workroomDir(t)

	output, err := Run("setup", scriptPrinting(t, dir, "probe=${WORKROOM_SHELL_PROBE-unset} shlvl=${SHLVL-unset}"), dir, "wr", "/root", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.HasPrefix(output, "probe=unset ") {
		t.Fatalf("the script saw %q", output)
	}
}

func TestRunKeepsTheCallersGitSafetySettingsOverAnyRc(t *testing.T) {
	loginShellWith(t, "export GIT_TERMINAL_PROMPT=1 GIT_OPTIONAL_LOCKS=1\n")
	t.Setenv("GIT_TERMINAL_PROMPT", "0")
	t.Setenv("GIT_OPTIONAL_LOCKS", "0")
	dir := workroomDir(t)

	output, err := Run("setup", scriptPrinting(t, dir, "$GIT_TERMINAL_PROMPT$GIT_OPTIONAL_LOCKS"), dir, "wr", "/root", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if output != "00\n" {
		t.Fatalf("the script saw %q", output)
	}
}

func TestRunPutsTheLoginShellsPathFirstAndLosesNothing(t *testing.T) {
	loginShellWith(t, "export PATH=/selected/for/workroom:$PATH\n")
	t.Setenv("PATH", "/only/the/caller:"+os.Getenv("PATH"))
	dir := workroomDir(t)

	output, err := Run("setup", scriptPrinting(t, dir, "$PATH"), dir, "wr", "/root", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.HasPrefix(output, "/selected/for/workroom:") || !strings.Contains(output, ":/only/the/caller:") {
		t.Fatalf("the script's PATH is %q", output)
	}
}

// No script means nothing is about to run in that clone, so its rc-visible config isn't read either.
func TestRunStartsNoLoginShellWithoutAScript(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "started")
	loginShellWith(t, "touch "+marker+"\n")
	dir := workroomDir(t)

	if _, err := Run("setup", filepath.Join(dir, "nonexistent"), dir, "wr", "/root", nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("the login shell started: %v", err)
	}
}

// `workroom create` in a real terminal: interactive zsh outside the terminal's foreground group is
// stopped by SIGTTOU, which only a real controlling terminal shows. The child test is run under one.
func TestRunIsNotStoppedInARealTerminal(t *testing.T) {
	if _, err := exec.LookPath("zsh"); err != nil {
		t.Skip("needs zsh: bash isn't stopped")
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	child := self + " -test.run=^TestRunInATerminalChild$ -test.v"
	args := []string{"-q", "/dev/null", "/bin/sh", "-c", child}
	if runtime.GOOS == "linux" {
		args = []string{"-qec", child, "/dev/null"}
	}
	cmd := exec.Command("script", args...)
	cmd.Env = append(os.Environ(), "WORKROOM_TERMINAL_CHILD=1")
	output, err := cmd.CombinedOutput()
	if strings.Contains(string(output), "CHILD-NEEDS-A-TERMINAL") || err != nil && !strings.Contains(string(output), "=== RUN") {
		t.Skipf("no terminal to be had here: %v: %s", err, output)
	}
	if err != nil || !strings.Contains(string(output), "--- PASS: TestRunInATerminalChild") {
		t.Fatalf("under a terminal: %v\n%s", err, output)
	}
}

func TestRunInATerminalChild(t *testing.T) {
	if os.Getenv("WORKROOM_TERMINAL_CHILD") == "" {
		t.Skip("run by TestRunIsNotStoppedInARealTerminal")
	}
	if tty, err := os.Open("/dev/tty"); err != nil {
		fmt.Println("CHILD-NEEDS-A-TERMINAL")
		t.Skip(err)
	} else {
		tty.Close()
	}
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".zshrc"), []byte("export SELECTED_FOR=\"$(pwd -P)\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("ZDOTDIR", home)
	t.Setenv("SHELL", zsh)
	loginReadTimeout = 3 * time.Second
	dir := workroomDir(t)

	output, err := Run("setup", scriptPrinting(t, dir, "selected=$SELECTED_FOR"), dir, "wr", "/root", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if want := "selected=" + dir + "\n"; output != want {
		t.Fatalf("the script saw %q, want %q", output, want)
	}
}
