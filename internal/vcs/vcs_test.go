package vcs

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/vcs/vcstest"
)

// MockExecutor records calls and returns canned output.
type MockExecutor struct {
	Output string
	Err    error
	Calls  [][]string
}

func (m *MockExecutor) Run(dir string, name string, args ...string) (string, error) {
	call := append([]string{name}, args...)
	m.Calls = append(m.Calls, call)
	return m.Output, m.Err
}

func TestDetectGit(t *testing.T) {
	dir := t.TempDir()
	vcstest.MakeGitDir(t, dir)

	v, err := Detect(dir)
	if err != nil {
		t.Fatal(err)
	}
	if v == nil {
		t.Fatal("expected Git VCS")
	}
	if v.Type() != TypeGit {
		t.Fatalf("expected git, got %s", v.Type())
	}
	if v.Label() != "Git worktree" {
		t.Fatalf("expected 'Git worktree', got %s", v.Label())
	}
}

// TestDetectIgnoresJJ pins the Jujutsu removal (#266): a colocated repo (.jj beside .git) is
// plain git, and a .jj-only directory — or a stale stored "jj" type — is unsupported.
func TestDetectIgnoresJJ(t *testing.T) {
	colocated := t.TempDir()
	os.Mkdir(filepath.Join(colocated, ".jj"), 0o755)
	vcstest.MakeGitDir(t, colocated)
	v, err := Detect(colocated)
	if err != nil {
		t.Fatal(err)
	}
	if v.Type() != TypeGit {
		t.Fatalf("expected git for a colocated repo, got %s", v.Type())
	}

	jjOnly := t.TempDir()
	os.Mkdir(filepath.Join(jjOnly, ".jj"), 0o755)
	if _, err := Detect(jjOnly); !errors.Is(err, errs.ErrUnsupportedVCS) {
		t.Fatalf("expected ErrUnsupportedVCS for a .jj-only dir, got %v", err)
	}

	if _, err := New("jj"); !errors.Is(err, errs.ErrUnsupportedVCS) {
		t.Fatalf("expected ErrUnsupportedVCS for a stored jj type, got %v", err)
	}
}

func TestDetectNone(t *testing.T) {
	dir := t.TempDir()

	v, err := Detect(dir)
	if !errors.Is(err, errs.ErrUnsupportedVCS) {
		t.Fatalf("expected ErrUnsupportedVCS, got %v", err)
	}
	if v != nil {
		t.Fatalf("expected nil VCS, got %v", v)
	}
}

func TestGitListWorktrees(t *testing.T) {
	mock := &MockExecutor{
		Output: "worktree /project\nHEAD cbace1f043eee2836c7b8494797dfe49f6985716\nbranch refs/heads/master\n\nworktree /workrooms/foo\nHEAD abc123\nbranch refs/heads/workroom/foo\n\nworktree /workrooms/bar\nHEAD def456\nbranch refs/heads/workroom/bar\n",
	}
	git := &Git{Executor: mock}

	workrooms, err := git.ListWorkrooms("/project")
	if err != nil {
		t.Fatal(err)
	}
	if len(workrooms) != 2 {
		t.Fatalf("expected 2 worktrees, got %d: %v", len(workrooms), workrooms)
	}
	if workrooms[0] != "foo" {
		t.Fatalf("expected foo, got %s", workrooms[0])
	}
	if workrooms[1] != "bar" {
		t.Fatalf("expected bar, got %s", workrooms[1])
	}
}

// TestGitListWorktreesSupportsMembershipCheck pins that ListWorkrooms alone (no separate
// WorkroomExists method — removed; it was a hidden full list-and-scan behind a signature that
// looked like a cheap probe) is sufficient for a caller to do its own membership check.
func TestGitListWorktreesSupportsMembershipCheck(t *testing.T) {
	mock := &MockExecutor{
		Output: "worktree /project\nHEAD cbace1f043eee2836c7b8494797dfe49f6985716\nbranch refs/heads/master\n\nworktree /workrooms/foo\nHEAD abc123\nbranch refs/heads/workroom/foo\n",
	}
	git := &Git{Executor: mock}

	worktrees, err := git.ListWorkrooms("/project")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(worktrees, "foo") {
		t.Fatalf("expected foo to be present, got %v", worktrees)
	}
	if slices.Contains(worktrees, "bar") {
		t.Fatalf("expected bar to be absent, got %v", worktrees)
	}
}

func TestGitCreate(t *testing.T) {
	mock := &MockExecutor{}
	git := &Git{Executor: mock}

	_, err := git.Create("/project", "workroom/foo", "/workrooms/foo")
	if err != nil {
		t.Fatal(err)
	}
	expected := []string{"git", "worktree", "add", "-b", "workroom/foo", "/workrooms/foo"}
	for i, v := range expected {
		if mock.Calls[0][i] != v {
			t.Fatalf("expected %s at position %d, got %s", v, i, mock.Calls[0][i])
		}
	}
}

func TestGitDelete(t *testing.T) {
	mock := &MockExecutor{}
	git := &Git{Executor: mock}

	_, err := git.Delete("/project", "workroom/foo", "/workrooms/foo")
	if err != nil {
		t.Fatal(err)
	}
	expected := []string{"git", "worktree", "remove", "/workrooms/foo", "--force"}
	for i, v := range expected {
		if mock.Calls[0][i] != v {
			t.Fatalf("expected %s at position %d, got %s", v, i, mock.Calls[0][i])
		}
	}
}

func TestGitExcludesCurrentDir(t *testing.T) {
	mock := &MockExecutor{
		Output: "worktree /project\nHEAD cbace1f\nbranch refs/heads/master\n",
	}
	git := &Git{Executor: mock}

	workrooms, err := git.ListWorkrooms("/project")
	if err != nil {
		t.Fatal(err)
	}
	if len(workrooms) != 0 {
		t.Fatalf("expected 0 worktrees (cwd excluded), got %d", len(workrooms))
	}
}

func TestGitParsePortableFormat(t *testing.T) {
	output := `worktree /
HEAD cbace1f043eee2836c7b8494797dfe49f6985716
branch refs/heads/master

`
	result := parseGitWorktrees(output, "/")
	if len(result) != 0 {
		t.Fatalf("expected 0 (excluded cwd), got %d", len(result))
	}
}

func TestGitWorktreePathsWithSpaces(t *testing.T) {
	mock := &MockExecutor{
		Output: "worktree /Users/foo/my project\nHEAD cbace1f043eee2836c7b8494797dfe49f6985716\nbranch refs/heads/master\n\nworktree /Users/foo/my workrooms/feature one\nHEAD abc123\nbranch refs/heads/workroom/feature-one\n",
	}
	git := &Git{Executor: mock}

	workrooms, err := git.ListWorkrooms("/Users/foo/my project")
	if err != nil {
		t.Fatal(err)
	}
	if len(workrooms) != 1 {
		t.Fatalf("expected 1 worktree, got %d: %v", len(workrooms), workrooms)
	}
	if workrooms[0] != "feature one" {
		t.Fatalf("expected 'feature one', got %q", workrooms[0])
	}
}

// A folder that is not itself a repository (a workspace Jujutsu left before #266, or a broken
// empty .git) inside another repository: git run there must not discover the ANCESTOR, however
// the folder is spelled (trailing slash, or a symlink in a different folder from its target).
func TestRealExecutorNeverDiscoversAnAncestorRepository(t *testing.T) {
	parent := t.TempDir()
	if out, err := (&RealExecutor{}).Run(parent, "git", "init", "-q"); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	if _, err := (&RealExecutor{}).Run(parent, "git", "rev-parse", "--show-toplevel"); err != nil {
		t.Fatalf("control: git must still work at a repository root: %v", err)
	}
	inner := filepath.Join(parent, "plain", "inner")
	if err := os.MkdirAll(filepath.Join(inner, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	links := filepath.Join(parent, "links")
	if err := os.MkdirAll(links, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(inner, filepath.Join(links, "inner")); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{inner, inner + "/", filepath.Join(links, "inner")} {
		out, err := (&RealExecutor{}).Run(dir, "git", "rev-parse", "--show-toplevel")
		if err == nil || !strings.Contains(out, "not a git repository") {
			t.Fatalf("%s: git discovered the ancestor repository: %q (%v)", dir, out, err)
		}
	}
}

// git splits GIT_CEILING_DIRECTORIES on ':', so a parent containing one would silently disable
// it: no ceiling there; Detect's strict .git check is the backstop (#266 D5).
func TestNoCeilingForAParentPathContainingAColon(t *testing.T) {
	base := t.TempDir()
	colon := filepath.Join(base, "Acme: Inc", "web")
	plain := filepath.Join(base, "plain", "web")
	for _, d := range []string{colon, plain} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if got := ceilingDirectories(colon); got != "" {
		t.Fatalf("ceiling for a colon parent = %q, want none", got)
	}
	want, _ := filepath.EvalSymlinks(filepath.Join(base, "plain"))
	if got := ceilingDirectories(plain); got != want {
		t.Fatalf("ceiling = %q, want %q", got, want)
	}
}

// A .git that git itself would not accept (an empty dir, or HEAD alone) is no repository.
func TestDetectRefusesAGitDirGitWouldNotAccept(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)
	if _, err := Detect(dir); !errors.Is(err, errs.ErrUnsupportedVCS) {
		t.Fatalf("empty .git: expected ErrUnsupportedVCS, got %v", err)
	}
	os.WriteFile(filepath.Join(dir, ".git", "HEAD"), []byte("ref: refs/heads/main\n"), 0o644)
	if _, err := Detect(dir); !errors.Is(err, errs.ErrUnsupportedVCS) {
		t.Fatalf("HEAD-only .git: expected ErrUnsupportedVCS, got %v", err)
	}
	worktree := t.TempDir()
	os.WriteFile(filepath.Join(worktree, ".git"), []byte("gitdir: /elsewhere\n"), 0o644)
	if _, err := Detect(worktree); err != nil {
		t.Fatalf("a gitdir: file is a worktree: %v", err)
	}
}
