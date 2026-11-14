//go:build !windows

package workroom

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/joelmoss/workroom/internal/errs"
)

// holdLock takes path's lock through an open file description of its own, as another process would,
// until the test ends or the returned release is called.
func holdLock(t *testing.T, path string) (release func()) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	released := false
	release = func() {
		if !released {
			released = true
			_ = f.Close()
		}
	}
	t.Cleanup(release)
	return release
}

// lockIsHeld reports whether something else holds path's lock.
func lockIsHeld(t *testing.T, path string) bool {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if err == nil {
		return false
	}
	if !errors.Is(err, syscall.EWOULDBLOCK) {
		t.Fatal(err)
	}
	return true
}

func touch(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

// Value: protects=a staging folder's lock, when it has one, decides whether its clone is alive: held
// keeps it whatever its pid, free sweeps it whatever its pid; without one the pid decides; an orphan
// lock goes only once free; fails_when=the sweep reads the pid alone, or takes a held lock for dead;
// why_new=the lock is new; seam=staleStaging takes the host, so this runs on a machine with no id;
// no_claim=does not crash a real clone
func TestStaleStaging_LockRules(t *testing.T) {
	const host = "f00dcafe"
	for _, tc := range []struct {
		name               string
		pid                int
		folder, lock, held bool
		wantStale          bool
	}{
		{"held lock, dead pid", deadPid(t), true, true, true, false},
		{"free lock, live pid", os.Getpid(), true, true, false, true},
		{"no lock, dead pid", deadPid(t), true, false, false, true},
		{"no lock, live pid", os.Getpid(), true, false, false, false},
		{"orphan lock, free", deadPid(t), false, true, false, true},
		{"orphan lock, held", deadPid(t), false, true, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			stage := filepath.Join(dir, stagingName(".clone-", host, tc.pid))
			if tc.folder {
				mkStaging(t, stage)
			}
			if tc.lock {
				touch(t, stage+".lock")
				if tc.held {
					holdLock(t, stage+".lock")
				}
			}
			stale := staleStaging(dir, ".clone-", host)
			defer releaseAll(stale)
			if got := len(stale) == 1; got != tc.wantStale {
				t.Fatalf("stale = %+v, want stale %v", stale, tc.wantStale)
			}
			if !tc.wantStale {
				return
			}
			want := staleStage{lock: ""}
			if tc.folder {
				want.dir = stage
			}
			if tc.lock {
				want.lock = stage + ".lock"
			}
			if stale[0].dir != want.dir || stale[0].lock != want.lock {
				t.Fatalf("stale = %+v, want dir %q lock %q", stale[0], want.dir, want.lock)
			}
		})
	}
}

// Value: protects=a clone whose CLI was killed while git (holding the inherited lock) still runs
// keeps its staging, and the folder is named as in the way; fails_when=the dead pid in the name
// sweeps a staging folder git is still writing; why_new=only the lock can tell; seam=the test holds
// the lock in git's place; no_claim=does not SIGKILL a real CLI
func TestCloneProject_SweepKeepsStagingWhoseLockIsHeld(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	dest := t.TempDir()
	name := stagingName(".clone-", hostOf(t), deadPid(t))
	stage := filepath.Join(dest, name)
	mkStaging(t, stage)
	holdLock(t, stage+".lock")

	_, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
	if !errors.Is(err, errs.ErrDestinationNotEmpty) || !strings.Contains(err.Error(), name) {
		t.Fatalf("err = %v, want ErrDestinationNotEmpty naming %s", err, name)
	}
	if _, err := os.Stat(filepath.Join(stage, ".git")); err != nil {
		t.Fatalf("staging whose lock is held was removed: %v", err)
	}
}

// Value: protects=once a dead clone's lock is free its staging and lock file are both swept, inside
// and beside; fails_when=the lock file is left behind and blocks the folder; why_new=the lock file is
// new; seam=none; no_claim=does not crash a real clone
func TestCloneProject_SweepsStagingOnceItsLockIsFree(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	t.Run("inside", func(t *testing.T) {
		dest := t.TempDir()
		stage := filepath.Join(dest, stagingName(".clone-", hostOf(t), deadPid(t)))
		mkStaging(t, stage)
		holdLock(t, stage+".lock")()
		if _, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{}); err != nil {
			t.Fatalf("retry after a dead clone: %v", err)
		}
		assertGone(t, stage, stage+".lock")
	})
	t.Run("beside", func(t *testing.T) {
		parent := t.TempDir()
		stage := filepath.Join(parent, stagingName(".api.clone-", hostOf(t), os.Getpid()))
		mkStaging(t, stage)
		holdLock(t, stage+".lock")()
		orphan := filepath.Join(parent, stagingName(".api.clone-", hostOf(t), deadPid(t))+".lock")
		touch(t, orphan)
		if _, err := svc.CloneProject(context.Background(), "file://"+origin, filepath.Join(parent, "api"), &bytes.Buffer{}); err != nil {
			t.Fatalf("clone failed: %v", err)
		}
		assertGone(t, stage, stage+".lock", orphan)
	})
}

func assertGone(t *testing.T, paths ...string) {
	t.Helper()
	for _, p := range paths {
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Fatalf("%s is still there (lstat err %v)", p, err)
		}
	}
}

// Value: protects=a live clone's lock file inside the folder blocks it and is named, while --pretend
// looks past a dead one's without touching it; fails_when=a lock file counts as ordinary content, or
// pretend removes it; why_new=lock files are new; seam=none; no_claim=none beyond protects
func TestCloneProject_LockFilesAndTheEmptinessCheck(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	t.Run("live lock in the way", func(t *testing.T) {
		dest := t.TempDir()
		name := stagingName(".clone-", hostOf(t), deadPid(t)) + ".lock"
		holdLock(t, filepath.Join(dest, name))
		_, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
		if !errors.Is(err, errs.ErrDestinationNotEmpty) || !strings.Contains(err.Error(), name) {
			t.Fatalf("err = %v, want ErrDestinationNotEmpty naming %s", err, name)
		}
	})
	t.Run("pretend ignores a dead one", func(t *testing.T) {
		pretend, _ := newCreateSvc(t)
		pretend.Pretend = true
		dest := t.TempDir()
		stage := filepath.Join(dest, stagingName(".clone-", hostOf(t), os.Getpid()))
		mkStaging(t, stage)
		touch(t, stage+".lock")
		res, err := pretend.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
		if err != nil || !res.WouldClone {
			t.Fatalf("pretend: res %+v, err %v; want WouldClone", res, err)
		}
		for _, p := range []string{stage, stage + ".lock"} {
			if _, err := os.Stat(p); err != nil {
				t.Fatalf("pretend removed %s: %v", p, err)
			}
		}
		if lockIsHeld(t, stage+".lock") {
			t.Fatal("pretend kept the dead clone's lock")
		}
	})
}

// Value: protects=a clone leaves no lock file behind, whether it succeeds, fails or is cancelled;
// fails_when=a cleanup path forgets the lock and the next clone finds the folder taken;
// why_new=lock files are new; seam=none; no_claim=none beyond protects
func TestCloneProject_LeavesNoLockFile(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	t.Run("success inside", func(t *testing.T) {
		dest := t.TempDir()
		if _, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{}); err != nil {
			t.Fatal(err)
		}
		assertNoStaging(t, dest)
	})
	t.Run("success beside", func(t *testing.T) {
		dest := filepath.Join(t.TempDir(), "api")
		if _, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{}); err != nil {
			t.Fatal(err)
		}
		assertNoStaging(t, dest)
	})
	t.Run("failure", func(t *testing.T) {
		dest := t.TempDir()
		if _, err := svc.CloneProject(context.Background(), "file:///nowhere.git", dest, &bytes.Buffer{}); !errors.Is(err, errs.ErrCloneFailed) {
			t.Fatalf("err = %v, want ErrCloneFailed", err)
		}
		assertNoStaging(t, dest)
	})
	t.Run("cancel", func(t *testing.T) {
		parent := t.TempDir()
		dest := filepath.Join(parent, "api")
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		done := startHangingClone(t, svc, ctx, dest)
		cancel()
		awaitCancelled(t, done)
		assertNoStaging(t, dest)
	})
}

// Value: protects=the run's lock is held for as long as the clone runs; fails_when=the lock is taken
// only after git finishes, or never; why_new=the lock is new; seam=none; no_claim=does not show git
// holds it (TestRunClone_GitInheritsTheLock does)
func TestCloneProject_HoldsTheLockWhileCloning(t *testing.T) {
	svc, _ := newCreateSvc(t)
	dest := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := startHangingClone(t, svc, ctx, dest)
	locks, _ := filepath.Glob(filepath.Join(dest, ".clone-*.lock"))
	if len(locks) != 1 {
		cancel()
		awaitCancelled(t, done)
		t.Fatalf("lock files while cloning: %v, want one", locks)
	}
	held := lockIsHeld(t, locks[0])
	cancel()
	awaitCancelled(t, done)
	if !held {
		t.Fatalf("%s is not locked while the clone runs", locks[0])
	}
}

// Value: protects=git and its helpers inherit the lock, so it stays held after the CLI is gone while
// any of them still runs; fails_when=the lock is held by the CLI's file alone; why_new=the lock is
// new; seam=the test closes its own file in place of the CLI dying; no_claim=does not SIGKILL a real
// CLI
func TestRunClone_GitInheritsTheLock(t *testing.T) {
	requireGit(t)
	tools := t.TempDir()
	pidFile := filepath.Join(tools, "helper.pid")
	helper := filepath.Join(tools, "hang.sh")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\necho $$ > "+pidFile+"\nexec sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_ALLOW_PROTOCOL", "ext")
	stage := filepath.Join(t.TempDir(), ".api.clone-x")
	lock, err := createStagingLock(stage + ".lock")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- runClone(ctx, "ext::"+helper, stage, &bytes.Buffer{}, lock) }()
	waitForPid(t, pidFile)

	_ = lock.Close() // the CLI's own hold is gone; only git and its helper still have the file
	held := lockIsHeld(t, stage+".lock")
	cancel()
	awaitCancelled(t, done)
	if !held {
		t.Fatal("the lock was free while git still ran: git did not inherit it")
	}
	if lockIsHeld(t, stage+".lock") {
		t.Fatal("the lock is still held after git and its helper are gone")
	}
}

// Value: protects=a FIFO planted at a staging lock path can't hang the sweep (or --pretend) past
// cancel; the staging is kept; fails_when=the probe opens the lock without O_NONBLOCK; why_new=every
// other test uses regular lock files; seam=none; no_claim=does not cover other special files
func TestProbeStagingLock_FIFODoesNotBlock(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".clone-x.lock")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan lockState, 1)
	go func() {
		f, state := probeStagingLock(path)
		if f != nil {
			_ = f.Close()
		}
		done <- state
	}()
	select {
	case state := <-done:
		if state != lockHeld {
			t.Fatalf("FIFO lock judged %v, want lockHeld (kept)", state)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("probing a FIFO lock blocked")
	}
}
