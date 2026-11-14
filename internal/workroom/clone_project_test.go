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
	"syscall"
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
			if !psAlive(pid) {
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
			for psAlive(pid) {
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

// psAlive reports whether pid is a live process (a zombie counts as gone).
func psAlive(pid int) bool {
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

// Value: protects=a new clone folder honours the user's umask, so a private umask keeps a private
// repo private; fails_when=the folder's mode is forced after creation; why_new=the 0755 test runs
// under the default umask only; seam=none; no_claim=does not check files git writes inside
func TestCloneProject_NewFolderHonoursUmask(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	dest := filepath.Join(t.TempDir(), "api")
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)

	if _, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{}); err != nil {
		t.Fatalf("clone failed: %v", err)
	}
	info, err := os.Stat(dest)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Fatalf("new folder mode under umask 077 = %o, want 0700", got)
	}
}

// Value: protects=a symlink at the destination that points nowhere is refused, not replaced by the
// clone; fails_when=cloneDestination follows the link and calls the path missing; why_new=no test
// puts a symlink at the destination; seam=none; no_claim=does not cover a link to a folder (resolved
// by CanonicalPath before this check)
func TestCloneProject_RefusesADanglingSymlink(t *testing.T) {
	svc, cfg := newCreateSvc(t)
	origin := bareRepo(t)
	dest := filepath.Join(t.TempDir(), "api")
	if err := os.Symlink(filepath.Join(t.TempDir(), "unmounted", "drive"), dest); err != nil {
		t.Fatal(err)
	}

	_, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
	if !errors.Is(err, errs.ErrNotDirectory) {
		t.Fatalf("err = %v, want ErrNotDirectory", err)
	}
	if info, err := os.Lstat(dest); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the symlink was replaced (lstat err %v)", err)
	}
	assertNoProjects(t, cfg)
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

// deadPid is the pid of a process that has exited and been reaped.
func deadPid(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	return cmd.Process.Pid
}

// stagingName is a staging folder name as a clone by pid on host would make it.
func stagingName(prefix, host string, pid int) string {
	return prefix + host + "-" + strconv.Itoa(pid) + "-abc"
}

func mkStaging(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(path, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
}

// Value: protects=a retry into a folder a crashed clone left its staging in succeeds, and that
// staging is removed; fails_when=a stale .clone-* makes the folder count as not empty; why_new=no
// test leaves a dead clone's staging behind; seam=none; no_claim=does not crash a real clone
func TestCloneProject_SweepsADeadClonesStagingInside(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	dest := t.TempDir()
	stale := filepath.Join(dest, stagingName(".clone-", hostOf(t, svc), deadPid(t)))
	mkStaging(t, stale)

	res, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
	if err != nil {
		t.Fatalf("retry after a dead clone: %v", err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatalf("the dead clone's staging is still there (stat err %v)", err)
	}
	if got := run(t, res.Path, "git", "log", "--format=%s"); got != "init" {
		t.Fatalf("clone has log %q, want the origin's commit", got)
	}
}

// Value: protects=the sweep never removes a staging folder that may still be in use: a live
// process's, another machine's, an old unnamed one, or a symlink; fails_when=the sweep matches on the
// name alone; why_new=only the sweep decides this; seam=none; no_claim=does not use a second machine
func TestCloneProject_SweepLeavesStagingThatMayBeInUse(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	for _, tc := range []struct{ name, entry string }{
		{"live process", stagingName(".clone-", hostOf(t, svc), os.Getpid())},
		{"another machine", stagingName(".clone-", "0badc0de", deadPid(t))},
		{"old unnamed", ".clone-123456"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dest := t.TempDir()
			kept := filepath.Join(dest, tc.entry)
			mkStaging(t, kept)
			_, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
			if !errors.Is(err, errs.ErrDestinationNotEmpty) {
				t.Fatalf("err = %v, want ErrDestinationNotEmpty", err)
			}
			if _, err := os.Stat(filepath.Join(kept, ".git")); err != nil {
				t.Fatalf("staging that may be in use was removed: %v", err)
			}
		})
	}
	t.Run("symlink", func(t *testing.T) {
		dest := t.TempDir()
		target := t.TempDir()
		link := filepath.Join(dest, stagingName(".clone-", hostOf(t, svc), deadPid(t)))
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
		_, _ = svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
		if info, err := os.Lstat(link); err != nil || info.Mode()&os.ModeSymlink == 0 {
			t.Fatalf("a symlink with a staging name was removed (lstat err %v)", err)
		}
		if _, err := os.Stat(target); err != nil {
			t.Fatalf("the symlink's target was touched: %v", err)
		}
	})
}

// Value: protects=a dead clone's staging beside a new destination is swept, a live sibling's is not;
// fails_when=the parent is not swept, or the sweep ignores the owner; why_new=beside staging lives in
// the parent, where no other test looks; seam=none; no_claim=does not crash a real clone
func TestCloneProject_SweepsDeadStagingBeside(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	parent := t.TempDir()
	dest := filepath.Join(parent, "api")
	stale := filepath.Join(parent, stagingName(".api.clone-", hostOf(t, svc), deadPid(t)))
	live := filepath.Join(parent, stagingName(".api.clone-", hostOf(t, svc), os.Getpid()))
	mkStaging(t, stale)
	mkStaging(t, live)

	if _, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{}); err != nil {
		t.Fatalf("clone failed: %v", err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatalf("the dead clone's staging is still there (stat err %v)", err)
	}
	if _, err := os.Stat(live); err != nil {
		t.Fatalf("a live clone's staging was removed: %v", err)
	}
}

// Value: protects=--pretend writes nothing yet judges as the real clone will; fails_when=pretend
// sweeps, or counts stale staging as content; why_new=pretend never met staging; seam=none;
// no_claim=none beyond protects
func TestCloneProject_PretendIgnoresButKeepsDeadStaging(t *testing.T) {
	svc, _ := newCreateSvc(t)
	svc.Pretend = true
	origin := bareRepo(t)
	dest := t.TempDir()
	stale := filepath.Join(dest, stagingName(".clone-", hostOf(t, svc), deadPid(t)))
	mkStaging(t, stale)

	res, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
	if err != nil || !res.WouldClone {
		t.Fatalf("pretend: res %+v, err %v; want WouldClone", res, err)
	}
	if _, err := os.Stat(stale); err != nil {
		t.Fatalf("pretend removed the staging: %v", err)
	}
}

// Value: protects=a clone's staging is named after this machine's persisted id and its process, which
// the sweep relies on; fails_when=CloneProject names staging without its owner; why_new=no test reads
// the names a real clone makes; seam=none; no_claim=none beyond protects
func TestCloneProject_StagingNamesItsOwner(t *testing.T) {
	svc, _ := newCreateSvc(t)
	want := hostOf(t, svc) + "-" + strconv.Itoa(os.Getpid()) + "-"
	stage, err := makeStaging(t.TempDir(), true, svc.stagingOwner())
	if err != nil {
		t.Fatal(err)
	}
	if base := filepath.Base(stage); !strings.HasPrefix(base, ".clone-"+want) {
		t.Fatalf("inside staging %q doesn't name its owner %q", base, want)
	}
	stage, err = makeStaging(filepath.Join(t.TempDir(), "api"), false, svc.stagingOwner())
	if err != nil {
		t.Fatal(err)
	}
	if base := filepath.Base(stage); !strings.HasPrefix(base, ".api.clone-"+want) {
		t.Fatalf("beside staging %q doesn't name its owner %q", base, want)
	}
}

// hostOf is the machine id svc names its staging with; the test fails if it has none.
func hostOf(t *testing.T, svc *Service) string {
	t.Helper()
	host, ok := svc.stagingHost()
	if !ok {
		t.Fatal("no machine id")
	}
	return host
}

// Value: protects=the machine id is made once and then stable, unique to its config folder, never
// the hostname; fails_when=it is derived from the hostname or regenerated each run; why_new=identity
// is what keeps one Mac from sweeping another's live clone; seam=none; no_claim=none beyond protects
func TestStagingHost_PersistsAMachineID(t *testing.T) {
	svc, cfg := newCreateSvc(t)
	first := hostOf(t, svc)
	again := hostOf(t, &Service{Config: cfg})
	if first != again {
		t.Fatalf("machine id changed between runs: %q then %q", first, again)
	}
	other, _ := newCreateSvc(t)
	if hostOf(t, other) == first {
		t.Fatalf("two config folders share machine id %q", first)
	}
	if first == hostnameHash() {
		t.Fatal("machine id is the hostname hash")
	}
	b, err := os.ReadFile(filepath.Join(filepath.Dir(cfg.Path()), "machine-id"))
	if err != nil || strings.TrimSpace(string(b)) != first {
		t.Fatalf("machine-id file holds %q (err %v), want %q", b, err, first)
	}
}

// Value: protects=without a machine id the sweep removes no owned staging, since it can't tell this
// machine's from another's; fails_when=a failed id falls back to matching the hostname; why_new=the
// fail-safe path is otherwise unexercised; seam=none; no_claim=none beyond protects
func TestCloneProject_NoMachineIDSweepsNoOwnedStaging(t *testing.T) {
	cfgDir := t.TempDir()
	cfg, err := config.New(filepath.Join(cfgDir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	svc := &Service{Config: cfg}
	origin := bareRepo(t)
	if err := os.Chmod(cfgDir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(cfgDir, 0o755) })
	if _, ok := svc.stagingHost(); ok {
		t.Skip("config folder is writable here (running as root?)")
	}
	dest := t.TempDir()
	kept := filepath.Join(dest, stagingName(".clone-", hostnameHash(), deadPid(t)))
	mkStaging(t, kept)

	_, err = svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
	if !errors.Is(err, errs.ErrDestinationNotEmpty) {
		t.Fatalf("err = %v, want ErrDestinationNotEmpty", err)
	}
	if _, err := os.Stat(kept); err != nil {
		t.Fatalf("owned staging was swept without a machine id: %v", err)
	}
}

// Value: protects=a folder refused only because of a clone's staging says which folder is in the way;
// fails_when=the refusal is a bare "not empty"; why_new=no test reads the refusal's text; seam=none;
// no_claim=none beyond protects
func TestCloneProject_RefusalNamesBlockingStaging(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	dest := t.TempDir()
	live := stagingName(".clone-", hostOf(t, svc), os.Getpid())
	mkStaging(t, filepath.Join(dest, live))

	_, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
	if !errors.Is(err, errs.ErrDestinationNotEmpty) || !strings.Contains(err.Error(), live) {
		t.Fatalf("err = %v, want ErrDestinationNotEmpty naming %s", err, live)
	}
}

// ageTree sets every path to the given age, deepest first so making a child can't refresh a parent.
func ageTree(t *testing.T, age time.Duration, paths ...string) {
	t.Helper()
	when := time.Now().Add(-age)
	for i := len(paths) - 1; i >= 0; i-- {
		if err := os.Chtimes(paths[i], when, when); err != nil {
			t.Fatal(err)
		}
	}
}

// legacyStaging makes an unowned staging folder (the #636 naming) with a pack in progress, every
// part age old.
func legacyStaging(t *testing.T, path string, age time.Duration) string {
	t.Helper()
	pack := filepath.Join(path, ".git", "objects", "pack")
	if err := os.MkdirAll(pack, 0o755); err != nil {
		t.Fatal(err)
	}
	tmp := filepath.Join(pack, "tmp_pack_x")
	if err := os.WriteFile(tmp, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	ageTree(t, age, path, filepath.Join(path, ".git"), filepath.Join(path, ".git", "objects"), pack, tmp)
	return tmp
}

// Value: protects=an unowned staging folder left by the #636 build is swept once it has been idle
// over an hour, inside and beside; fails_when=unowned names are never swept, or swept by name alone;
// why_new=owned-name tests can't reach the age rule; seam=none; no_claim=does not run the old build
func TestCloneProject_SweepsIdleUnownedStaging(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	t.Run("inside", func(t *testing.T) {
		dest := t.TempDir()
		stale := filepath.Join(dest, ".clone-123456789")
		legacyStaging(t, stale, 2*time.Hour)
		if _, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{}); err != nil {
			t.Fatalf("retry over idle unowned staging: %v", err)
		}
		if _, err := os.Stat(stale); !os.IsNotExist(err) {
			t.Fatalf("idle unowned staging is still there (stat err %v)", err)
		}
	})
	t.Run("beside", func(t *testing.T) {
		parent := t.TempDir()
		stale := filepath.Join(parent, ".api.clone-1x2y3z")
		legacyStaging(t, stale, 2*time.Hour)
		if _, err := svc.CloneProject(context.Background(), "file://"+origin, filepath.Join(parent, "api"), &bytes.Buffer{}); err != nil {
			t.Fatalf("clone failed: %v", err)
		}
		if _, err := os.Stat(stale); !os.IsNotExist(err) {
			t.Fatalf("idle unowned staging is still there (stat err %v)", err)
		}
	})
}

// Value: protects=an unowned staging folder that may belong to a clone still running is kept: one
// idle under an hour, or whose pack is still being written; fails_when=age is read from the folder's
// own time only, missing a long fetch; why_new=no test pairs an old folder with fresh activity;
// seam=none; no_claim=does not run a real long fetch
func TestCloneProject_SweepKeepsActiveUnownedStaging(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T, path string)
	}{
		{"idle under an hour", func(t *testing.T, path string) { legacyStaging(t, path, 30*time.Minute) }},
		{"old folder, pack still growing", func(t *testing.T, path string) {
			tmp := legacyStaging(t, path, 2*time.Hour)
			ageTree(t, time.Minute, tmp)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dest := t.TempDir()
			kept := filepath.Join(dest, ".clone-987654321")
			tc.setup(t, kept)
			_, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
			if !errors.Is(err, errs.ErrDestinationNotEmpty) {
				t.Fatalf("err = %v, want ErrDestinationNotEmpty", err)
			}
			if _, err := os.Stat(kept); err != nil {
				t.Fatalf("possibly active staging was removed: %v", err)
			}
		})
	}
}

// Value: protects=an old folder of the user's that merely matches an unowned staging name is never
// swept: a finished repository (it has an index), a folder without .git, or a name the old build
// couldn't have made; fails_when=the sweep trusts name and age alone; why_new=the other unowned
// tests use real staging shapes only; seam=none; no_claim=none beyond protects
func TestCloneProject_SweepKeepsLookalikeFolders(t *testing.T) {
	svc, _ := newCreateSvc(t)
	origin := bareRepo(t)
	for _, tc := range []struct {
		name, entry string
		setup       func(t *testing.T, path string)
	}{
		{"finished repository", ".clone-123", func(t *testing.T, path string) {
			legacyStaging(t, path, 2*time.Hour)
			index := filepath.Join(path, ".git", "index")
			if err := os.WriteFile(index, nil, 0o644); err != nil {
				t.Fatal(err)
			}
			ageTree(t, 2*time.Hour, path, filepath.Join(path, ".git"), index)
		}},
		{"no .git", ".clone-456", func(t *testing.T, path string) {
			if err := os.MkdirAll(path, 0o755); err != nil {
				t.Fatal(err)
			}
			notes := filepath.Join(path, "notes.txt")
			if err := os.WriteFile(notes, []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			ageTree(t, 2*time.Hour, path, notes)
		}},
		{"letters inside", ".clone-backup", func(t *testing.T, path string) { legacyStaging(t, path, 2*time.Hour) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dest := t.TempDir()
			kept := filepath.Join(dest, tc.entry)
			tc.setup(t, kept)
			_, err := svc.CloneProject(context.Background(), "file://"+origin, dest, &bytes.Buffer{})
			if !errors.Is(err, errs.ErrDestinationNotEmpty) {
				t.Fatalf("err = %v, want ErrDestinationNotEmpty", err)
			}
			if _, err := os.Stat(kept); err != nil {
				t.Fatalf("a lookalike folder was removed: %v", err)
			}
		})
	}
	t.Run("beside, name too long for the old build", func(t *testing.T) {
		parent := t.TempDir()
		kept := filepath.Join(parent, ".api.clone-mybackups")
		legacyStaging(t, kept, 2*time.Hour)
		if _, err := svc.CloneProject(context.Background(), "file://"+origin, filepath.Join(parent, "api"), &bytes.Buffer{}); err != nil {
			t.Fatalf("clone failed: %v", err)
		}
		if _, err := os.Stat(kept); err != nil {
			t.Fatalf("a lookalike folder beside was removed: %v", err)
		}
	})
}

// Value: protects=a process this user may not signal (EPERM) counts as running, so its staging is
// kept, and an exited one does not; fails_when=processAlive reads only a nil kill error; why_new=the
// sweep tests only use our own pid and a reaped child, never another user's process; seam=none;
// no_claim=does not cover Windows
func TestProcessAlive_CountsAnUnsignalableProcessAsRunning(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root may signal pid 1, so there is no EPERM to see")
	}
	if !processAlive(1) {
		t.Fatal("pid 1 (not ours to signal) was taken for dead, so its staging would be swept")
	}
	if processAlive(deadPid(t)) {
		t.Fatal("an exited process was taken for running")
	}
}
