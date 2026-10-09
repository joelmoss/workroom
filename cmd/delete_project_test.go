package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/workroom"
)

// fakeVCS is a no-disk VCS double: it records the vcsNames passed to Delete and can
// be told to fail on a specific one, so the cascade loop can be exercised without
// shelling out to real git. Nothing on disk is touched.
type fakeVCS struct {
	deleteCalls []string
	failOn      string   // vcsName to fail on (e.g. "workroom/bravo"); "" never fails
	list        []string // names ListWorkrooms returns (Service.Delete's existence check)
	onDelete    func()   // runs after each Delete, to change config mid-cascade
}

func (f *fakeVCS) Type() vcs.Type                                   { return vcs.TypeGit }
func (f *fakeVCS) Label() string                                    { return "Git" }
func (f *fakeVCS) Create(_, _, _, _ string, _ bool) (string, error) { return "", nil }
func (f *fakeVCS) ListWorkrooms(_ string) ([]string, error)         { return f.list, nil }
func (f *fakeVCS) Delete(_, vcsName, _ string) (string, error) {
	f.deleteCalls = append(f.deleteCalls, vcsName)
	if f.onDelete != nil {
		f.onDelete()
	}
	if f.failOn != "" && vcsName == f.failOn {
		return "", errors.New("boom")
	}
	return "", nil
}

// newTestSvc builds a Service backed by a throwaway temp config and the given VCS
// double — never the real ~/.config/workroom/config.json. KeepEmptyProject mirrors
// --json mode so the cascade keeps the (now-empty) project until RemoveProject runs.
func newTestSvc(t *testing.T, v vcs.VCS) (*workroom.Service, *config.Config) {
	t.Helper()
	dir := t.TempDir()
	cfg, err := config.New(filepath.Join(dir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	return &workroom.Service{
		Config:           cfg,
		VCS:              v,
		Out:              &bytes.Buffer{},
		KeepEmptyProject: true,
	}, cfg
}

func TestDeleteProjectRequiresJSON(t *testing.T) {
	svc, _ := newTestSvc(t, &fakeVCS{})
	err := runDeleteProject(svc, false, "", false, false, []string{"/p"}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil || !bytes.Contains([]byte(err.Error()), []byte("only available in --json mode")) {
		t.Fatalf("expected --json-only error, got %v", err)
	}
}

func TestDeleteProjectRequiresPathArg(t *testing.T) {
	svc, _ := newTestSvc(t, &fakeVCS{})
	err := runDeleteProject(svc, true, "", false, false, []string{}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil {
		t.Fatal("expected error when no path argument is given")
	}
}

func TestDeleteProjectConfirmMismatch(t *testing.T) {
	svc, cfg := newTestSvc(t, &fakeVCS{})
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)
	if err := cfg.AddProject(canon, "git"); err != nil {
		t.Fatal(err)
	}

	err := runDeleteProject(svc, true, "wrong-path", false, false, []string{proj}, &bytes.Buffer{}, &bytes.Buffer{})
	if !errors.Is(err, errs.ErrConfirmMismatch) {
		t.Fatalf("expected ErrConfirmMismatch, got %v", err)
	}
	// The project must still be registered after a rejected confirm.
	data, _ := cfg.Read()
	if _, ok := data[canon]; !ok {
		t.Fatal("project removed despite confirm mismatch")
	}
}

func TestDeleteProjectConfigOnly(t *testing.T) {
	fake := &fakeVCS{}
	svc, cfg := newTestSvc(t, fake)
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)
	if err := cfg.AddWorkroom(canon, "alpha", "/wr/alpha", "git"); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	// confirm matches the as-given path (gate accepts canon OR path).
	if err := runDeleteProject(svc, true, proj, false, false, []string{proj}, &stdout, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}

	// No VCS teardown without --with-workrooms.
	if len(fake.deleteCalls) != 0 {
		t.Fatalf("config-only delete touched VCS: %v", fake.deleteCalls)
	}
	// Project entry gone.
	data, _ := cfg.Read()
	if _, ok := data[canon]; ok {
		t.Fatal("project entry not removed")
	}
	// Envelope shape.
	var env map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("bad envelope %q: %v", stdout.String(), err)
	}
	if env["ok"] != true || env["command"] != "delete-project" || env["path"] != canon || env["with_workrooms"] != false {
		t.Fatalf("unexpected envelope: %v", env)
	}
}

func TestDeleteProjectCascade(t *testing.T) {
	fake := &fakeVCS{list: []string{"alpha", "bravo"}}
	svc, cfg := newTestSvc(t, fake)
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)
	for _, n := range []string{"bravo", "alpha"} { // insertion order; cascade should sort
		if err := cfg.AddWorkroom(canon, n, "/wr/"+n, "git"); err != nil {
			t.Fatal(err)
		}
	}

	var stdout, logs bytes.Buffer
	if err := runDeleteProject(svc, true, canon, true, false, []string{proj}, &stdout, &logs); err != nil {
		t.Fatal(err)
	}

	// Both workrooms torn down, in sorted order, via "workroom/<name>".
	if len(fake.deleteCalls) != 2 || fake.deleteCalls[0] != "workroom/alpha" || fake.deleteCalls[1] != "workroom/bravo" {
		t.Fatalf("expected [workroom/alpha workroom/bravo], got %v", fake.deleteCalls)
	}
	// Project removed.
	data, _ := cfg.Read()
	if _, ok := data[canon]; ok {
		t.Fatal("project entry not removed after cascade")
	}
	var env map[string]any
	_ = json.Unmarshal(stdout.Bytes(), &env)
	if env["with_workrooms"] != true {
		t.Fatalf("expected with_workrooms:true, got %v", env)
	}
}

func TestDeleteProjectCascadePartialFailureKeepsProject(t *testing.T) {
	fake := &fakeVCS{failOn: "workroom/bravo", list: []string{"alpha", "bravo"}}
	svc, cfg := newTestSvc(t, fake)
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)
	for _, n := range []string{"alpha", "bravo"} {
		if err := cfg.AddWorkroom(canon, n, "/wr/"+n, "git"); err != nil {
			t.Fatal(err)
		}
	}

	err := runDeleteProject(svc, true, canon, true, false, []string{proj}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil {
		t.Fatal("expected cascade to surface the teardown failure")
	}
	// alpha was torn down before bravo failed; the loop stops at bravo.
	if len(fake.deleteCalls) != 2 {
		t.Fatalf("expected 2 delete attempts (alpha ok, bravo fail), got %v", fake.deleteCalls)
	}
	// Project must remain in config so the user can retry.
	data, _ := cfg.Read()
	if _, ok := data[canon]; !ok {
		t.Fatal("project removed despite a cascade failure (should be retryable)")
	}
}

// TestDeleteProjectFromDisk verifies the --from-disk happy path: teardowns are run
// (none exist in this test), config is cleaned up, and the envelope contains
// from_disk:true and trash_paths = [root, ...sorted workroom paths].
func TestDeleteProjectFromDisk(t *testing.T) {
	fake := &fakeVCS{}
	svc, cfg := newTestSvc(t, fake)
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)

	wrBase := t.TempDir()
	wrAlpha := filepath.Join(wrBase, "alpha")
	wrBravo := filepath.Join(wrBase, "bravo")
	if err := os.MkdirAll(wrAlpha, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(wrBravo, 0o755); err != nil {
		t.Fatal(err)
	}

	if err := cfg.AddWorkroom(canon, "alpha", wrAlpha, "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddWorkroom(canon, "bravo", wrBravo, "git"); err != nil {
		t.Fatal(err)
	}

	var stdout, logs bytes.Buffer
	if err := runDeleteProject(svc, true, canon, false, true, []string{proj}, &stdout, &logs); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// No VCS teardown — from-disk only runs teardown scripts, not VCS delete.
	if len(fake.deleteCalls) != 0 {
		t.Fatalf("from-disk delete should not call VCS.Delete, got: %v", fake.deleteCalls)
	}

	// Project entry removed from config.
	data, _ := cfg.Read()
	if _, ok := data[canon]; ok {
		t.Fatal("project entry not removed from config after from-disk delete")
	}

	// Workroom dirs still exist on disk (CLI must NOT delete them).
	if _, err := os.Stat(wrAlpha); err != nil {
		t.Fatalf("workroom dir %s should still exist on disk: %v", wrAlpha, err)
	}
	if _, err := os.Stat(wrBravo); err != nil {
		t.Fatalf("workroom dir %s should still exist on disk: %v", wrBravo, err)
	}

	// Envelope: ok, from_disk:true, trash_paths = [canon, sorted workroom paths].
	var env map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("bad envelope %q: %v", stdout.String(), err)
	}
	if env["ok"] != true {
		t.Fatalf("expected ok:true, got %v", env["ok"])
	}
	if env["from_disk"] != true {
		t.Fatalf("expected from_disk:true, got %v", env["from_disk"])
	}

	rawPaths, ok := env["trash_paths"].([]any)
	if !ok {
		t.Fatalf("expected trash_paths array, got %T: %v", env["trash_paths"], env["trash_paths"])
	}
	trashPaths := make([]string, len(rawPaths))
	for i, v := range rawPaths {
		s, ok := v.(string)
		if !ok {
			t.Fatalf("trash_paths[%d] is not a string: %v", i, v)
		}
		trashPaths[i] = s
	}

	// First element must be project root.
	if trashPaths[0] != canon {
		t.Fatalf("expected trash_paths[0] = %q (project root), got %q", canon, trashPaths[0])
	}
	// Remaining elements must be the workroom paths sorted ascending.
	expectedWR := []string{wrAlpha, wrBravo}
	sort.Strings(expectedWR)
	gotWR := trashPaths[1:]
	if len(gotWR) != len(expectedWR) {
		t.Fatalf("expected %d workroom paths, got %d: %v", len(expectedWR), len(gotWR), gotWR)
	}
	for i, want := range expectedWR {
		if gotWR[i] != want {
			t.Fatalf("trash_paths[%d]: want %q, got %q", i+1, want, gotWR[i])
		}
	}
}

// TestDeleteProjectFromDiskTeardownFailureKeepsConfig verifies that a failing teardown
// script aborts the operation and leaves the project in config (retryable).
func TestDeleteProjectFromDiskTeardownFailureKeepsConfig(t *testing.T) {
	fake := &fakeVCS{}
	svc, cfg := newTestSvc(t, fake)
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)

	// Write a failing teardown script into the project directory.
	scriptsDir := filepath.Join(proj, "scripts")
	if err := os.MkdirAll(scriptsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	teardownScript := filepath.Join(scriptsDir, "workroom_teardown")
	if err := os.WriteFile(teardownScript, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	// We need a workroom whose path resolves under the configured WorkroomsDir so
	// RunTeardown can locate it. Use a real temp dir as the workroom path.
	wrPath := t.TempDir()
	if err := cfg.AddWorkroom(canon, "alpha", wrPath, "git"); err != nil {
		t.Fatal(err)
	}

	// Override WorkroomsDir so workroomPath("alpha") returns wrPath.
	// WorkroomsDir is derived from config; inject via cfg.SetWorkroomsDir.
	// Instead, we set the workrooms_dir in config to the parent of wrPath so
	// filepath.Join(workroomsDir, "alpha") == wrPath.
	wrParent := filepath.Dir(wrPath)
	wrName := filepath.Base(wrPath)
	// We need the workroom name to match the dir name; use the base of the temp path.
	// Re-register with the real name.
	if err := cfg.RemoveProject(canon); err != nil {
		t.Fatal(err)
	}
	if err := cfg.SetWorkroomsDir(wrParent); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddWorkroom(canon, wrName, filepath.Join(wrParent, wrName), "git"); err != nil {
		t.Fatal(err)
	}

	err := runDeleteProject(svc, true, canon, false, true, []string{proj}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil {
		t.Fatal("expected error from failing teardown script")
	}

	// Project must remain in config.
	data, _ := cfg.Read()
	if _, ok := data[canon]; !ok {
		t.Fatal("project was removed from config despite teardown failure — should be retryable")
	}
}

// TestDeleteProjectFromDiskGuardRefuses verifies that from-disk refuses when the
// project is an ancestor of another registered project, returning ErrUnsafeDeletePath.
func TestDeleteProjectFromDiskGuardRefuses(t *testing.T) {
	fake := &fakeVCS{}
	svc, cfg := newTestSvc(t, fake)

	parent := t.TempDir()
	child := filepath.Join(parent, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatal(err)
	}

	parentCanon, _ := config.CanonicalPath(parent)
	childCanon, _ := config.CanonicalPath(child)

	if err := cfg.AddProject(parentCanon, "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(childCanon, "git"); err != nil {
		t.Fatal(err)
	}

	err := runDeleteProject(svc, true, parentCanon, false, true, []string{parent}, &bytes.Buffer{}, &bytes.Buffer{})
	if !errors.Is(err, errs.ErrUnsafeDeletePath) {
		t.Fatalf("expected ErrUnsafeDeletePath, got %v", err)
	}

	// Nothing removed from config.
	data, _ := cfg.Read()
	if _, ok := data[parentCanon]; !ok {
		t.Fatal("parent project removed from config despite guard refusal")
	}
	if _, ok := data[childCanon]; !ok {
		t.Fatal("child project removed from config despite guard refusal")
	}
}

// TestUnsafeProjectDeletePath is a table-driven test of the guard function itself.
func TestUnsafeProjectDeletePath(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	homeCanon, _ := config.CanonicalPath(home)

	// A standalone leaf temp dir that will be registered as the only project.
	leaf := t.TempDir()
	leafCanon, _ := config.CanonicalPath(leaf)

	// An ancestor dir (parent of leaf).
	ancestor := filepath.Dir(leaf)

	// Another project that will be registered.
	other := t.TempDir()
	otherCanon, _ := config.CanonicalPath(other)

	// Build a config with the leaf and other registered.
	cfgDir := t.TempDir()
	cfg, err := config.New(filepath.Join(cfgDir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(leafCanon, "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(otherCanon, "git"); err != nil {
		t.Fatal(err)
	}

	workroomsDir, _ := cfg.WorkroomsDir()
	workroomsDirCanon, _ := config.CanonicalPath(workroomsDir)
	workroomsDirParent := filepath.Dir(workroomsDirCanon)

	tests := []struct {
		name   string
		canon  string
		refuse bool
	}{
		{"root slash", "/", true},
		{"home dir", homeCanon, true},
		{"empty string", "", true},
		{"relative path", "relative/path", true},
		{"equals workrooms_dir", workroomsDirCanon, true},
		{"ancestor of workrooms_dir", workroomsDirParent, true},
		{"ancestor of another project", ancestor, true},
		{"standalone leaf project", leafCanon, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := unsafeProjectDeletePath(tt.canon, cfg)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.refuse {
				t.Fatalf("unsafeProjectDeletePath(%q) = %v, want %v", tt.canon, got, tt.refuse)
			}
		})
	}
}

// TestUnsafeProjectDeletePathIgnoresScalarSettings: run from inside the project, a global
// base_branch key resolved as a path lies under it and wrongly refused the delete.
func TestUnsafeProjectDeletePathIgnoresScalarSettings(t *testing.T) {
	leaf, _ := config.CanonicalPath(t.TempDir())
	cfg, err := config.New(filepath.Join(t.TempDir(), "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(leaf, "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.SetGlobalBaseBranch("develop"); err != nil {
		t.Fatal(err)
	}
	t.Chdir(leaf)
	got, err := unsafeProjectDeletePath(leaf, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if got {
		t.Fatal("a global base_branch refused deleting the project it was run from")
	}
}

// TestDeleteProjectRefusesAProjectWithABase: a project's own host descriptor records its base
// machine (#252), so every mode refuses a project carrying one even with no remote workroom,
// rather than dropping the only record of a running box.
func TestDeleteProjectRefusesAProjectWithABase(t *testing.T) {
	for _, mode := range []struct {
		name             string
		withWR, fromDisk bool
	}{{"config-only", false, false}, {"with-workrooms", true, false}, {"from-disk", false, true}} {
		t.Run(mode.name, func(t *testing.T) {
			fake := &fakeVCS{list: []string{"alpha"}}
			svc, cfg := newTestSvc(t, fake)
			proj := t.TempDir()
			canon, _ := config.CanonicalPath(proj)
			cfg.AddWorkroom(canon, "alpha", "/wr/alpha", "git")
			if err := cfg.SetHost(canon, "", map[string]any{"base": map[string]any{"host": "h1"}}); err != nil {
				t.Fatal(err)
			}
			before, _ := os.ReadFile(cfg.Path())

			err := runDeleteProject(svc, true, canon, mode.withWR, mode.fromDisk, []string{proj}, &bytes.Buffer{}, &bytes.Buffer{})
			if !errors.Is(err, errs.ErrRemoteWorkroom) {
				t.Fatalf("expected ErrRemoteWorkroom, got %v", err)
			}
			if len(fake.deleteCalls) != 0 {
				t.Fatalf("workrooms were torn down: %v", fake.deleteCalls)
			}
			if after, _ := os.ReadFile(cfg.Path()); !bytes.Equal(before, after) {
				t.Fatalf("config changed:\n%s", after)
			}
		})
	}
}

// TestDeleteProjectStopsWhenABaseIsRecordedMidCascade: a host descriptor written while
// --with-workrooms tears down (a base recorded) stops the cascade before the next workroom, not
// only at the final config write, so no more local workrooms go than had already gone.
func TestDeleteProjectStopsWhenABaseIsRecordedMidCascade(t *testing.T) {
	fake := &fakeVCS{list: []string{"alpha", "bravo", "charlie"}}
	svc, cfg := newTestSvc(t, fake)
	proj := t.TempDir()
	canon, _ := config.CanonicalPath(proj)
	for _, name := range []string{"alpha", "bravo", "charlie"} {
		cfg.AddWorkroom(canon, name, filepath.Join(t.TempDir(), name), "git")
	}
	fake.onDelete = func() {
		fake.onDelete = nil
		if err := cfg.SetHost(canon, "", map[string]any{"base": map[string]any{"host": "h1"}}); err != nil {
			t.Fatal(err)
		}
	}

	err := runDeleteProject(svc, true, canon, true, false, []string{proj}, &bytes.Buffer{}, &bytes.Buffer{})
	if !errors.Is(err, errs.ErrRemoteWorkroom) {
		t.Fatalf("expected ErrRemoteWorkroom, got %v", err)
	}
	if len(fake.deleteCalls) != 1 {
		t.Fatalf("the cascade went on after the base was recorded: %v", fake.deleteCalls)
	}
}

// TestDeleteProjectRefusesRemoteWorkrooms: every mode refuses a project with remote workrooms,
// naming them, before tearing anything down or touching config.
func TestDeleteProjectRefusesRemoteWorkrooms(t *testing.T) {
	for _, mode := range []struct {
		name             string
		withWR, fromDisk bool
	}{{"config-only", false, false}, {"with-workrooms", true, false}, {"from-disk", false, true}} {
		t.Run(mode.name, func(t *testing.T) {
			fake := &fakeVCS{list: []string{"alpha"}}
			svc, cfg := newTestSvc(t, fake)
			proj := t.TempDir()
			canon, _ := config.CanonicalPath(proj)
			cfg.AddWorkroom(canon, "alpha", "/wr/alpha", "git") // local, sorts first
			cfg.AddWorkroom(canon, "zulu", "/home/wr/zulu", "git")
			cfg.AddWorkroom(canon, "bravo", "/home/wr/bravo", "git")
			data, _ := cfg.Read()
			wrs := data[canon].(map[string]any)["workrooms"].(map[string]any)
			wrs["zulu"].(map[string]any)["host"] = map[string]any{"id": "h1"}
			wrs["bravo"].(map[string]any)["host"] = map[string]any{"id": "h2", "state": "destroyed"}
			cfg.Write(data)
			before, _ := os.ReadFile(cfg.Path())

			var stdout bytes.Buffer
			err := runDeleteProject(svc, true, canon, mode.withWR, mode.fromDisk, []string{proj}, &stdout, &bytes.Buffer{})
			if !errors.Is(err, errs.ErrRemoteWorkroom) {
				t.Fatalf("expected ErrRemoteWorkroom, got %v", err)
			}
			if !strings.Contains(err.Error(), "bravo, zulu") {
				t.Fatalf("the error must name the remote workrooms, sorted: %q", err)
			}
			if len(fake.deleteCalls) != 0 {
				t.Fatalf("workrooms were torn down: %v", fake.deleteCalls)
			}
			if after, _ := os.ReadFile(cfg.Path()); !bytes.Equal(before, after) {
				t.Fatalf("config changed:\n%s", after)
			}
			if stdout.Len() != 0 {
				t.Fatalf("a success envelope was written: %s", stdout.String())
			}
		})
	}
}
