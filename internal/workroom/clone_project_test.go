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
// helper included, reports ErrCancelled rather than a clone failure, and leaves nothing behind. A
// helper that ignores SIGTERM is SIGKILLed once the grace period is over.
func TestCloneProject_CancelKillsGitAndCleansUp(t *testing.T) {
	for _, tc := range []struct{ name, trap string }{
		{"helper exits on SIGTERM", ""},
		{"helper ignores SIGTERM", "trap '' TERM\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			requireGit(t)
			svc, cfg := newCreateSvc(t)
			tools := t.TempDir()
			pidFile := filepath.Join(tools, "helper.pid")
			// A transport that never answers: the ext:: helper records its pid, then hangs.
			helper := filepath.Join(tools, "hang.sh")
			body := "#!/bin/sh\n" + tc.trap + "echo $$ > " + pidFile + "\nexec sleep 30\n"
			if err := os.WriteFile(helper, []byte(body), 0o755); err != nil {
				t.Fatal(err)
			}
			t.Setenv("GIT_ALLOW_PROTOCOL", "ext")
			dest := filepath.Join(t.TempDir(), "api")

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() {
				_, err := svc.CloneProject(ctx, "ext::"+helper, dest, &bytes.Buffer{})
				done <- err
			}()

			pid := waitForPid(t, pidFile)
			if !processAlive(pid) {
				t.Fatalf("helper %d not running before the cancel", pid)
			}
			cancel()
			deadline := time.Now().Add(5 * time.Second)

			select {
			case err := <-done:
				if !errors.Is(err, errs.ErrCancelled) {
					t.Fatalf("err = %v, want ErrCancelled", err)
				}
			case <-time.After(10 * time.Second):
				t.Fatal("CloneProject did not return after the cancel")
			}
			for processAlive(pid) {
				if time.Now().After(deadline) {
					if p, err := os.FindProcess(pid); err == nil {
						_ = p.Kill()
					}
					t.Fatalf("transport helper %d survived the cancel", pid)
				}
				time.Sleep(20 * time.Millisecond)
			}
			if _, err := os.Stat(dest); !os.IsNotExist(err) {
				t.Fatalf("%s left behind (stat err %v)", dest, err)
			}
			assertNoProjects(t, cfg)
		})
	}
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
		{"non-percentage progress dropped", "remote: Enumerating objects: 5, done.\nremote: Counting objects: 5\nremote: Compressing objects: 3\n" +
			"remote: Total 5 (delta 0), reused 0 (delta 0), pack-reused 0\nResolving deltas, done.\nfatal: early EOF\n", "fatal: early EOF"},
		{"remote error kept", "Cloning into 'x'...\nremote: Repository not found.\nfatal: repository 'y' not found\n",
			"remote: Repository not found.\nfatal: repository 'y' not found"},
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
	assertNoStaging(t, filepath.Join(parent, "a"))
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
	assertNoStaging(t, dest)
}

// assertNoStaging checks no staging folder for dest is left beside it or inside it.
func assertNoStaging(t *testing.T, dest string) {
	t.Helper()
	for _, pattern := range []string{
		filepath.Join(filepath.Dir(dest), "."+filepath.Base(dest)+".clone-*"),
		filepath.Join(dest, ".clone-*"),
	} {
		if left, _ := filepath.Glob(pattern); len(left) > 0 {
			t.Fatalf("staging folder left behind: %v", left)
		}
	}
}

// fillingRemote is a clone URL for origin whose transport first writes README into dest (creating
// dest if it is missing), as another run filling the destination mid-clone would, then serves
// origin normally.
func fillingRemote(t *testing.T, origin, dest string) string {
	t.Helper()
	helper := filepath.Join(t.TempDir(), "fill.sh")
	body := "#!/bin/sh\nmkdir -p '" + dest + "'\necho x > '" + filepath.Join(dest, "README") + "'\nexec git-upload-pack '" + origin + "'\n"
	if err := os.WriteFile(helper, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_ALLOW_PROTOCOL", "ext:file")
	return "ext::" + helper
}

// readOnlyParent makes an empty dest inside a parent this user cannot write to, like an empty
// external volume's root under /Volumes.
func readOnlyParent(t *testing.T) string {
	t.Helper()
	parent := t.TempDir()
	dest := filepath.Join(parent, "dest")
	if err := os.Mkdir(dest, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(parent, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(parent, 0o755) })
	return dest
}

// Value: protects=cloning into an empty folder works when its parent is not writable (an external
// drive's root); fails_when=staging always goes beside the destination; why_new=every other test has
// a writable parent; seam=none; no_claim=does not test a real mount point (EXDEV path)
func TestCloneProject_EmptyFolderUnderReadOnlyParent(t *testing.T) {
	svc, cfg := newCreateSvc(t)
	origin := bareRepo(t)
	dest := readOnlyParent(t)

	res, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
	if err != nil {
		t.Fatalf("clone into an empty folder under a read-only parent: %v", err)
	}
	if got := run(t, res.Path, "git", "log", "--format=%s"); got != "init" {
		t.Fatalf("clone has log %q, want the origin's commit", got)
	}
	assertNoStaging(t, dest)
	assertRegistered(t, cfg, res.Path, true)
}

// Value: protects=a destination another run fills mid-clone is refused and left intact;
// fails_when=the clone is moved over the other run's files or its staging is left behind;
// why_new=no test reaches the move-into-place refusal; seam=none; no_claim=the other run is a file
func TestCloneProject_DestinationFilledMeanwhile(t *testing.T) {
	for _, tc := range []struct {
		name string
		dest func(t *testing.T) string
	}{
		// A missing destination is staged beside; the other run creates it mid-clone.
		{"staged beside", func(t *testing.T) string { return filepath.Join(t.TempDir(), "dest") }},
		{"staged inside", func(t *testing.T) string {
			dest := filepath.Join(t.TempDir(), "dest")
			if err := os.Mkdir(dest, 0o755); err != nil {
				t.Fatal(err)
			}
			return dest
		}},
		{"staged inside, read-only parent", readOnlyParent},
	} {
		t.Run(tc.name, func(t *testing.T) {
			svc, cfg := newCreateSvc(t)
			origin := bareRepo(t)
			dest := tc.dest(t)

			_, err := svc.CloneProject(context.Background(), fillingRemote(t, origin, dest), dest, &bytes.Buffer{})
			if !errors.Is(err, errs.ErrDestinationNotEmpty) {
				t.Fatalf("err = %v, want ErrDestinationNotEmpty", err)
			}
			if got := run(t, dest, "ls", "-A"); got != "README" {
				t.Fatalf("destination holds %q, want only the other run's README", got)
			}
			assertNoStaging(t, dest)
			assertNoProjects(t, cfg)
		})
	}
}

// Value: protects=cloning into an existing empty folder keeps that folder (its inode, mode, ACLs,
// xattrs, Finder tags) and works where a directory can't be renamed over another (Windows);
// fails_when=the clone is staged beside and renamed over the folder; why_new=the other
// existing-folder tests only check the folder's contents; seam=none; no_claim=does not check ACLs or
// xattrs themselves, only the inode and mode that carry them
func TestCloneProject_KeepsAnExistingFolder(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	dest := filepath.Join(t.TempDir(), "dest")
	if err := os.Mkdir(dest, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dest, 0o700); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(dest)
	if err != nil {
		t.Fatal(err)
	}

	if _, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{}); err != nil {
		t.Fatalf("clone into an existing empty folder failed: %v", err)
	}
	after, err := os.Stat(dest)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) {
		t.Fatal("the existing folder was replaced, not cloned into")
	}
	if got := after.Mode().Perm(); got != 0o700 {
		t.Fatalf("folder mode = %o, want the user's 0700 kept", got)
	}
	assertNoStaging(t, dest)
}

// Value: protects=a folder the clone creates is 0755 like any other new folder, not MkdirTemp's
// 0700; fails_when=the staging folder's mode is published as is; why_new=no test checks the mode;
// seam=none; no_claim=does not vary the umask
func TestCloneProject_NewFolderIs0755(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	dest := filepath.Join(t.TempDir(), "api")

	if _, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{}); err != nil {
		t.Fatalf("clone failed: %v", err)
	}
	info, err := os.Stat(dest)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o755 {
		t.Fatalf("new folder mode = %o, want 0755", got)
	}
}

// Value: protects=Finder junk that appears in the destination while the clone runs doesn't fail it,
// while a real clash still does; fails_when=moveUp counts .DS_Store/.localized as "something else
// appeared"; why_new=the end-to-end junk test has the junk before the clone, where it is removed
// first; seam=moveUp called directly; no_claim=does not run git
func TestMoveUp_ToleratesFinderJunk(t *testing.T) {
	setup := func(t *testing.T) (string, string) {
		t.Helper()
		canon := t.TempDir()
		stage := filepath.Join(canon, ".clone-1")
		if err := os.MkdirAll(filepath.Join(stage, ".git"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(stage, "README"), []byte("clone"), 0o644); err != nil {
			t.Fatal(err)
		}
		return canon, stage
	}
	t.Run("junk alongside", func(t *testing.T) {
		canon, stage := setup(t)
		// Junk moveUp's sweep can't remove (a non-empty .localized folder) stands in for junk Finder
		// writes after that sweep.
		if err := os.MkdirAll(filepath.Join(canon, ".localized", "x"), 0o755); err != nil {
			t.Fatal(err)
		}
		var placed []string
		if err := moveUp(stage, canon, &placed); err != nil {
			t.Fatalf("moveUp with Finder junk present: %v", err)
		}
		if got := run(t, canon, "ls", "-A"); got != ".git\n.localized\nREADME" {
			t.Fatalf("canon holds %q", got)
		}
	})
	t.Run("clash refused", func(t *testing.T) {
		canon, stage := setup(t)
		if err := os.WriteFile(filepath.Join(canon, "README"), []byte("theirs"), 0o644); err != nil {
			t.Fatal(err)
		}
		var placed []string
		if err := moveUp(stage, canon, &placed); !errors.Is(err, errs.ErrDestinationNotEmpty) {
			t.Fatalf("err = %v, want ErrDestinationNotEmpty", err)
		}
	})
}

// Value: protects=a clone whose git exited 0 succeeds even if a helper it started kept stderr open
// past WaitDelay; fails_when=exec.ErrWaitDelay is reported as a clone failure; why_new=real git
// never leaves a helper behind in tests; seam=a fake git first on PATH; no_claim=does not run git
func TestRunClone_WaitDelayAfterSuccessIsSuccess(t *testing.T) {
	tools := t.TempDir()
	// A git that makes the clone folder, leaves a child holding stderr, and exits 0.
	fake := "#!/bin/sh\nfor last; do :; done\nmkdir -p \"$last\"\nsleep 5 &\nexit 0\n"
	if err := os.WriteFile(filepath.Join(tools, "git"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", tools+string(os.PathListSeparator)+os.Getenv("PATH"))

	if err := runClone(context.Background(), "file:///x.git", filepath.Join(t.TempDir(), "d"), &bytes.Buffer{}); err != nil {
		t.Fatalf("runClone = %v, want success", err)
	}
}

// Value: protects=a server streaming endless progress can't make the CLI keep all of it in memory;
// fails_when=the retained stderr grows past its cap or loses its tail; why_new=no test bounds
// memory; seam=none; no_claim=does not run git
func TestTailBuffer_KeepsOnlyTheLast64KiB(t *testing.T) {
	var tb tailBuffer
	chunk := bytes.Repeat([]byte("x"), 1000)
	for range 200 {
		if n, err := tb.Write(chunk); n != len(chunk) || err != nil {
			t.Fatalf("Write = %d, %v", n, err)
		}
	}
	if _, err := tb.Write([]byte("\nfatal: the end\n")); err != nil {
		t.Fatal(err)
	}
	got := tb.String()
	if len(got) > cloneStderrCap {
		t.Fatalf("kept %d bytes, want at most %d", len(got), cloneStderrCap)
	}
	if !strings.HasSuffix(got, "fatal: the end\n") {
		t.Fatalf("tail lost: ...%q", got[len(got)-40:])
	}
	// The cut line is dropped, so a half progress line can't pass for an error.
	if got != "fatal: the end\n" {
		t.Fatalf("kept %q..., want the partial first line dropped", got[:40])
	}

	var small tailBuffer
	_, _ = small.Write([]byte("a\nb\n"))
	if small.String() != "a\nb\n" {
		t.Fatalf("untruncated buffer = %q", small.String())
	}
}

// Value: protects=a GIT_INDEX_FILE (or GIT_DIR…) inherited from a git hook or alias doesn't
// redirect the clone; fails_when=git inherits repository-scoped variables; why_new=TestMain clears
// them, so no test sees one; seam=none; no_claim=only GIT_INDEX_FILE is exercised
func TestCloneProject_IgnoresInheritedRepositoryVariables(t *testing.T) {
	svc, _ := newCreateSvc(t)
	work := t.TempDir()
	run(t, work, "git", "init", "-q", "-b", "main")
	if err := os.WriteFile(filepath.Join(work, "README"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, work, "git", "add", "README")
	run(t, work, "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init")
	stray := filepath.Join(t.TempDir(), "stray-index")
	t.Setenv("GIT_INDEX_FILE", stray)
	dest := filepath.Join(t.TempDir(), "api")

	if _, err := svc.CloneProject(context.Background(), "file://"+work, dest, &bytes.Buffer{}); err != nil {
		t.Fatalf("clone failed: %v", err)
	}
	if _, err := os.Stat(stray); !os.IsNotExist(err) {
		t.Fatalf("the clone wrote the inherited GIT_INDEX_FILE (stat err %v)", err)
	}
	if _, err := os.Stat(filepath.Join(dest, ".git", "index")); err != nil {
		t.Fatalf("the clone has no index of its own: %v", err)
	}
}

// Value: protects=a clone that is in place survives a registration failure, and the error says
// where it is; fails_when=cleanup deletes the published clone; why_new=no test makes AddProject
// fail; seam=config.json replaced by a folder; no_claim=does not test a full disk
func TestCloneProject_RegistrationFailureKeepsTheClone(t *testing.T) {
	for _, tc := range []struct {
		name   string
		exists bool
	}{{"new folder", false}, {"existing empty folder", true}} {
		t.Run(tc.name, func(t *testing.T) {
			svc, _ := newCreateSvc(t)
			origin := bareRepo(t)
			cfgPath := filepath.Join(t.TempDir(), "config.json")
			if err := os.Mkdir(cfgPath, 0o755); err != nil {
				t.Fatal(err)
			}
			cfg, err := config.New(cfgPath)
			if err != nil {
				t.Fatal(err)
			}
			svc.Config = cfg
			dest := filepath.Join(t.TempDir(), "api")
			if tc.exists {
				if err := os.Mkdir(dest, 0o755); err != nil {
					t.Fatal(err)
				}
			}

			_, err = svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
			if !errors.Is(err, errs.ErrConfigWrite) {
				t.Fatalf("err = %v, want ErrConfigWrite", err)
			}
			if !strings.Contains(err.Error(), "could not be registered") || !strings.Contains(err.Error(), dest) {
				t.Fatalf("err = %q, want it to say the clone at %s could not be registered", err, dest)
			}
			if _, err := os.Stat(filepath.Join(dest, ".git")); err != nil {
				t.Fatalf("the clone was removed: %v", err)
			}
			if got := run(t, dest, "git", "log", "--format=%s"); got != "init" {
				t.Fatalf("the clone is wrong: log %q", got)
			}
		})
	}
}
