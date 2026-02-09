package vcs

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/joelmoss/workroom/internal/errs"
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

func TestDetectJJ(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)

	v, err := Detect(dir)
	if err != nil {
		t.Fatal(err)
	}
	if v == nil {
		t.Fatal("expected JJ VCS")
	}
	if v.Type() != TypeJJ {
		t.Fatalf("expected jj, got %s", v.Type())
	}
	if v.Label() != "JJ workspace" {
		t.Fatalf("expected 'JJ workspace', got %s", v.Label())
	}
}

func TestDetectGit(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)

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

func TestDetectJJPriority(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)

	v, err := Detect(dir)
	if err != nil {
		t.Fatal(err)
	}
	if v.Type() != TypeJJ {
		t.Fatalf("expected jj (priority), got %s", v.Type())
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

func TestJJListWorkrooms(t *testing.T) {
	mock := &MockExecutor{
		Output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: qo a41890ed (empty) (no description set)\nworkroom/bar: xz b12345 (no description set)\n",
	}
	jj := &JJ{Executor: mock}

	workrooms, err := jj.ListWorkrooms("/project")
	if err != nil {
		t.Fatal(err)
	}
	if len(workrooms) != 2 {
		t.Fatalf("expected 2 workrooms, got %d: %v", len(workrooms), workrooms)
	}
	if workrooms[0] != "workroom/foo" {
		t.Fatalf("expected workroom/foo, got %s", workrooms[0])
	}
	if workrooms[1] != "workroom/bar" {
		t.Fatalf("expected workroom/bar, got %s", workrooms[1])
	}
}

func TestJJWorkroomExists(t *testing.T) {
	mock := &MockExecutor{
		Output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: qo a41890ed (empty) (no description set)\n",
	}
	jj := &JJ{Executor: mock}

	exists, err := jj.WorkroomExists("/project", "foo")
	if err != nil {
		t.Fatal(err)
	}
	if !exists {
		t.Fatal("expected workspace to exist")
	}

	exists, err = jj.WorkroomExists("/project", "bar")
	if err != nil {
		t.Fatal(err)
	}
	if exists {
		t.Fatal("expected workspace to not exist")
	}
}

func TestJJCreate(t *testing.T) {
	mock := &MockExecutor{}
	jj := &JJ{Executor: mock}

	_, err := jj.Create("/project", "workroom/foo", "/workrooms/foo")
	if err != nil {
		t.Fatal(err)
	}
	if len(mock.Calls) != 1 {
		t.Fatalf("expected 1 call, got %d", len(mock.Calls))
	}
	expected := []string{"jj", "workspace", "add", "/workrooms/foo", "--name", "workroom/foo"}
	for i, v := range expected {
		if mock.Calls[0][i] != v {
			t.Fatalf("expected %s at position %d, got %s", v, i, mock.Calls[0][i])
		}
	}
}

func TestJJDelete(t *testing.T) {
	mock := &MockExecutor{}
	jj := &JJ{Executor: mock}

	_, err := jj.Delete("/project", "workroom/foo", "/workrooms/foo")
	if err != nil {
		t.Fatal(err)
	}
	expected := []string{"jj", "workspace", "forget", "workroom/foo"}
	for i, v := range expected {
		if mock.Calls[0][i] != v {
			t.Fatalf("expected %s at position %d, got %s", v, i, mock.Calls[0][i])
		}
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

func TestGitWorktreeExists(t *testing.T) {
	mock := &MockExecutor{
		Output: "worktree /project\nHEAD cbace1f043eee2836c7b8494797dfe49f6985716\nbranch refs/heads/master\n\nworktree /workrooms/foo\nHEAD abc123\nbranch refs/heads/workroom/foo\n",
	}
	git := &Git{Executor: mock}

	exists, err := git.WorkroomExists("/project", "foo")
	if err != nil {
		t.Fatal(err)
	}
	if !exists {
		t.Fatal("expected worktree to exist")
	}

	exists, err = git.WorkroomExists("/project", "bar")
	if err != nil {
		t.Fatal(err)
	}
	if exists {
		t.Fatal("expected worktree to not exist")
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

func TestJJParseIgnoresDefaultAndEmpty(t *testing.T) {
	output := "default: mk 6ec05f05 (no description set)\n\n"
	result := parseJJWorkspaces(output)
	if len(result) != 0 {
		t.Fatalf("expected 0 workspaces, got %d: %v", len(result), result)
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

func TestJJListError(t *testing.T) {
	mock := &MockExecutor{
		Err: fmt.Errorf("jj not found"),
	}
	jj := &JJ{Executor: mock}

	_, err := jj.ListWorkrooms("/project")
	if err == nil {
		t.Fatal("expected error")
	}
}
