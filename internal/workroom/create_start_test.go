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

// The project's base branch reaches the worktree's start point.
func TestCreateStartsFromTheProjectBaseBranch(t *testing.T) {
	svc, exec, dir := newCreateFixture(t, func(args []string) (string, error) {
		if args[0] == "worktree" && args[1] == "list" {
			return gitWorktrees(t.TempDir()), nil
		}
		return "", nil
	})
	if err := svc.Config.SetBaseBranch(dir, "develop"); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.CreateNamed(dir, nil); err != nil {
		t.Fatal(err)
	}
	if add := worktreeAdd(exec.calls); add == nil || add[len(add)-1] != "refs/remotes/origin/develop" {
		t.Fatalf("worktree add = %v, want it to start from refs/remotes/origin/develop", add)
	}
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
	if err := svc.Create(dir); err != nil {
		t.Fatal(err)
	}
	out := svc.Out.(interface{ String() string }).String()
	if !strings.Contains(out, "Could not fetch origin") || !strings.Contains(out, "origin/main") {
		t.Fatalf("output = %q, want the fetch warning naming origin/main", out)
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
	if err := svc.Create(dir); err == nil {
		t.Fatal("a failing setup script reported success")
	}
	if out := svc.Out.(interface{ String() string }).String(); !strings.Contains(out, "Could not fetch origin") {
		t.Fatalf("output = %q, want the fetch warning", out)
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
