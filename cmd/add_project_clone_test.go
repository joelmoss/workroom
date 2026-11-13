package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/joelmoss/workroom/internal/errs"
)

// add-project --clone's whole output where it is deterministic (#620): everything but a real
// clone's progress, which TestAddProjectCloneStreamsProgress covers.
func TestAddProjectCloneOutput(t *testing.T) {
	home := contractHomeDir(t)
	origin := "file://" + gitRepo(t, filepath.Join(home, "src", "origin"))
	full := filepath.Join(home, "src", "full")
	if err := os.MkdirAll(full, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(full, "README"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	fresh := filepath.Join(home, "src", "api")

	checkCLI(t, home, []cliCase{
		{"pretend", []string{"add-project", fresh, "--clone", origin, "--json", "--pretend"}, 0,
			envelope(`"command":"add-project","ok":true,"path":"/Users/dev/src/api","schema_version":1,"vcs":"git","would_clone":true`), ""},
		{"with --create", []string{"add-project", fresh, "--clone", origin, "--create", "--json"}, 1,
			envelope(`"command":"add-project","error":{"kind":"InternalError","message":"--clone and --create cannot be used together"},"ok":false,"schema_version":1`), ""},
		{"into a full folder", []string{"add-project", full, "--clone", origin, "--json"}, 3,
			envelope(`"command":"add-project","error":{"kind":"DestinationNotEmpty","message":"the destination folder is not empty: /Users/dev/src/full"},"ok":false,"schema_version":1`), ""},
		{"remote path", []string{"add-project", "git@example.com:org/api.git", "--clone", origin, "--json"}, 3,
			envelope(`"command":"add-project","error":{"kind":"RemoteProjectUnsupported","message":"remote projects are not supported: add the project from a local Git repository. A remote workroom belongs to a local project: git@example.com:org/api.git"},"ok":false,"schema_version":1`), ""},
	})
	if _, err := os.Stat(fresh); !os.IsNotExist(err) {
		t.Fatalf("pretend made %s (stat err %v)", fresh, err)
	}
}

// A real clone registers the project and streams git's output as "clone" log events on stderr.
func TestAddProjectCloneStreamsProgress(t *testing.T) {
	home := contractHomeDir(t)
	origin := "file://" + gitRepo(t, filepath.Join(home, "src", "origin"))
	dest := filepath.Join(home, "src", "api")

	run := runCLI(t, "add-project", dest, "--clone", origin, "--json")
	want := envelope(`"command":"add-project","ok":true,"path":"` + dest + `","schema_version":1,"vcs":"git"`)
	if run.code != 0 || string(run.stdout) != want {
		t.Fatalf("exit %d, stdout:\n%s\nwant exit 0, stdout:\n%s\nstderr:\n%s", run.code, run.stdout, want, run.stderr)
	}
	var texts []string
	for _, line := range strings.Split(strings.TrimSuffix(string(run.stderr), "\n"), "\n") {
		var ev struct{ Type, Phase, Text string }
		if err := json.Unmarshal([]byte(line), &ev); err != nil || ev.Type != "log" || ev.Phase != "clone" {
			t.Fatalf("stderr line %q is not a clone log event (err %v)", line, err)
		}
		texts = append(texts, ev.Text)
	}
	if len(texts) == 0 || !strings.HasPrefix(texts[0], "Cloning into ") {
		t.Fatalf("log texts %q, want git's \"Cloning into\" first", texts)
	}
}

// A failed clone is CloneFailed, with git's own words.
func TestAddProjectCloneFailure(t *testing.T) {
	home := contractHomeDir(t)
	requireGit(t)
	run := runCLI(t, "add-project", filepath.Join(home, "src", "api"), "--clone", "file://"+home+"/nowhere.git", "--json")
	var env struct {
		Error struct{ Kind, Message string }
	}
	if err := json.Unmarshal(run.stdout, &env); err != nil {
		t.Fatalf("stdout %q: %v", run.stdout, err)
	}
	if run.code != 1 || env.Error.Kind != "CloneFailed" ||
		!strings.Contains(env.Error.Message, "does not appear to be a git repository") {
		t.Fatalf("exit %d, error %+v; want exit 1, CloneFailed with git's message", run.code, env.Error)
	}
}

// SIGTERM, which is how the app's Cancel reaches the CLI, kills git's process group (its transport
// helper too), puts the destination back, registers nothing, and reports Cancelled.
func TestAddProjectCloneSIGTERMCancels(t *testing.T) {
	home := contractHomeDir(t)
	requireGit(t)
	tools := t.TempDir()
	pidFile := filepath.Join(tools, "helper.pid")
	// A transport that never answers: the ext:: helper records its pid, then hangs.
	helper := filepath.Join(tools, "hang.sh")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\necho $$ > "+pidFile+"\nexec sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_ALLOW_PROTOCOL", "ext")
	dest := filepath.Join(home, "src", "api")
	svc, err := newService()
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() { done <- runCloneProject(svc, "ext::"+helper, dest, &bytes.Buffer{}, &bytes.Buffer{}) }()

	// The helper runs only once git has started, by which point the SIGTERM handler is installed,
	// so signalling this test process reaches it rather than ending the run.
	pid := 0
	for deadline := time.Now().Add(10 * time.Second); pid == 0; time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the transport helper never started")
		}
		if b, err := os.ReadFile(pidFile); err == nil {
			pid, _ = strconv.Atoi(strings.TrimSpace(string(b)))
		}
	}
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}

	select {
	case err := <-done:
		if !errors.Is(err, errs.ErrCancelled) {
			t.Fatalf("err = %v, want ErrCancelled", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the clone did not stop on SIGTERM")
	}
	for deadline := time.Now().Add(3 * time.Second); helperAlive(pid); time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("transport helper %d survived the SIGTERM", pid)
		}
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatalf("%s left behind (stat err %v)", dest, err)
	}
	projects, err := svc.Config.AllProjects()
	if err != nil || len(projects) != 0 {
		t.Fatalf("want nothing registered, got %v (err %v)", projects, err)
	}
}

// helperAlive reports whether pid is a live process (a zombie counts as gone).
func helperAlive(pid int) bool {
	out, err := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
	return err == nil && !strings.HasPrefix(strings.TrimSpace(string(out)), "Z")
}
