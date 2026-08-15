package workroom

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/vcs"
)

// mockExecutor returns canned VCS output for testing.
type mockExecutor struct {
	output string
	err    error
	calls  [][]string
	onRun  func(dir, name string, args []string) // optional side effect
}

func (m *mockExecutor) Run(dir string, name string, args ...string) (string, error) {
	call := append([]string{name}, args...)
	m.calls = append(m.calls, call)
	if m.onRun != nil {
		m.onRun(dir, name, args)
	}
	return m.output, m.err
}

func newTestConfig(t *testing.T, path string) *config.Config {
	t.Helper()
	cfg, err := config.New(path)
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func newTestService(t *testing.T, v vcs.VCS) (*Service, *bytes.Buffer, *config.Config) {
	t.Helper()
	dir := t.TempDir()
	cfg := newTestConfig(t, filepath.Join(dir, "config.json"))
	var buf bytes.Buffer
	svc := &Service{
		Config:         cfg,
		VCS:            v,
		Out:            &buf,
		ConfirmFn:      func(string) (bool, error) { return true, nil },
		PromptFn:       func(string, []string) ([]string, error) { return nil, nil },
		OpenEditorFunc: func(string, string) error { return nil },
	}
	return svc, &buf, cfg
}

// --- CheckNotInWorkroom ---

func TestCheckNotInWorkroom(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, ".Workroom"), []byte{}, 0o644)

	svc := &Service{}
	err := svc.CheckNotInWorkroom(dir)
	if !errors.Is(err, ErrInWorkroom) {
		t.Fatalf("expected ErrInWorkroom, got %v", err)
	}
}

func TestCheckNotInWorkroomOK(t *testing.T) {
	dir := t.TempDir()
	svc := &Service{}
	err := svc.CheckNotInWorkroom(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// --- Create ---

func TestCreateErrorsIfNotJJOrGit(t *testing.T) {
	dir := t.TempDir()
	svc := &Service{
		Config: newTestConfig(t, filepath.Join(dir, "config.json")),
		Out:    &bytes.Buffer{},
	}

	err := svc.Create(dir)
	if !errors.Is(err, ErrUnsupportedVCS) {
		t.Fatalf("expected ErrUnsupportedVCS, got %v", err)
	}
}

func TestCreateErrorsIfInWorkroom(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, ".Workroom"), []byte{}, 0o644)

	svc := &Service{Out: &bytes.Buffer{}}
	err := svc.Create(dir)
	if !errors.Is(err, ErrInWorkroom) {
		t.Fatalf("expected ErrInWorkroom, got %v", err)
	}
}

func TestCreateSucceedsJJ(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)

	workroomsDir := filepath.Join(dir, "workrooms")

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, buf, cfg := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))

	// Override workrooms dir
	svc.Config.SetWorkroomsDir(workroomsDir)

	nameIdx := 0
	svc.NameGenFunc = func() string {
		nameIdx++
		return "foo"
	}

	err := svc.Create(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "Workroom 'foo' created successfully") {
		t.Fatalf("expected success message, got %q", output)
	}

	// Verify config was updated
	data, _ := cfg.Read()
	_ = data // config updated via svc.Config, not cfg

	data2, _ := svc.Config.Read()
	project := data2[dir].(map[string]any)
	if project["vcs"] != "jj" {
		t.Fatalf("expected vcs jj, got %v", project["vcs"])
	}

	workrooms := project["workrooms"].(map[string]any)
	foo := workrooms["foo"].(map[string]any)
	if foo["path"] != filepath.Join(workroomsDir, "foo") {
		t.Fatalf("expected workroom path, got %v", foo["path"])
	}
}

func TestCreateSucceedsGit(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)

	workroomsDir := filepath.Join(dir, "workrooms")

	mock := &mockExecutor{
		output: "worktree " + dir + "\nHEAD cbace1f\nbranch refs/heads/master\n",
	}
	git := &vcs.Git{Executor: mock}

	svc, buf, _ := newTestService(t, git)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)

	svc.NameGenFunc = func() string { return "bar" }

	err := svc.Create(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "Workroom 'bar' created successfully") {
		t.Fatalf("expected success message, got %q", output)
	}
}

func TestCreateRunsSetupScript(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	// Create setup script
	scriptsDir := filepath.Join(dir, "scripts")
	os.MkdirAll(scriptsDir, 0o755)
	scriptPath := filepath.Join(scriptsDir, "workroom_setup")
	os.WriteFile(scriptPath, []byte("#!/usr/bin/env bash\necho \"I succeeded\"\nexit 0\n"), 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)",
		onRun: func(dir, name string, args []string) {
			// Simulate jj workspace add creating the directory
			if name == "jj" && len(args) > 1 && args[0] == "workspace" && args[1] == "add" {
				os.MkdirAll(args[2], 0o755)
			}
		},
	}
	jj := &vcs.JJ{Executor: mock}

	svc, buf, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.NameGenFunc = func() string { return "foo" }

	err := svc.Create(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	// Setup output is rendered inside a titled log panel with a gutter border.
	if !strings.Contains(output, "╭─ Setup ") {
		t.Fatalf("expected setup log panel header, got %q", output)
	}
	if !strings.Contains(output, "│ I succeeded") {
		t.Fatalf("expected gutter-prefixed setup output, got %q", output)
	}
	if !strings.Contains(output, "Workroom 'foo' created successfully") {
		t.Fatalf("expected success message, got %q", output)
	}
}

func TestCreateOnReadyFiresBeforeSetup(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	// Setup script records a marker so we can assert ordering relative to OnReady.
	scriptsDir := filepath.Join(dir, "scripts")
	os.MkdirAll(scriptsDir, 0o755)
	marker := filepath.Join(dir, "setup-ran")
	scriptPath := filepath.Join(scriptsDir, "workroom_setup")
	os.WriteFile(scriptPath, []byte("#!/usr/bin/env bash\ntouch "+marker+"\n"), 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)",
		onRun: func(_, name string, args []string) {
			if name == "jj" && len(args) > 1 && args[0] == "workspace" && args[1] == "add" {
				os.MkdirAll(args[2], 0o755)
			}
		},
	}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.NameGenFunc = func() string { return "foo" }

	var ready *CreateResult
	var setupRanWhenReady bool
	svc.OnReady = func(r CreateResult) {
		ready = &r
		_, err := os.Stat(marker)
		setupRanWhenReady = err == nil // setup must NOT have run yet
	}

	if _, err := svc.CreateNamed(dir, nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ready == nil {
		t.Fatal("OnReady was not called")
	}
	if ready.Name != "foo" || ready.Path != filepath.Join(workroomsDir, "foo") {
		t.Fatalf("OnReady got unexpected result: %+v", *ready)
	}
	if !ready.HasSetup {
		t.Fatal("OnReady result should report HasSetup when a setup script exists")
	}
	if setupRanWhenReady {
		t.Fatal("OnReady fired after the setup script ran; it must fire before")
	}
}

func TestCreateOnReadyReportsNoSetupScript(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	// No scripts/workroom_setup exists, so HasSetup must be false.
	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)",
		onRun: func(_, name string, args []string) {
			if name == "jj" && len(args) > 1 && args[0] == "workspace" && args[1] == "add" {
				os.MkdirAll(args[2], 0o755)
			}
		},
	}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.NameGenFunc = func() string { return "foo" }

	var ready *CreateResult
	svc.OnReady = func(r CreateResult) { ready = &r }

	if _, err := svc.CreateNamed(dir, nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ready == nil {
		t.Fatal("OnReady was not called")
	}
	if ready.HasSetup {
		t.Fatal("OnReady result should report HasSetup=false when no setup script exists")
	}
}

func TestCreateErrorsOnFailedSetupScript(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	scriptsDir := filepath.Join(dir, "scripts")
	os.MkdirAll(scriptsDir, 0o755)
	scriptPath := filepath.Join(scriptsDir, "workroom_setup")
	os.WriteFile(scriptPath, []byte("#!/usr/bin/env bash\necho \"I failed\"\nexit 1\n"), 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)",
		onRun: func(dir, name string, args []string) {
			if name == "jj" && len(args) > 1 && args[0] == "workspace" && args[1] == "add" {
				os.MkdirAll(args[2], 0o755)
			}
		},
	}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.NameGenFunc = func() string { return "foo" }

	err := svc.Create(dir)
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrSetup) {
		t.Fatalf("expected ErrSetup, got %v", err)
	}
}

func TestCreateRetriesOnNameCollisionWorkspace(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)\nworkroom/taken: qo a41890ed (empty) (no description set)\n",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, buf, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)

	callCount := 0
	svc.NameGenFunc = func() string {
		callCount++
		if callCount == 1 {
			return "taken"
		}
		return "fresh"
	}

	err := svc.Create(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "Workroom 'fresh' created successfully") {
		t.Fatalf("expected fresh name, got %q", output)
	}
}

func TestCreateRetriesOnNameCollisionDirectory(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	os.MkdirAll(filepath.Join(workroomsDir, "taken"), 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, buf, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)

	callCount := 0
	svc.NameGenFunc = func() string {
		callCount++
		if callCount == 1 {
			return "taken"
		}
		return "fresh"
	}

	err := svc.Create(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "Workroom 'fresh' created successfully") {
		t.Fatalf("expected fresh name, got %q", output)
	}
}

func TestCreateErrorsAfterTooManyNameCollisions(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	// Make the mock dynamically report every queried workspace as existing
	// by including the requested name in the output.
	mock := &mockExecutor{}
	mock.onRun = func(_, name string, args []string) {
		if name == "jj" && len(args) > 0 && args[0] == "workspace" && args[1] == "list" {
			mock.output = "default: mk 6ec05f05 (no description set)\nworkroom/taken: qo a41890ed (empty) (no description set)\n"
		}
	}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)

	// Always return the same name. The initial 5 attempts collide via VCS.
	// The fallback loop generates "taken-NN" names — pre-create the workrooms
	// directory so os.Stat finds it, causing directory collisions too.
	svc.NameGenFunc = func() string { return "taken" }

	// Pre-create directories for all possible suffixed names (taken-10 through taken-99)
	for i := 10; i <= 99; i++ {
		os.MkdirAll(filepath.Join(workroomsDir, fmt.Sprintf("taken-%d", i)), 0o755)
	}

	err := svc.Create(dir)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "failed to generate unique workroom name") {
		t.Fatalf("expected name generation error, got: %v", err)
	}

	// generateUniqueName lists workrooms exactly once for its whole 15-attempt retry loop
	// (not once per candidate name) — this is the worst case, all 15 attempts collide.
	listCalls := 0
	for _, call := range mock.calls {
		if len(call) >= 3 && call[0] == "jj" && call[1] == "workspace" && call[2] == "list" {
			listCalls++
		}
	}
	if listCalls != 1 {
		t.Fatalf("expected exactly 1 'jj workspace list' call across all retry attempts, got %d", listCalls)
	}
}

// --- Create: Editor prompt ---

func TestCreatePromptsToOpenEditorWhenSet(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	mock := &mockExecutor{output: "default: mk 6ec05f05 (no description set)"}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.NameGenFunc = func() string { return "foo" }

	t.Setenv("EDITOR", "code")

	confirmCalled := false
	svc.ConfirmFn = func(msg string) (bool, error) {
		if strings.Contains(msg, "Open workroom in code?") {
			confirmCalled = true
		}
		return false, nil
	}
	svc.OpenEditorFunc = func(editor, path string) error {
		t.Fatal("editor should not be opened when user declines")
		return nil
	}

	err := svc.Create(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !confirmCalled {
		t.Fatal("expected editor confirm prompt")
	}
}

func TestCreateDoesNotPromptEditorWhenUnset(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	mock := &mockExecutor{output: "default: mk 6ec05f05 (no description set)"}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.NameGenFunc = func() string { return "foo" }

	t.Setenv("EDITOR", "")

	editorPrompted := false
	svc.ConfirmFn = func(msg string) (bool, error) {
		if strings.Contains(msg, "Open workroom in") {
			editorPrompted = true
		}
		return false, nil
	}

	err := svc.Create(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if editorPrompted {
		t.Fatal("should not prompt for editor when EDITOR is unset")
	}
}

func TestCreateOpensEditorWhenConfirmed(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	mock := &mockExecutor{output: "default: mk 6ec05f05 (no description set)"}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.NameGenFunc = func() string { return "foo" }

	t.Setenv("EDITOR", "myeditor")

	var openedEditor, openedPath string
	svc.ConfirmFn = func(msg string) (bool, error) { return true, nil }
	svc.OpenEditorFunc = func(editor, path string) error {
		openedEditor = editor
		openedPath = path
		return nil
	}

	err := svc.Create(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if openedEditor != "myeditor" {
		t.Fatalf("expected editor 'myeditor', got %q", openedEditor)
	}
	if openedPath != filepath.Join(workroomsDir, "foo") {
		t.Fatalf("expected path %q, got %q", filepath.Join(workroomsDir, "foo"), openedPath)
	}
}

func TestCreateSkipsEditorPromptInPretendMode(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	mock := &mockExecutor{output: "default: mk 6ec05f05 (no description set)"}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.NameGenFunc = func() string { return "foo" }
	svc.Pretend = true

	t.Setenv("EDITOR", "code")

	editorPrompted := false
	svc.ConfirmFn = func(msg string) (bool, error) {
		if strings.Contains(msg, "Open workroom in") {
			editorPrompted = true
		}
		return false, nil
	}

	err := svc.Create(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if editorPrompted {
		t.Fatal("should not prompt for editor in pretend mode")
	}
}

// --- List ---

func TestListWorkroomsForCurrentProject(t *testing.T) {
	dir := t.TempDir()
	cfg := newTestConfig(t, filepath.Join(dir, "config.json"))
	fooDir := filepath.Join(dir, "foo")
	barDir := filepath.Join(dir, "bar")
	os.MkdirAll(fooDir, 0o755)
	os.MkdirAll(barDir, 0o755)

	cfg.AddWorkroom(dir, "foo", fooDir, "jj")
	cfg.AddWorkroom(dir, "bar", barDir, "jj")

	var buf bytes.Buffer
	svc := &Service{Config: cfg, Out: &buf}

	err := svc.List(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "foo") {
		t.Fatalf("expected foo in output, got %q", output)
	}
	if !strings.Contains(output, "bar") {
		t.Fatalf("expected bar in output, got %q", output)
	}
}

func TestListWarnsWhenDirNotFound(t *testing.T) {
	dir := t.TempDir()
	cfg := newTestConfig(t, filepath.Join(dir, "config.json"))
	cfg.AddWorkroom(dir, "foo", "/nonexistent", "jj")

	var buf bytes.Buffer
	svc := &Service{Config: cfg, Out: &buf}

	err := svc.List(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "directory not found") {
		t.Fatalf("expected warning, got %q", output)
	}
}

func TestListNoWarningWhenDirExists(t *testing.T) {
	dir := t.TempDir()
	wrDir := filepath.Join(dir, "myworkroom")
	os.MkdirAll(wrDir, 0o755)
	cfg := newTestConfig(t, filepath.Join(dir, "config.json"))
	cfg.AddWorkroom(dir, "foo", wrDir, "jj")

	var buf bytes.Buffer
	svc := &Service{Config: cfg, Out: &buf}

	err := svc.List(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if strings.Contains(output, "directory not found") {
		t.Fatalf("unexpected warning, got %q", output)
	}
}

func TestListAllGroupedByParent(t *testing.T) {
	dir := t.TempDir()
	cfg := newTestConfig(t, filepath.Join(dir, "config.json"))

	bazDir := filepath.Join(dir, "baz")
	quxDir := filepath.Join(dir, "qux")
	os.MkdirAll(bazDir, 0o755)
	os.MkdirAll(quxDir, 0o755)

	cfg.AddWorkroom("/other/project", "baz", bazDir, "git")
	cfg.AddWorkroom("/another/project", "qux", quxDir, "jj")

	var buf bytes.Buffer
	svc := &Service{Config: cfg, Out: &buf}

	// cwd is not a known project
	unknownDir := filepath.Join(dir, "unknown")
	os.MkdirAll(unknownDir, 0o755)
	err := svc.List(unknownDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "/other/project:") {
		t.Fatalf("expected /other/project:, got %q", output)
	}
	if !strings.Contains(output, "/another/project:") {
		t.Fatalf("expected /another/project:, got %q", output)
	}
}

func TestListNoWorkroomsAnywhere(t *testing.T) {
	dir := t.TempDir()
	cfg := newTestConfig(t, filepath.Join(dir, "config.json"))

	var buf bytes.Buffer
	svc := &Service{Config: cfg, Out: &buf}

	err := svc.List(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "No workrooms found.") {
		t.Fatalf("expected 'No workrooms found.', got %q", output)
	}
}

func TestListInsideWorkroom(t *testing.T) {
	dir := t.TempDir()
	wrDir := filepath.Join(dir, "myworkroom")
	os.MkdirAll(wrDir, 0o755)
	cfg := newTestConfig(t, filepath.Join(dir, "config.json"))
	cfg.AddWorkroom(dir, "myworkroom", wrDir, "jj")

	var buf bytes.Buffer
	svc := &Service{Config: cfg, Out: &buf}

	err := svc.List(wrDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "You are already in a workroom.") {
		t.Fatalf("expected in-workroom message, got %q", output)
	}
	if !strings.Contains(output, dir) {
		t.Fatalf("expected parent path, got %q", output)
	}
}

// --- Delete ---

func TestDeleteInvalidName(t *testing.T) {
	dir := t.TempDir()
	mock := &mockExecutor{}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)

	err := svc.Delete(dir, "fo.o", "")
	if !errors.Is(err, ErrInvalidName) {
		t.Fatalf("expected ErrInvalidName, got %v", err)
	}
}

func TestDeleteErrorsIfNotJJOrGit(t *testing.T) {
	dir := t.TempDir()

	svc := &Service{
		Config: newTestConfig(t, filepath.Join(dir, "config.json")),
		Out:    &bytes.Buffer{},
	}

	err := svc.Delete(dir, "foo", "")
	if !errors.Is(err, ErrUnsupportedVCS) {
		t.Fatalf("expected ErrUnsupportedVCS, got %v", err)
	}
}

func TestDeleteErrorsIfJJWorkspaceNotFound(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))

	err := svc.Delete(dir, "foo", "foo")
	if !errors.Is(err, ErrJJWorkspaceNotFound) {
		t.Fatalf("expected ErrJJWorkspaceNotFound, got %v", err)
	}
}

func TestDeleteErrorsIfGitWorktreeNotFound(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)

	mock := &mockExecutor{
		output: "worktree " + dir + "\nHEAD cbace1f\nbranch refs/heads/master\n",
	}
	git := &vcs.Git{Executor: mock}

	svc, _, _ := newTestService(t, git)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))

	err := svc.Delete(dir, "foo", "foo")
	if !errors.Is(err, ErrGitWorktreeNotFound) {
		t.Fatalf("expected ErrGitWorktreeNotFound, got %v", err)
	}
}

func TestDeleteErrorsIfInWorkroom(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, ".Workroom"), []byte{}, 0o644)

	svc := &Service{Out: &bytes.Buffer{}}
	err := svc.Delete(dir, "foo", "")
	if !errors.Is(err, ErrInWorkroom) {
		t.Fatalf("expected ErrInWorkroom, got %v", err)
	}
}

func TestDeleteSucceeds(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: mk 6ec05f05 (no description set)\n",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, buf, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.Config.AddWorkroom(dir, "foo", wrPath, "jj")

	err := svc.Delete(dir, "foo", "foo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "Workroom 'foo' deleted successfully.") {
		t.Fatalf("expected success message, got %q", output)
	}

	// JJ cleanup should remove directory
	if _, err := os.Stat(wrPath); !os.IsNotExist(err) {
		t.Fatal("expected directory to be removed")
	}
}

func TestDeleteUpdatesConfig(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: mk 6ec05f05 (no description set)\n",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.Config.AddWorkroom(dir, "foo", wrPath, "jj")

	err := svc.Delete(dir, "foo", "foo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	data, _ := svc.Config.Read()
	if _, ok := data[dir]; ok {
		t.Fatal("expected project to be removed from config")
	}
}

func TestDeleteConfirmSkipsPrompt(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: mk 6ec05f05 (no description set)\n",
	}
	jj := &vcs.JJ{Executor: mock}

	confirmCalled := false
	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.Config.AddWorkroom(dir, "foo", wrPath, "jj")
	svc.ConfirmFn = func(string) (bool, error) {
		confirmCalled = true
		return true, nil
	}

	err := svc.Delete(dir, "foo", "foo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if confirmCalled {
		t.Fatal("confirm should not be called when --confirm matches")
	}
}

func TestDeleteConfirmMismatchErrors(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: mk 6ec05f05 (no description set)\n",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)

	err := svc.Delete(dir, "foo", "wrong")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "--confirm value 'wrong' does not match workroom name 'foo'") {
		t.Fatalf("expected mismatch error, got %v", err)
	}
}

func TestDeleteRunsTeardownScript(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	scriptsDir := filepath.Join(dir, "scripts")
	os.MkdirAll(scriptsDir, 0o755)
	scriptPath := filepath.Join(scriptsDir, "workroom_teardown")
	os.WriteFile(scriptPath, []byte("#!/usr/bin/env bash\necho \"I teared down\"\nexit 0\n"), 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: mk 6ec05f05 (no description set)\n",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, buf, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.Config.AddWorkroom(dir, "foo", wrPath, "jj")

	err := svc.Delete(dir, "foo", "foo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	// Teardown output is rendered inside a titled log panel with a gutter border.
	if !strings.Contains(output, "╭─ Teardown ") {
		t.Fatalf("expected teardown log panel header, got %q", output)
	}
	if !strings.Contains(output, "│ I teared down") {
		t.Fatalf("expected gutter-prefixed teardown output, got %q", output)
	}
	if !strings.Contains(output, "Workroom 'foo' deleted successfully.") {
		t.Fatalf("expected success message, got %q", output)
	}
}

func TestDeleteErrorsOnFailedTeardownScript(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	scriptsDir := filepath.Join(dir, "scripts")
	os.MkdirAll(scriptsDir, 0o755)
	scriptPath := filepath.Join(scriptsDir, "workroom_teardown")
	os.WriteFile(scriptPath, []byte("#!/usr/bin/env bash\necho \"I failed to tear down\"\nexit 1\n"), 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: mk 6ec05f05 (no description set)\n",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.Config.AddWorkroom(dir, "foo", wrPath, "jj")

	err := svc.Delete(dir, "foo", "foo")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrTeardown) {
		t.Fatalf("expected ErrTeardown, got %v", err)
	}
}

// In --json mode a ScriptLogWriter is supplied (the NDJSON stderr stream). The
// teardown output must flow there live, and the returned error stays concise since
// the output has already been streamed rather than being folded into the envelope.
func TestDeleteTeardownFailureStreamsToScriptLogWriter(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	scriptsDir := filepath.Join(dir, "scripts")
	os.MkdirAll(scriptsDir, 0o755)
	scriptPath := filepath.Join(scriptsDir, "workroom_teardown")
	os.WriteFile(scriptPath, []byte("#!/usr/bin/env bash\necho \"boom diagnostic\"\nexit 1\n"), 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: mk 6ec05f05 (no description set)\n",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, _, _ := newTestService(t, jj)
	svc.Out = io.Discard // machine/JSON mode discards human output
	var logged bytes.Buffer
	svc.ScriptLogWriter = &logged // ...but script output streams here
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.Config.AddWorkroom(dir, "foo", wrPath, "jj")

	err := svc.Delete(dir, "foo", "foo")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrTeardown) {
		t.Fatalf("expected ErrTeardown, got %v", err)
	}
	if !strings.Contains(logged.String(), "boom diagnostic") {
		t.Fatalf("teardown output should stream to ScriptLogWriter, got %q", logged.String())
	}
	// Output already streamed, so the error must not duplicate it.
	if strings.Contains(err.Error(), "boom diagnostic") {
		t.Fatalf("error should stay concise when streaming, got %q", err.Error())
	}
}

func TestDeleteGitShowsBranchNote(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	mock := &mockExecutor{
		output: "worktree " + dir + "\nHEAD cbace1f\nbranch refs/heads/master\n\nworktree " + wrPath + "\nHEAD abc123\nbranch refs/heads/workroom/foo\n",
	}
	git := &vcs.Git{Executor: mock}

	svc, buf, _ := newTestService(t, git)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.Config.AddWorkroom(dir, "foo", wrPath, "git")

	err := svc.Delete(dir, "foo", "foo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "Git branch 'workroom/foo' was not deleted") {
		t.Fatalf("expected git branch note, got %q", output)
	}
}

// --- Interactive Delete ---

func TestInteractiveDeleteNoWorkrooms(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	cfg := newTestConfig(t, filepath.Join(dir, "config.json"))

	var buf bytes.Buffer
	svc := &Service{Config: cfg, Out: &buf}

	err := svc.InteractiveDelete(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "No workrooms found for this project.") {
		t.Fatalf("expected no workrooms message, got %q", output)
	}
}

func TestInteractiveDeleteSingle(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: mk 6ec05f05 (no description set)\n",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, buf, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.Config.AddWorkroom(dir, "foo", wrPath, "jj")

	svc.PromptFn = func(msg string, opts []string) ([]string, error) {
		return []string{"foo"}, nil
	}
	svc.ConfirmFn = func(string) (bool, error) { return true, nil }

	err := svc.InteractiveDelete(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "Workroom 'foo' deleted successfully.") {
		t.Fatalf("expected success message, got %q", output)
	}
}

func TestInteractiveDeleteMultiple(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	fooPath := filepath.Join(workroomsDir, "foo")
	barPath := filepath.Join(workroomsDir, "bar")
	os.MkdirAll(fooPath, 0o755)
	os.MkdirAll(barPath, 0o755)

	mock := &mockExecutor{
		output: "default: mk 6ec05f05 (no description set)\nworkroom/foo: mk 6ec05f05 (no description set)\nworkroom/bar: xz b12345 (no description set)\n",
	}
	jj := &vcs.JJ{Executor: mock}

	svc, buf, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.Config.AddWorkroom(dir, "foo", fooPath, "jj")
	svc.Config.AddWorkroom(dir, "bar", barPath, "jj")

	svc.PromptFn = func(msg string, opts []string) ([]string, error) {
		return []string{"foo", "bar"}, nil
	}
	svc.ConfirmFn = func(string) (bool, error) { return true, nil }

	err := svc.InteractiveDelete(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "Workroom 'foo' deleted successfully.") {
		t.Fatalf("expected foo success, got %q", output)
	}
	if !strings.Contains(output, "Workroom 'bar' deleted successfully.") {
		t.Fatalf("expected bar success, got %q", output)
	}
}

func TestInteractiveDeleteAbortsOnDecline(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	cfg := newTestConfig(t, filepath.Join(dir, "config.json"))
	cfg.SetWorkroomsDir(workroomsDir)
	cfg.AddWorkroom(dir, "foo", wrPath, "jj")

	var buf bytes.Buffer
	svc := &Service{
		Config: cfg,
		Out:    &buf,
		PromptFn: func(msg string, opts []string) ([]string, error) {
			return []string{"foo"}, nil
		},
		ConfirmFn: func(string) (bool, error) { return false, nil },
	}

	err := svc.InteractiveDelete(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "Aborting. No workrooms were deleted.") {
		t.Fatalf("expected abort message, got %q", output)
	}
	// Directory should still exist
	if _, err := os.Stat(wrPath); os.IsNotExist(err) {
		t.Fatal("expected directory to still exist")
	}
}

func TestInteractiveDeleteAbortsOnNoSelection(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")
	wrPath := filepath.Join(workroomsDir, "foo")
	os.MkdirAll(wrPath, 0o755)

	cfg := newTestConfig(t, filepath.Join(dir, "config.json"))
	cfg.SetWorkroomsDir(workroomsDir)
	cfg.AddWorkroom(dir, "foo", wrPath, "jj")

	var buf bytes.Buffer
	svc := &Service{
		Config: cfg,
		Out:    &buf,
		PromptFn: func(msg string, opts []string) ([]string, error) {
			return []string{}, nil
		},
	}

	err := svc.InteractiveDelete(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "Aborting. No workrooms were selected.") {
		t.Fatalf("expected no-selection message, got %q", output)
	}
}

func TestInteractiveDeleteErrorsIfInWorkroom(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, ".Workroom"), []byte{}, 0o644)

	svc := &Service{Out: &bytes.Buffer{}}
	err := svc.InteractiveDelete(dir)
	if !errors.Is(err, ErrInWorkroom) {
		t.Fatalf("expected ErrInWorkroom, got %v", err)
	}
}
