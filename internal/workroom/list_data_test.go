package workroom

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs"
)

func TestListDataSortedIncludesEmptyAndMakesNoVCSCallsForNone(t *testing.T) {
	mock := &mockExecutor{}
	svc, _, cfg := newTestService(t, &vcs.JJ{Executor: mock})

	if err := cfg.AddProject("/b", "jj"); err != nil { // empty project
		t.Fatal(err)
	}
	if err := cfg.AddWorkroom("/a", "zeta", "/wr/zeta", "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddWorkroom("/a", "alpha", "/wr/alpha", "git"); err != nil {
		t.Fatal(err)
	}

	res, err := svc.ListData(WarningsNone)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Projects) != 2 {
		t.Fatalf("expected 2 projects (incl. empty), got %d", len(res.Projects))
	}
	if res.Projects[0].Path != "/a" || res.Projects[1].Path != "/b" {
		t.Fatalf("projects not sorted by path: %v", res.Projects)
	}
	if got := res.Projects[0].Workrooms[0].Name; got != "alpha" {
		t.Fatalf("workrooms not sorted by name, first = %q", got)
	}
	if got := res.Projects[0].Workrooms[0].VCSName; got != "workroom/alpha" {
		t.Fatalf("vcs_name = %q, want workroom/alpha", got)
	}
	if len(res.Projects[1].Workrooms) != 0 {
		t.Fatalf("empty project should have 0 workrooms, got %d", len(res.Projects[1].Workrooms))
	}
	if len(mock.calls) != 0 {
		t.Fatalf("warnings=none must make no VCS calls, got %d: %v", len(mock.calls), mock.calls)
	}
	if res.ConfigPath != cfg.Path() {
		t.Fatalf("config_path = %q, want %q", res.ConfigPath, cfg.Path())
	}
}

func TestListDataFastFlagsMissingDirectory(t *testing.T) {
	mock := &mockExecutor{}
	svc, _, cfg := newTestService(t, &vcs.JJ{Executor: mock})

	dir := t.TempDir()
	existing := filepath.Join(dir, "exists")
	if err := os.MkdirAll(existing, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg.AddWorkroom("/a", "here", existing, "jj")
	cfg.AddWorkroom("/a", "gone", filepath.Join(dir, "missing"), "jj")

	res, err := svc.ListData(WarningsFast)
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string][]Warning{}
	for _, w := range res.Projects[0].Workrooms {
		byName[w.Name] = w.Warnings
	}
	if len(byName["here"]) != 0 {
		t.Fatalf("existing dir should have no warnings, got %v", byName["here"])
	}
	if len(byName["gone"]) != 1 || byName["gone"][0].Kind != "DirectoryMissing" {
		t.Fatalf("missing dir should have one DirectoryMissing warning, got %v", byName["gone"])
	}
	if len(mock.calls) != 0 {
		t.Fatalf("warnings=fast must make no VCS calls, got %d", len(mock.calls))
	}
}

func TestListDataFlagsEmptyPathAsMissingDirectory(t *testing.T) {
	mock := &mockExecutor{}
	svc, _, cfg := newTestService(t, &vcs.JJ{Executor: mock})

	cfg.AddWorkroom("/a", "ghost", "", "jj")

	res, err := svc.ListData(WarningsFast)
	if err != nil {
		t.Fatal(err)
	}
	warnings := res.Projects[0].Workrooms[0].Warnings
	if len(warnings) != 1 || warnings[0].Kind != "DirectoryMissing" {
		t.Fatalf("workroom with empty/missing path should warn DirectoryMissing, got %v", warnings)
	}
}

// TestListAndListDataAgreeOnEmptyPath pins the fix for a real divergence: `workroom list`
// (List, via os.Stat's unconditional call) used to warn on an empty/missing "path" config
// entry while `workroom list --json` (ListData, guarded on wrPath != "") silently didn't. Both
// now share projectInfo, so they must agree.
func TestListAndListDataAgreeOnEmptyPath(t *testing.T) {
	mock := &mockExecutor{}
	svc, buf, cfg := newTestService(t, &vcs.JJ{Executor: mock})

	cfg.AddWorkroom("/a", "ghost", "", "jj")

	if err := svc.List("/a"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), "directory not found") {
		t.Fatalf("expected 'directory not found' in human list output, got %q", buf.String())
	}

	res, err := svc.ListData(WarningsFast)
	if err != nil {
		t.Fatal(err)
	}
	warnings := res.Projects[0].Workrooms[0].Warnings
	if len(warnings) != 1 || warnings[0].Kind != "DirectoryMissing" {
		t.Fatalf("workroom list --json disagreed with workroom list: got %v", warnings)
	}
}

// TestListAndListDataAgreeOnMalformedWorkroomEntry pins a second, previously-silent divergence
// this consolidation resolves: a workroom entry whose stored value isn't an object at all (e.g.
// hand-edited config with `"ghost": "oops"` instead of `"ghost": {"path": ...}`). The old human
// List skipped it outright; the old ListData's looser `info, _ := wrMap[name].(map[string]any)`
// let it through as a bogus zero-value entry (path "", no warning, since its os.Stat guard was
// `if wrPath != ""`). Both now go through config.decodeProject, which skips it the same way the
// human path always did — deliberately, not by accident, and now proven on both outputs.
func TestListAndListDataAgreeOnMalformedWorkroomEntry(t *testing.T) {
	mock := &mockExecutor{}
	svc, buf, cfg := newTestService(t, &vcs.JJ{Executor: mock})

	if err := cfg.Write(map[string]any{
		"/a": map[string]any{"vcs": "jj", "workrooms": map[string]any{"ghost": "oops"}},
	}); err != nil {
		t.Fatal(err)
	}

	if err := svc.List("/a"); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(buf.String(), "ghost") {
		t.Fatalf("expected malformed entry to be skipped from human list, got %q", buf.String())
	}

	res, err := svc.ListData(WarningsFull)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Projects[0].Workrooms) != 0 {
		t.Fatalf("expected malformed entry to be skipped from --json list, got %v", res.Projects[0].Workrooms)
	}
}

func TestListDataFullListsVCSOncePerProject(t *testing.T) {
	// jj workspace list output: foo present, bar absent.
	mock := &mockExecutor{output: "default: mk 0 (no description)\nworkroom/foo: mk 1 (no description)\n"}
	jj := &vcs.JJ{Executor: mock}
	svc, _, cfg := newTestService(t, jj)
	svc.VCSForTypeFunc = func(vcs.Type) (vcs.VCS, error) { return jj, nil }

	cfg.AddWorkroom("/a", "foo", "/wr/foo", "jj")
	cfg.AddWorkroom("/a", "bar", "/wr/bar", "jj")

	res, err := svc.ListData(WarningsFull)
	if err != nil {
		t.Fatal(err)
	}
	// Exactly one VCS list call for the single project (not one per workroom).
	if len(mock.calls) != 1 {
		t.Fatalf("expected 1 VCS call (once per project), got %d: %v", len(mock.calls), mock.calls)
	}

	warn := map[string]bool{}
	for _, w := range res.Projects[0].Workrooms {
		for _, x := range w.Warnings {
			if x.Kind == "VCSWorkroomMissing" {
				warn[w.Name] = true
			}
		}
	}
	if warn["foo"] {
		t.Fatal("foo is present in the VCS listing; should not be flagged missing")
	}
	if !warn["bar"] {
		t.Fatal("bar is absent from the VCS listing; should be flagged VCSWorkroomMissing")
	}
}

func TestCreateNamedReturnsResult(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	workroomsDir := filepath.Join(dir, "workrooms")

	mock := &mockExecutor{output: "default: mk 0 (no description)\n"} // no workroom/* exists yet
	jj := &vcs.JJ{Executor: mock}
	svc, _, _ := newTestService(t, jj)
	svc.Config = newTestConfig(t, filepath.Join(dir, "config.json"))
	svc.Config.SetWorkroomsDir(workroomsDir)
	svc.NameGenFunc = func() string { return "fixed-name" }

	res, err := svc.CreateNamed(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if res.Name != "fixed-name" {
		t.Fatalf("name = %q", res.Name)
	}
	if res.VCS != "jj" {
		t.Fatalf("vcs = %q", res.VCS)
	}
	if res.Project != dir {
		t.Fatalf("project = %q, want %q", res.Project, dir)
	}
	if want := filepath.Join(workroomsDir, "fixed-name"); res.Path != want {
		t.Fatalf("path = %q, want %q", res.Path, want)
	}
}
