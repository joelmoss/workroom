package workroom

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/vcs/vcstest"
)

// scriptedExecutor answers each git call through answer, and makes the directory a
// `worktree add` names, as git would.
type scriptedExecutor struct {
	calls  [][]string
	answer func(args []string) (string, error)
}

func (e *scriptedExecutor) Run(dir string, name string, args ...string) (string, error) {
	e.calls = append(e.calls, append([]string{name}, args...))
	if slices.Equal(args, []string{"remote"}) {
		return "origin\n", nil
	}
	if len(args) > 1 && args[0] == "worktree" && args[1] == "add" {
		if i := slices.Index(args, "-b"); i >= 0 && i+2 < len(args) {
			_ = os.MkdirAll(args[i+2], 0o755)
		}
	}
	return e.answer(args)
}

func newCreateFixture(t *testing.T, answer func(args []string) (string, error)) (*Service, *scriptedExecutor, string) {
	t.Helper()
	dir := t.TempDir()
	vcstest.MakeGitDir(t, dir)
	exec := &scriptedExecutor{answer: answer}
	svc, _, _ := newTestService(t, &vcs.Git{Executor: exec})
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	if err := svc.Config.SetWorkroomsDir(filepath.Join(dir, "workrooms")); err != nil {
		t.Fatal(err)
	}
	if err := svc.Config.AddProject(dir, "git"); err != nil {
		t.Fatal(err)
	}
	svc.NameGenFunc = func() string { return "foo" }
	return svc, exec, dir
}

func worktreeAdd(calls [][]string) []string {
	for _, c := range calls {
		if len(c) > 2 && c[1] == "worktree" && c[2] == "add" {
			return c
		}
	}
	return nil
}

// A project without a base of its own uses the global one, and its own wins when both are set.
func TestCreateUsesTheGlobalBaseUnlessTheProjectHasOne(t *testing.T) {
	answer := func(args []string) (string, error) {
		if args[0] == "worktree" && args[1] == "list" {
			return gitWorktrees(t.TempDir()), nil
		}
		return "", nil
	}
	svc, exec, dir := newCreateFixture(t, answer)
	if err := svc.Config.SetGlobalBaseBranch("upstream-ish"); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.CreateNamed(dir, nil); err != nil {
		t.Fatal(err)
	}
	if add := worktreeAdd(exec.calls); add == nil || add[len(add)-1] != "refs/remotes/origin/upstream-ish" {
		t.Fatalf("global base: worktree add = %v", add)
	}

	svc, exec, dir = newCreateFixture(t, answer)
	_ = svc.Config.SetGlobalBaseBranch("upstream-ish")
	_ = svc.Config.SetBaseBranch(dir, "develop")
	if _, err := svc.CreateNamed(dir, nil); err != nil {
		t.Fatal(err)
	}
	if add := worktreeAdd(exec.calls); add == nil || add[len(add)-1] != "refs/remotes/origin/develop" {
		t.Fatalf("project base: worktree add = %v", add)
	}
}

// An app-wide default that doesn't exist in this project (`upstream/main` with no upstream) falls
// back to origin's default branch with a warning; it must not block the create.
func TestCreateFallsBackWhenTheGlobalBaseDoesNotFit(t *testing.T) {
	svc, exec, dir := newCreateFixture(t, func(args []string) (string, error) {
		switch {
		case args[0] == "worktree" && args[1] == "list":
			return gitWorktrees(t.TempDir()), nil
		case args[0] == "rev-parse" && args[1] == "--verify" && !strings.HasPrefix(args[3], "refs/remotes/origin/HEAD"):
			return "", os.ErrNotExist
		}
		return "", nil
	})
	if err := svc.Config.SetGlobalBaseBranch("upstream/main"); err != nil {
		t.Fatal(err)
	}
	res, err := svc.CreateNamed(dir, nil)
	if err != nil {
		t.Fatalf("a global base that doesn't fit blocked the create: %v", err)
	}
	if add := worktreeAdd(exec.calls); add == nil || add[len(add)-1] != "refs/remotes/origin/HEAD" {
		t.Fatalf("worktree add = %v, want origin's default branch", add)
	}
	if !strings.Contains(res.Warning, "default base branch upstream/main") {
		t.Fatalf("warning = %q, want it to name the default that was not used", res.Warning)
	}
	fetches := 0
	for _, c := range exec.calls {
		if len(c) > 1 && c[1] == "fetch" {
			fetches++
		}
	}
	if fetches != 1 {
		t.Fatalf("%d fetches, want one", fetches)
	}
}

// A failed fetch reaches the result and the human output as a warning.
func TestCreateReportsAFailedFetch(t *testing.T) {
	svc, _, dir := newCreateFixture(t, func(args []string) (string, error) {
		switch {
		case args[0] == "worktree" && args[1] == "list":
			return gitWorktrees(t.TempDir()), nil
		case args[0] == "fetch":
			return "", os.ErrDeadlineExceeded
		case args[0] == "rev-parse" && args[1] == "--abbrev-ref":
			return "origin/main", nil
		}
		return "", nil
	})
	res, err := svc.CreateNamed(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.Warning, "Could not fetch origin") || !strings.Contains(res.Warning, "origin/main") {
		t.Fatalf("warning = %q, want the fetch warning naming origin/main", res.Warning)
	}
}

// The workroom's own setup script runs, not the root checkout's, which can be older.
func TestCreateRunsTheWorkroomsOwnSetupScript(t *testing.T) {
	var svc *Service
	var dir string
	svc, _, dir = newCreateFixture(t, func(args []string) (string, error) {
		if args[0] == "worktree" && args[1] == "list" {
			return gitWorktrees(dir), nil
		}
		if args[0] == "worktree" && args[1] == "add" {
			wr := args[slices.Index(args, "-b")+2]
			writeScript(t, wr, "echo from-the-workroom")
		}
		return "", nil
	})
	writeScript(t, dir, "echo from-the-root")
	res, err := svc.CreateNamed(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.SetupOutput, "from-the-workroom") || strings.Contains(res.SetupOutput, "from-the-root") {
		t.Fatalf("setup output = %q, want only the workroom's script", res.SetupOutput)
	}
}

// A local-only script in the root checkout (gitignored, so absent from the workroom) still runs.
func TestCreateFallsBackToTheRootSetupScript(t *testing.T) {
	var dir string
	svc, _, d := newCreateFixture(t, func(args []string) (string, error) {
		if args[0] == "worktree" && args[1] == "list" {
			return gitWorktrees(dir), nil
		}
		return "", nil
	})
	dir = d
	writeScript(t, dir, "echo from-the-root")
	res, err := svc.CreateNamed(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.SetupOutput, "from-the-root") {
		t.Fatalf("setup output = %q, want the root's script", res.SetupOutput)
	}
}

func writeScript(t *testing.T, base, body string) {
	t.Helper()
	scripts := filepath.Join(base, "scripts")
	if err := os.MkdirAll(scripts, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scripts, "workroom_setup"), []byte("#!/usr/bin/env bash\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

// A base that resolves nowhere keeps its own kind through CreateNamed, so `create --json` says
// BaseBranchNotFound, not VCSCommandFailed.
func TestCreateKeepsTheBaseBranchNotFoundKind(t *testing.T) {
	svc, _, dir := newCreateFixture(t, func(args []string) (string, error) {
		switch {
		case args[0] == "worktree" && args[1] == "list":
			return gitWorktrees(t.TempDir()), nil
		case args[0] == "rev-parse" && args[1] == "--verify":
			return "", os.ErrNotExist
		}
		return "", nil
	})
	if err := svc.Config.SetBaseBranch(dir, "nope"); err != nil {
		t.Fatal(err)
	}
	_, err := svc.CreateNamed(dir, nil)
	if !errors.Is(err, ErrBaseBranchNotFound) || errors.Is(err, ErrVCSCommand) {
		t.Fatalf("err = %v, want BaseBranchNotFound and not VCSCommandFailed", err)
	}
}

// Offline, the fetch and a networked setup script fail together: the warning still shows.
func TestCreateShowsTheFetchWarningWhenSetupFails(t *testing.T) {
	var dir string
	svc, _, d := newCreateFixture(t, func(args []string) (string, error) {
		switch {
		case args[0] == "worktree" && args[1] == "list":
			return gitWorktrees(dir), nil
		case args[0] == "fetch":
			return "", os.ErrDeadlineExceeded
		}
		return "", nil
	})
	dir = d
	writeScript(t, dir, "exit 1")
	res, err := svc.CreateNamed(dir, nil)
	if err == nil {
		t.Fatal("a failing setup script reported success")
	}
	if !strings.Contains(res.Warning, "Could not fetch origin") {
		t.Fatalf("warning = %q, want the fetch warning", res.Warning)
	}
}

// Teardown runs the workroom's own script, as setup does, so a pair comes from one place.
func TestTeardownRunsTheWorkroomsOwnScript(t *testing.T) {
	dir := t.TempDir()
	vcstest.MakeGitDir(t, dir)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	writeTeardown(t, wrPath, "echo from-the-workroom")
	writeTeardown(t, dir, "echo from-the-root")
	svc, buf, _ := newTestService(t, &vcs.Git{Executor: &mockExecutor{output: gitWorktrees(dir, wrPath)}})
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	_ = svc.Config.SetWorkroomsDir(workroomsDir)
	_ = svc.Config.AddWorkroom(dir, "foo", wrPath, "git")

	if err := svc.RunTeardown(dir, "foo"); err != nil {
		t.Fatal(err)
	}
	if out := buf.String(); !strings.Contains(out, "from-the-workroom") || strings.Contains(out, "from-the-root") {
		t.Fatalf("output = %q, want only the workroom's teardown", out)
	}
}

// A teardown runs only in a folder git registers as a worktree of the project. A folder of the
// user's with a listed worktree's name, and the project's own checkout, are refused before
// anything runs, under Pretend and SkipTeardown too. A symlinked workrooms folder still finds its
// own worktree.
func TestTeardownRunsOnlyInAWorktreeGitRegistersForTheProject(t *testing.T) {
	dir := t.TempDir()
	vcstest.MakeGitDir(t, dir)
	workrooms := filepath.Join(t.TempDir(), "workrooms")
	ours := filepath.Join(workrooms, "ours")
	writeTeardown(t, ours, "echo ran-ours")
	writeTeardown(t, filepath.Join(workrooms, "mine"), "echo ran-mine")
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(workrooms, link); err != nil {
		t.Fatal(err)
	}
	// Git lists `ours` there, and a worktree named `mine` elsewhere.
	listed := gitWorktrees(dir, ours, filepath.Join(t.TempDir(), "mine"))
	svc, buf, cfg := newTestService(t, &vcs.Git{Executor: &mockExecutor{output: listed}})
	if err := cfg.SetWorkroomsDir(link); err != nil {
		t.Fatal(err)
	}

	for _, mode := range []string{"run", "pretend", "skip"} {
		svc.Pretend, svc.SkipTeardown = mode == "pretend", mode == "skip"
		err := svc.RunTeardown(dir, "mine")
		if !errors.Is(err, ErrGitWorktreeNotFound) {
			t.Fatalf("%s: err = %v, want ErrGitWorktreeNotFound", mode, err)
		}
		want := `git worktree does not exist: git lists no worktree of this project at "` + filepath.Join(link, "mine") + `"`
		if err.Error() != want {
			t.Fatalf("%s: err = %q, want %q", mode, err, want)
		}
	}
	svc.Pretend, svc.SkipTeardown = false, false
	if err := svc.RunTeardown(dir, "ours"); err != nil {
		t.Fatal(err)
	}
	if out := buf.String(); !strings.Contains(out, "ran-ours") || strings.Contains(out, "ran-mine") {
		t.Fatalf("output = %q, want only the registered worktree's teardown", out)
	}

	// The project's own checkout, at <workrooms>/<name>, is no workroom.
	if err := cfg.SetWorkroomsDir(filepath.Dir(dir)); err != nil {
		t.Fatal(err)
	}
	if err := svc.RunTeardown(dir, filepath.Base(dir)); !errors.Is(err, ErrGitWorktreeNotFound) {
		t.Fatalf("the project's own checkout: err = %v, want ErrGitWorktreeNotFound", err)
	}
}

func writeTeardown(t *testing.T, base, body string) {
	t.Helper()
	scripts := filepath.Join(base, "scripts")
	if err := os.MkdirAll(scripts, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scripts, "workroom_teardown"), []byte("#!/usr/bin/env bash\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}
