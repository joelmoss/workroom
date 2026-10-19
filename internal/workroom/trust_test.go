package workroom

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs"
)

// swappingGit is real git whose Create rewrites the new workroom's setup script once the worktree
// exists: bytes that change between the early check and the run.
type swappingGit struct{ *vcs.Git }

func (g swappingGit) Create(dir, vcsName, path, base string, fallback bool, p vcs.Progress) (string, error) {
	warning, err := g.Git.Create(dir, vcsName, path, base, fallback, p)
	if err == nil {
		err = os.WriteFile(filepath.Join(path, "scripts", SetupScript), []byte("#!/bin/sh\necho swapped\n"), 0o755)
	}
	return warning, err
}

func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	if out, err := exec.Command("git", append([]string{"-C", dir, "-c", "commit.gpgsign=false"}, args...)...).CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
}

// The script about to run is hashed where it is, and refused when it is not the approved one,
// even though the bytes the early check read were.
func TestASetupScriptThatChangesAfterTheEarlyCheckIsRefused(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	project := filepath.Join(dir, "app")
	if err := os.MkdirAll(filepath.Join(project, "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, project, "init", "-q", "-b", "main")
	approved := []byte("#!/bin/sh\necho approved\n")
	if err := os.WriteFile(filepath.Join(project, "scripts", SetupScript), approved, 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, project, "add", ".")
	gitIn(t, project, "commit", "-q", "-m", "setup")

	svc, _, _ := newTestService(t, swappingGit{&vcs.Git{Executor: &vcs.RealExecutor{}}})
	if err := svc.Config.SetWorkroomsDir(filepath.Join(dir, "workrooms")); err != nil {
		t.Fatal(err)
	}
	if err := svc.Config.AddProject(project, "git"); err != nil {
		t.Fatal(err)
	}
	sc, _, err := svc.RootScript(project, SetupScript)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.Trust(project, sc); err != nil {
		t.Fatal(err)
	}
	svc.NameGenFunc = func() string { return "swap" }
	svc.ApproveScriptFn = nil

	res, err := svc.CreateNamed(project, nil)
	var untrusted *UntrustedScriptError
	if !errors.As(err, &untrusted) || untrusted.Script.Origin != OriginWorkroom {
		t.Fatalf("err = %v, want the workroom's changed copy refused", err)
	}
	if res.SetupOutput != "" {
		t.Fatalf("the script ran: %q", res.SetupOutput)
	}
}
