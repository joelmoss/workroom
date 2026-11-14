package workroom

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
)

// bareRepo makes a bare repository with one commit, to clone from as file://.
func bareRepo(t *testing.T) string {
	t.Helper()
	requireGit(t)
	work := t.TempDir()
	run(t, work, "git", "init", "-q", "-b", "main")
	run(t, work, "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "init")
	bare := filepath.Join(t.TempDir(), "origin.git")
	run(t, work, "git", "clone", "-q", "--bare", work, bare)
	return bare
}

func TestCloneProject_ClonesAndRegisters(t *testing.T) {
	svc, cfg := newCreateSvc(t)
	origin := bareRepo(t)
	dest := filepath.Join(t.TempDir(), "src", "api")

	res, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
	if err != nil {
		t.Fatalf("clone failed: %v", err)
	}
	if res.VCS != "git" || res.WouldClone {
		t.Fatalf("unexpected result: %+v", res)
	}
	want, _ := filepath.EvalSymlinks(dest)
	if res.Path != want {
		t.Fatalf("path = %q, want the canonical %q", res.Path, want)
	}
	if got := run(t, res.Path, "git", "log", "--format=%s"); got != "init" {
		t.Fatalf("clone has log %q, want the origin's commit", got)
	}
	assertRegistered(t, cfg, res.Path, true)
}

// assertRegistered checks whether path is a registered project.
func assertRegistered(t *testing.T, cfg *config.Config, path string, want bool) {
	t.Helper()
	projects, err := cfg.AllProjects()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := projects[path]; ok != want {
		t.Fatalf("project %q registered = %v, want %v (projects: %v)", path, ok, want, projects)
	}
}

// A failing clone reports git's own error lines, removes every folder it made (the missing parent
// included), and registers nothing.
func TestCloneProject_FailureRemovesWhatItMade(t *testing.T) {
	requireGit(t)
	svc, cfg := newCreateSvc(t)
	root := t.TempDir()
	missing := filepath.Join(root, "src")
	dest := filepath.Join(missing, "api")

	_, err := svc.CloneProject(context.Background(), "file://"+filepath.Join(root, "nowhere.git"), dest, &bytes.Buffer{})
	if !errors.Is(err, errs.ErrCloneFailed) {
		t.Fatalf("err = %v, want ErrCloneFailed", err)
	}
	if !strings.Contains(err.Error(), "does not appear to be a git repository") {
		t.Fatalf("err = %q, want git's own message", err)
	}
	if strings.Contains(err.Error(), "Cloning into") {
		t.Fatalf("err = %q, want git's progress chatter left out", err)
	}
	if _, statErr := os.Stat(missing); !os.IsNotExist(statErr) {
		t.Fatalf("%s left behind (stat err %v)", missing, statErr)
	}
	assertNoProjects(t, cfg)
}

// A destination that already existed as an empty folder is emptied again, not removed.
func TestCloneProject_FailureKeepsAnEmptyFolderThatExisted(t *testing.T) {
	requireGit(t)
	svc, cfg := newCreateSvc(t)
	dest := t.TempDir()

	_, err := svc.CloneProject(context.Background(), "file:///nowhere.git", dest, &bytes.Buffer{})
	if !errors.Is(err, errs.ErrCloneFailed) {
		t.Fatalf("err = %v, want ErrCloneFailed", err)
	}
	entries, statErr := os.ReadDir(dest)
	if statErr != nil || len(entries) != 0 {
		t.Fatalf("dest not kept empty: entries %v, err %v", entries, statErr)
	}
	assertNoProjects(t, cfg)
}

// A Finder-touched folder (only .DS_Store) still counts as empty, as it does for --create.
func TestCloneProject_DSStoreOnlyFolderCountsEmpty(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, ".DS_Store"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{}); err != nil {
		t.Fatalf("clone into a .DS_Store-only folder failed: %v", err)
	}
}

// A destination that is a file, or a folder with something in it, fails before any clone.
func TestCloneProject_RefusesAnUnusableDestination(t *testing.T) {
	svc, cfg := newCreateSvc(t)
	origin := bareRepo(t)
	full := t.TempDir()
	if err := os.WriteFile(filepath.Join(full, "README"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := svc.CloneProject(context.Background(), "file://"+origin, full, &bytes.Buffer{}); !errors.Is(err, errs.ErrDestinationNotEmpty) {
		t.Fatalf("non-empty folder: err = %v, want ErrDestinationNotEmpty", err)
	}
	if got := run(t, full, "ls", "-A"); got != "README" {
		t.Fatalf("non-empty folder was touched: %q", got)
	}
	if _, err := svc.CloneProject(context.Background(), "file://"+origin, file, &bytes.Buffer{}); !errors.Is(err, errs.ErrNotDirectory) {
		t.Fatalf("file: err = %v, want ErrNotDirectory", err)
	}
	assertNoProjects(t, cfg)
}

func assertNoProjects(t *testing.T, cfg *config.Config) {
	t.Helper()
	projects, err := cfg.AllProjects()
	if err != nil {
		t.Fatal(err)
	}
	if len(projects) != 0 {
		t.Fatalf("want nothing registered, got %v", projects)
	}
}

// Cancelling a clone (what SIGTERM does to the CLI) kills git's whole process group, transport
// helper included, reports ErrCancelled rather than a clone failure, and leaves nothing behind.
func TestCloneProject_CancelKillsGitAndCleansUp(t *testing.T) {
	requireGit(t)
	svc, cfg := newCreateSvc(t)
	tools := t.TempDir()
	pidFile := filepath.Join(tools, "helper.pid")
	// A transport that never answers: the ext:: helper records its pid, then hangs.
	helper := filepath.Join(tools, "hang.sh")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\necho $$ > "+pidFile+"\nexec sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_ALLOW_PROTOCOL", "ext")
	dest := filepath.Join(t.TempDir(), "api")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	type result struct{ err error }
	done := make(chan result, 1)
	go func() {
		_, err := svc.CloneProject(ctx, "ext::"+helper, dest, &bytes.Buffer{})
		done <- result{err}
	}()

	pid := waitForPid(t, pidFile)
	if !processAlive(pid) {
		t.Fatalf("helper %d not running before the cancel", pid)
	}
	cancel()

	select {
	case r := <-done:
		if !errors.Is(r.err, errs.ErrCancelled) {
			t.Fatalf("err = %v, want ErrCancelled", r.err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("CloneProject did not return after the cancel")
	}
	deadline := time.Now().Add(3 * time.Second)
	for processAlive(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("transport helper %d survived the cancel", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatalf("%s left behind (stat err %v)", dest, err)
	}
	assertNoProjects(t, cfg)
}

func waitForPid(t *testing.T, file string) int {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(file); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
				return pid
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the transport helper never started")
	return 0
}

// processAlive reports whether pid is a live process (a zombie counts as gone).
func processAlive(pid int) bool {
	out, err := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
	return err == nil && !strings.HasPrefix(strings.TrimSpace(string(out)), "Z")
}

// Value: protects=the inline clone error shows git's own failure lines without progress chatter;
// fails_when=progress counters or "Cloning into" leak into the error, or a non-fatal line is dropped;
// why_new=real-git tests only hit the 'does not appear' failure, not ssh-style or CR-redrawn output; seam=none;
// no_claim=does not run git
func TestCloneErrorLines(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"empty", "", ""},
		{"progress only", "Cloning into 'x'...\nReceiving objects:  50% (1/2)\rReceiving objects: 100% (2/2), done.\n", ""},
		{"fatal kept", "Cloning into 'x'...\nfatal: repository 'y' does not exist\n", "fatal: repository 'y' does not exist"},
		{"non-fatal ssh line kept", "Cloning into 'x'...\r\nPermission denied (publickey).\nfatal: Could not read from remote repository.\n",
			"Permission denied (publickey).\nfatal: Could not read from remote repository."},
		{"CR-redrawn counters between errors", "remote: Counting objects: 10% (1/10)\rremote: Counting objects: 100% (10/10), done.\nfatal: early EOF\n", "fatal: early EOF"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := cloneErrorLines(c.in); got != c.want {
				t.Fatalf("cloneErrorLines(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// startHangingClone starts a clone that hangs in its transport until ctx is cancelled, and returns
// once git is running, with a channel for CloneProject's error.
func startHangingClone(t *testing.T, svc *Service, ctx context.Context, dest string) <-chan error {
	t.Helper()
	requireGit(t)
	tools := t.TempDir()
	pidFile := filepath.Join(tools, "helper.pid")
	helper := filepath.Join(tools, "hang.sh")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\necho $$ > "+pidFile+"\nexec sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_ALLOW_PROTOCOL", "ext")
	done := make(chan error, 1)
	go func() {
		_, err := svc.CloneProject(ctx, "ext::"+helper, dest, &bytes.Buffer{})
		done <- err
	}()
	waitForPid(t, pidFile)
	return done
}

func awaitCancelled(t *testing.T, done <-chan error) {
	t.Helper()
	select {
	case err := <-done:
		if !errors.Is(err, errs.ErrCancelled) {
			t.Fatalf("err = %v, want ErrCancelled", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("CloneProject did not return after the cancel")
	}
}

// Value: protects=a failed clone never deletes another clone sharing a newly created parent;
// fails_when=cleanup removes the topmost created folder wholesale; why_new=existing cleanup tests run
// one clone at a time; seam=none; no_claim=does not run two real clones (the sibling's files stand in)
func TestCloneProject_CancelLeavesASiblingInACreatedParent(t *testing.T) {
	svc, _ := newCreateSvc(t)
	parent := filepath.Join(t.TempDir(), "new")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := startHangingClone(t, svc, ctx, filepath.Join(parent, "a"))

	// Another clone, into new/b, writes while this one is running.
	sibling := filepath.Join(parent, "b", "README")
	if err := os.MkdirAll(filepath.Dir(sibling), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sibling, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cancel()
	awaitCancelled(t, done)

	if _, err := os.Stat(sibling); err != nil {
		t.Fatalf("the sibling clone's file was deleted: %v", err)
	}
	if _, err := os.Stat(filepath.Join(parent, "a")); !os.IsNotExist(err) {
		t.Fatalf("new/a left behind (stat err %v)", err)
	}
}

// Value: protects=cancelling a clone into an existing empty folder never deletes what another run
// put there meanwhile; fails_when=cleanup empties the destination wholesale; why_new=the existing
// empty-folder test has no concurrent writer; seam=none; no_claim=the other run is simulated by a file
func TestCloneProject_CancelLeavesAConcurrentWinnersClone(t *testing.T) {
	svc, _ := newCreateSvc(t)
	dest := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := startHangingClone(t, svc, ctx, dest)

	winner := filepath.Join(dest, "README")
	if err := os.WriteFile(winner, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cancel()
	awaitCancelled(t, done)

	if _, err := os.Stat(winner); err != nil {
		t.Fatalf("the concurrent clone's file was deleted: %v", err)
	}
	if got := run(t, dest, "ls", "-A"); got != "README" {
		t.Fatalf("destination holds %q, want only the other run's README", got)
	}
}
