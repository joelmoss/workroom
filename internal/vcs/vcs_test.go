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

	_, err := git.Create("/project", "workroom/foo", "/workrooms/foo", "")
	if err != nil {
		t.Fatal(err)
	}
	expected := []string{"git", "worktree", "add", "--no-track", "-b", "workroom/foo", "/workrooms/foo", "refs/remotes/origin/HEAD"}
	if last := mock.Calls[len(mock.Calls)-1]; !slices.Equal(last, expected) {
		t.Fatalf("expected %v, got %v", expected, last)
	}
}

// git runs a git command in dir for a test, with an identity and no signing so commits work on
// any machine.
func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	args = append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"}, args...)
	out, err := (&RealExecutor{}).Run(dir, "git", args...)
	if err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
	return out
}

// createdFrom creates a workroom from project and returns the commit it checked out, failing if
// its branch has an upstream.
func createdFrom(t *testing.T, project string) string {
	t.Helper()
	commit, _ := createdFromBase(t, project, "")
	return commit
}

// createdFromBase is createdFrom with a project base branch, also returning Create's warning.
func createdFromBase(t *testing.T, project, base string) (commit, warning string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "wr")
	warning, err := (&Git{Executor: &RealExecutor{}}).Create(project, "workroom/wr", path, base)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if out, err := (&RealExecutor{}).Run(path, "git", "rev-parse", "--abbrev-ref", "@{upstream}"); err == nil {
		t.Fatalf("workroom branch has an upstream: %s", out)
	}
	return git(t, path, "rev-parse", "HEAD"), warning
}

// A project with origin, its checkout on a feature branch and behind origin's default branch.
// Returns the project, origin's URL, and the commits at origin's default branch before and after
// the project last fetched, and on the feature branch.
func projectBehindOrigin(t *testing.T) (project, origin, fetched, newer, feature string) {
	t.Helper()
	origin = filepath.Join(t.TempDir(), "origin.git")
	git(t, filepath.Dir(origin), "init", "-q", "--bare", "-b", "trunk", origin)
	pusher := filepath.Join(t.TempDir(), "pusher")
	git(t, filepath.Dir(pusher), "clone", "-q", origin, pusher)
	git(t, pusher, "commit", "-q", "--allow-empty", "-m", "fetched")
	git(t, pusher, "push", "-q", "origin", "HEAD:trunk")
	fetched = git(t, pusher, "rev-parse", "HEAD")

	project = filepath.Join(t.TempDir(), "project")
	git(t, filepath.Dir(project), "clone", "-q", origin, project)
	git(t, project, "switch", "-q", "-c", "feature")
	git(t, project, "commit", "-q", "--allow-empty", "-m", "feature")
	feature = git(t, project, "rev-parse", "HEAD")

	git(t, pusher, "commit", "-q", "--allow-empty", "-m", "newer")
	git(t, pusher, "push", "-q", "origin", "HEAD:trunk")
	newer = git(t, pusher, "rev-parse", "HEAD")
	return project, origin, fetched, newer, feature
}

func TestGitCreateBranchesFromOriginsDefaultBranchFetched(t *testing.T) {
	project, _, _, newer, _ := projectBehindOrigin(t)
	got, warning := createdFromBase(t, project, "")
	if got != newer {
		t.Fatalf("workroom at %s, want origin's newest trunk %s", got, newer)
	}
	if warning != "" {
		t.Fatalf("a fetch that worked warned: %q", warning)
	}
}

// The user hears that the base may be stale: an expired token fails every fetch, silently.
func TestGitCreateUsesTheLastFetchWhenOriginIsUnreachable(t *testing.T) {
	project, _, fetched, _, _ := projectBehindOrigin(t)
	git(t, project, "remote", "set-url", "origin", filepath.Join(t.TempDir(), "gone.git"))
	got, warning := createdFromBase(t, project, "")
	if got != fetched {
		t.Fatalf("workroom at %s, want the last-fetched trunk %s", got, fetched)
	}
	if !strings.Contains(warning, "Could not fetch origin") || !strings.Contains(warning, "origin/trunk") {
		t.Fatalf("warning = %q, want it to name the failed fetch and origin/trunk", warning)
	}
}

// A repository with no commits yet (a fresh clone of an empty repository) creates an orphan
// branch, as `git worktree add` without a start point always did; an explicit HEAD is refused.
func TestGitCreateInARepositoryWithNoCommits(t *testing.T) {
	empty := filepath.Join(t.TempDir(), "empty.git")
	git(t, filepath.Dir(empty), "init", "-q", "--bare", empty)
	project := filepath.Join(t.TempDir(), "project")
	git(t, filepath.Dir(project), "clone", "-q", empty, project)
	path := filepath.Join(t.TempDir(), "wr")
	if _, err := (&Git{Executor: &RealExecutor{}}).Create(project, "workroom/wr", path, ""); err != nil {
		t.Fatalf("create in a repository with no commits: %v", err)
	}
	if got := git(t, path, "symbolic-ref", "--short", "HEAD"); got != "workroom/wr" {
		t.Fatalf("workroom on %q, want workroom/wr", got)
	}
}

// A project's base branch: origin's copy, fetched, wins over the stale local one.
func TestGitCreateBranchesFromTheProjectBaseOnOrigin(t *testing.T) {
	project, origin, _, _, _ := projectBehindOrigin(t)
	pusher := filepath.Join(t.TempDir(), "dev")
	git(t, filepath.Dir(pusher), "clone", "-q", origin, pusher)
	git(t, pusher, "switch", "-q", "-c", "develop")
	git(t, pusher, "commit", "-q", "--allow-empty", "-m", "develop")
	git(t, pusher, "push", "-q", "origin", "develop")
	want := git(t, pusher, "rev-parse", "HEAD")
	if got, warning := createdFromBase(t, project, "develop"); got != want || warning != "" {
		t.Fatalf("workroom at %s (warning %q), want origin/develop %s and no warning", got, warning, want)
	}
}

// A base that exists only locally (no origin, or not pushed) is still honoured.
func TestGitCreateBranchesFromALocalOnlyBase(t *testing.T) {
	project := t.TempDir()
	git(t, project, "init", "-q")
	git(t, project, "commit", "-q", "--allow-empty", "-m", "first")
	git(t, project, "switch", "-q", "-c", "develop")
	git(t, project, "commit", "-q", "--allow-empty", "-m", "develop")
	want := git(t, project, "rev-parse", "HEAD")
	git(t, project, "switch", "-q", "-")
	if got, _ := createdFromBase(t, project, "develop"); got != want {
		t.Fatalf("workroom at %s, want local develop %s", got, want)
	}
}

// After origin renames its default branch, new workrooms follow it: fetch alone never moves
// origin/HEAD, and once --prune drops the old branch, origin/HEAD would name nothing.
func TestGitCreateFollowsARenamedDefaultBranch(t *testing.T) {
	project, origin, _, _, _ := projectBehindOrigin(t)
	pusher := filepath.Join(t.TempDir(), "renamer")
	git(t, filepath.Dir(pusher), "clone", "-q", origin, pusher)
	git(t, pusher, "commit", "-q", "--allow-empty", "-m", "on main")
	git(t, pusher, "push", "-q", "origin", "HEAD:main")
	git(t, origin, "symbolic-ref", "HEAD", "refs/heads/main")
	git(t, pusher, "push", "-q", "origin", ":trunk")
	want := git(t, pusher, "rev-parse", "HEAD")
	if got := createdFrom(t, project); got != want {
		t.Fatalf("workroom at %s, want the renamed default branch main %s", got, want)
	}
}

// A base deleted on origin is not used from its stale local copy: the fetch prunes it.
func TestGitCreateDoesNotUseABaseDeletedOnOrigin(t *testing.T) {
	_, origin, _, _, _ := projectBehindOrigin(t)
	pusher := filepath.Join(t.TempDir(), "dev")
	git(t, filepath.Dir(pusher), "clone", "-q", origin, pusher)
	git(t, pusher, "push", "-q", "origin", "HEAD:develop")
	project := filepath.Join(t.TempDir(), "project")
	git(t, filepath.Dir(project), "clone", "-q", origin, project)
	git(t, pusher, "push", "-q", "origin", ":develop")
	path := filepath.Join(t.TempDir(), "wr")
	_, err := (&Git{Executor: &RealExecutor{}}).Create(project, "workroom/wr", path, "develop")
	if !errors.Is(err, errs.ErrBaseBranchNotFound) {
		t.Fatalf("err = %v, want ErrBaseBranchNotFound for a base deleted on origin", err)
	}
}

// Origin answered but lacks the base (deleted after a merge, or never pushed): the local copy is
// used, and the user hears it may be behind.
func TestGitCreateWarnsWhenTheBaseIsOnlyLocal(t *testing.T) {
	project, _, _, _, _ := projectBehindOrigin(t)
	git(t, project, "branch", "develop")
	want := git(t, project, "rev-parse", "develop")
	got, warning := createdFromBase(t, project, "develop")
	if got != want {
		t.Fatalf("workroom at %s, want local develop %s", got, want)
	}
	if !strings.Contains(warning, "Origin has no develop") {
		t.Fatalf("warning = %q, want it to say origin has no develop", warning)
	}
}

// Offline, a missing base may well be on origin: the error says origin was not reached.
func TestGitCreateSaysTheFetchFailedWhenTheBaseIsMissing(t *testing.T) {
	project, _, _, _, _ := projectBehindOrigin(t)
	git(t, project, "remote", "set-url", "origin", filepath.Join(t.TempDir(), "gone.git"))
	_, err := (&Git{Executor: &RealExecutor{}}).Create(project, "workroom/wr", filepath.Join(t.TempDir(), "wr"), "develop")
	if !errors.Is(err, errs.ErrBaseBranchNotFound) || !strings.Contains(err.Error(), "could not fetch origin") {
		t.Fatalf("err = %v, want BaseBranchNotFound naming the failed fetch", err)
	}
}

// A named base that resolves nowhere is the user's typo: refuse, never silently use HEAD.
func TestGitCreateRefusesABaseThatDoesNotExist(t *testing.T) {
	project, _, _, _, _ := projectBehindOrigin(t)
	path := filepath.Join(t.TempDir(), "wr")
	_, err := (&Git{Executor: &RealExecutor{}}).Create(project, "workroom/wr", path, "nope")
	if !errors.Is(err, errs.ErrBaseBranchNotFound) {
		t.Fatalf("err = %v, want ErrBaseBranchNotFound", err)
	}
	if _, statErr := os.Stat(path); statErr == nil {
		t.Fatal("a refused create left a workroom directory")
	}
}

// Value: protects=Create falls back to HEAD when origin exists but has no default branch to track; fails_when=the origin/HEAD rev-parse guard is removed; why_new=the other tests have an origin with commits or none at all; seam=none
func TestGitCreateBranchesFromHEADWhenOriginHasNoDefaultBranch(t *testing.T) {
	empty := filepath.Join(t.TempDir(), "empty.git")
	git(t, filepath.Dir(empty), "init", "-q", "--bare", empty)
	project := t.TempDir()
	git(t, project, "init", "-q")
	git(t, project, "commit", "-q", "--allow-empty", "-m", "only")
	git(t, project, "remote", "add", "origin", empty)
	if got, want := createdFrom(t, project), git(t, project, "rev-parse", "HEAD"); got != want {
		t.Fatalf("workroom at %s, want HEAD %s", got, want)
	}
}

func TestGitCreateBranchesFromHEADWithoutOrigin(t *testing.T) {
	project := t.TempDir()
	git(t, project, "init", "-q")
	git(t, project, "commit", "-q", "--allow-empty", "-m", "only")
	if got, want := createdFrom(t, project), git(t, project, "rev-parse", "HEAD"); got != want {
		t.Fatalf("workroom at %s, want HEAD %s", got, want)
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

// The create's fetch must fail, not ask for https credentials, when there are none.
func TestChildEnvironmentDisablesGitsTerminalPrompt(t *testing.T) {
	t.Setenv("GIT_TERMINAL_PROMPT", "1")
	env := childEnvironment(t.TempDir())
	if !slices.Contains(env, "GIT_TERMINAL_PROMPT=0") || slices.Contains(env, "GIT_TERMINAL_PROMPT=1") {
		t.Fatal("GIT_TERMINAL_PROMPT not forced to 0")
	}
}
