package workroom

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs"
)

// pinFixture is a project cloned from origin with a setup script in its only commit, and a pusher
// clone to move origin on. It returns the service, the project, the pusher and that commit.
func pinFixture(t *testing.T) (svc *Service, project, pusher, first string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	origin := filepath.Join(dir, "origin.git")
	gitIn(t, dir, "init", "-q", "--bare", "-b", "main", origin)
	pusher = filepath.Join(dir, "pusher")
	gitIn(t, dir, "clone", "-q", origin, pusher)
	commitScript(t, pusher, "#!/bin/sh\necho first\n")
	first = revParse(t, pusher, "HEAD")
	project = filepath.Join(dir, "app")
	gitIn(t, dir, "clone", "-q", origin, project)

	svc, _, _ = newTestService(t, &vcs.Git{Executor: &vcs.RealExecutor{}})
	if err := svc.Config.SetWorkroomsDir(filepath.Join(dir, "workrooms")); err != nil {
		t.Fatal(err)
	}
	if err := svc.Config.AddProject(project, "git"); err != nil {
		t.Fatal(err)
	}
	svc.ApproveScriptFn = nil
	return svc, project, pusher, first
}

// commitScript commits text as the setup script in repo and pushes it to origin's main.
func commitScript(t *testing.T, repo, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(repo, "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "scripts", SetupScript), []byte(text), 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, repo, "add", ".")
	gitIn(t, repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "setup")
	gitIn(t, repo, "push", "-q", "origin", "HEAD:main")
}

func revParse(t *testing.T, repo, rev string) string {
	t.Helper()
	out, err := exec.Command("git", "-C", repo, "rev-parse", rev).Output()
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(out))
}

// Value: protects=answering the setup-script question continues from the commit it was asked
// about: the refusal names it, and the pinned create starts there and runs the script the user
// approved, though a fetch since moved origin onto a different script (ADR 0059); fails_when=the
// refusal names no commit, or the answer starts from the moved ref and refuses its other script;
// no_claim=the --json envelope and the app's retry (cmd and app tests)
func TestAnsweringTheScriptQuestionContinuesFromTheCommitItWasAskedAbout(t *testing.T) {
	svc, project, pusher, first := pinFixture(t)
	svc.NameGenFunc = func() string { return "asked" }

	_, err := svc.CreateNamed(project, nil)
	var untrusted *UntrustedScriptError
	var question *vcs.QuestionError
	if !errors.As(err, &untrusted) || !errors.As(err, &question) {
		t.Fatalf("err = %v, want the setup script refused as a create question", err)
	}
	if question.StartCommit != first {
		t.Fatalf("StartCommit = %s, want the start the question was asked at %s", question.StartCommit, first)
	}

	// While the sheet is open: origin moves on, with another script, and a background fetch lands.
	commitScript(t, pusher, "#!/bin/sh\necho second\n")
	gitIn(t, project, "fetch", "-q", "origin")
	if err := svc.Trust(project, untrusted.Script); err != nil {
		t.Fatal(err)
	}

	svc.NameGenFunc = func() string { return "answered" }
	svc.StartCommit = question.StartCommit
	res, err := svc.CreateNamed(project, nil)
	if err != nil {
		t.Fatalf("answered create: %v", err)
	}
	if got := revParse(t, res.Path, "HEAD"); got != first {
		t.Fatalf("workroom at %s, want the commit asked about %s", got, first)
	}
	if !strings.Contains(res.SetupOutput, "first") {
		t.Fatalf("setup output = %q, want the approved script's", res.SetupOutput)
	}
}

// Value: protects=a pin the create can't use keeps its own error kind through CreateNamed, so the
// app can tell it from a git failure and Try Again; fails_when=it is folded into ErrVCSCommand;
// no_claim=the exit code (cmd tests)
func TestAnUnusablePinIsItsOwnError(t *testing.T) {
	svc, project, _, _ := pinFixture(t)
	svc.NameGenFunc = func() string { return "stray" }
	svc.StartCommit = strings.Repeat("ab", 20)
	_, err := svc.CreateNamed(project, nil)
	if !errors.Is(err, ErrStartCommitUnusable) || errors.Is(err, ErrVCSCommand) {
		t.Fatalf("err = %v, want ErrStartCommitUnusable and not ErrVCSCommand", err)
	}
}
