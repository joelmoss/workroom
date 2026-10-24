package cmd

import (
	"encoding/json"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// pinEnvelope is the part of a create's --json envelope an answer to a create question reads.
type pinEnvelope struct {
	Error struct {
		Kind string `json:"kind"`
	} `json:"error"`
	StartCommit string `json:"start_commit"`
	Path        string `json:"path"`
}

func decodePin(t *testing.T, stdout []byte) pinEnvelope {
	t.Helper()
	var env pinEnvelope
	if err := json.Unmarshal(stdout, &env); err != nil {
		t.Fatalf("not one JSON envelope: %q", stdout)
	}
	return env
}

// moveOrigin pushes a new commit onto origin's main (home/app.git) from a clone of its own, as
// someone else's push would, and fetches it into project, as the app's background fetch would.
func moveOrigin(t *testing.T, home, project string) string {
	t.Helper()
	other := filepath.Join(home, "other")
	run(t, home, "git", "clone", "-q", filepath.Join(home, "app.git"), other)
	run(t, other, "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
		"commit", "-q", "--allow-empty", "-m", "moved")
	run(t, other, "git", "push", "-q", "origin", "HEAD:main")
	run(t, project, "git", "fetch", "-q", "origin")
	return strings.TrimSpace(run(t, other, "git", "rev-parse", "HEAD"))
}

// Value: protects=answering the start question continues from the commit it was asked about: the
// refusal names it, and the answer pinned to it starts there with no fetch step, though origin has
// since moved (ADR 0059); fails_when=the envelope lacks start_commit, the flag doesn't reach the
// create, or the answer starts from the moved origin or reports a fetch; no_claim=the app passing it
func TestAnsweringTheStartQuestionContinuesFromItsStartCommit(t *testing.T) {
	home, project := aheadProject(t)
	asked := strings.TrimSpace(run(t, project, "git", "rev-parse", "origin/main"))

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "ask", "--project", project)
	env := decodePin(t, r.stdout)
	if r.code != 3 || env.Error.Kind != "LocalWorkLeftOut" || env.StartCommit != asked {
		t.Fatalf("exit %d kind %q start_commit %q, want 3 LocalWorkLeftOut at %s: %s", r.code, env.Error.Kind, env.StartCommit, asked, r.stdout)
	}

	if moved := moveOrigin(t, home, project); moved == asked {
		t.Fatal("origin didn't move")
	}
	r = runCLI(t, "create", "--json", "--no-editor", "--start", "origin", "--start-commit", env.StartCommit, "--project", project)
	created := decodePin(t, r.stdout)
	if r.code != 0 {
		t.Fatalf("answer: exit %d, %s", r.code, r.stdout)
	}
	if got := strings.TrimSpace(run(t, created.Path, "git", "rev-parse", "HEAD")); got != asked {
		t.Fatalf("workroom at %s, want the commit asked about %s", got, asked)
	}
	if strings.Contains(string(r.stderr), `"id":"fetch"`) {
		t.Fatalf("a pinned create reported a fetch step:\n%s", r.stderr)
	}
}

// Value: protects=a pin the create can't use fails as its own kind with the precondition exit code,
// so the app turns it into a Try Again rather than a git failure; fails_when=it reports
// VCSCommandFailed or exits 1; no_claim=the app's Try Again
func TestAnUnusableStartCommitIsItsOwnErrorKind(t *testing.T) {
	_, project := originProject(t)
	r := runCLI(t, "create", "--json", "--no-editor", "--start-commit", strings.Repeat("ab", 20), "--project", project)
	if env := decodePin(t, r.stdout); r.code != 3 || env.Error.Kind != "StartCommitUnusable" {
		t.Fatalf("exit %d kind %q, want 3 StartCommitUnusable: %s", r.code, env.Error.Kind, r.stdout)
	}
}

// Value: protects=--start-commit takes only a commit hash, so it never reaches git as an option or
// a ref expression; fails_when="--upload-pack=..." or "HEAD~1" is passed on; no_claim=none
func TestStartCommitMustBeACommitHash(t *testing.T) {
	_, project := originProject(t)
	for _, pin := range []string{"--upload-pack=touch x", "HEAD~1", "abc"} {
		r := runCLI(t, "create", "--json", "--no-editor", "--start-commit", pin, "--project", project)
		if r.code == 0 || !strings.Contains(string(r.stdout), "--start-commit") {
			t.Fatalf("--start-commit %q: exit %d, %s; want it refused by name", pin, r.code, r.stdout)
		}
	}
}

// Value: protects=--start-commit is the app's, not a person's: create's help doesn't offer it;
// fails_when=it shows in --help; no_claim=none
func TestStartCommitIsHidden(t *testing.T) {
	r := runCLI(t, "create", "--help")
	if regexp.MustCompile(`start-commit`).Match(r.stdout) {
		t.Fatalf("create --help offers --start-commit:\n%s", r.stdout)
	}
}
