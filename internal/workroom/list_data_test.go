package workroom

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/vcs/vcstest"
)

func TestListDataSortedIncludesEmptyAndMakesNoVCSCallsForNone(t *testing.T) {
	mock := &mockExecutor{}
	svc, _, cfg := newTestService(t, &vcs.Git{Executor: mock})

	if err := cfg.AddProject("/b", "git"); err != nil { // empty project
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
	svc, _, cfg := newTestService(t, &vcs.Git{Executor: mock})

	dir := t.TempDir()
	existing := filepath.Join(dir, "exists")
	if err := os.MkdirAll(existing, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg.AddWorkroom("/a", "here", existing, "git")
	cfg.AddWorkroom("/a", "gone", filepath.Join(dir, "missing"), "git")

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
	svc, _, cfg := newTestService(t, &vcs.Git{Executor: mock})

	cfg.AddWorkroom("/a", "ghost", "", "git")

	res, err := svc.ListData(WarningsFast)
	if err != nil {
		t.Fatal(err)
	}
	warnings := res.Projects[0].Workrooms[0].Warnings
	if len(warnings) != 1 || warnings[0].Kind != "DirectoryMissing" {
		t.Fatalf("workroom with empty/missing path should warn DirectoryMissing, got %v", warnings)
	}
}

// listingText flattens a Listing's projects, workroom names and warning messages, for tests that
// check what the human list shows.
func listingText(l Listing) string {
	var b strings.Builder
	for _, project := range l.Projects {
		p := project()
		b.WriteString(p.Path + ":\n")
		for _, w := range p.Workrooms {
			b.WriteString(w.Name)
			for _, warning := range w.Warnings {
				b.WriteString(" " + warning.Message)
			}
			b.WriteString("\n")
		}
	}
	return b.String()
}

// TestListAndListDataAgreeOnEmptyPath pins the fix for a real divergence: `workroom list`
// (List, via os.Stat's unconditional call) used to warn on an empty/missing "path" config
// entry while `workroom list --json` (ListData, guarded on wrPath != "") silently didn't. Both
// now share projectInfo, so they must agree.
func TestListAndListDataAgreeOnEmptyPath(t *testing.T) {
	mock := &mockExecutor{}
	svc, _, cfg := newTestService(t, &vcs.Git{Executor: mock})

	cfg.AddWorkroom("/a", "ghost", "", "git")

	l, err := svc.Listing("/a")
	if err != nil {
		t.Fatal(err)
	}
	if out := listingText(l); !strings.Contains(out, "directory not found") {
		t.Fatalf("expected 'directory not found' in the human listing, got %q", out)
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
	svc, _, cfg := newTestService(t, &vcs.Git{Executor: mock})

	if err := cfg.Write(map[string]any{
		"/a": map[string]any{"vcs": "git", "workrooms": map[string]any{"ghost": "oops"}},
	}); err != nil {
		t.Fatal(err)
	}

	l, err := svc.Listing("/a")
	if err != nil {
		t.Fatal(err)
	}
	if out := listingText(l); strings.Contains(out, "ghost") {
		t.Fatalf("expected malformed entry to be skipped from human list, got %q", out)
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
	// git worktree list output: foo present, bar absent.
	mock := &mockExecutor{output: gitWorktrees("/a", "/wr/foo")}
	git := &vcs.Git{Executor: mock}
	svc, _, cfg := newTestService(t, git)
	svc.VCSForTypeFunc = func(vcs.Type) (vcs.VCS, error) { return git, nil }

	cfg.AddWorkroom("/a", "foo", "/wr/foo", "git")
	cfg.AddWorkroom("/a", "bar", "/wr/bar", "git")

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
	vcstest.MakeGitDir(t, dir)
	workroomsDir := filepath.Join(dir, "workrooms")

	mock := &mockExecutor{output: gitWorktrees(dir)}
	git := &vcs.Git{Executor: mock}
	svc, _, _ := newTestService(t, git)
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
	if res.VCS != "git" {
		t.Fatalf("vcs = %q", res.VCS)
	}
	if res.Project != dir {
		t.Fatalf("project = %q, want %q", res.Project, dir)
	}
	if want := filepath.Join(workroomsDir, "fixed-name"); res.Path != want {
		t.Fatalf("path = %q, want %q", res.Path, want)
	}
}

// remoteConfig writes a project with one local workroom whose directory and workspace are both
// gone, one live remote workroom and one whose host was destroyed. The remote paths do not exist
// here and neither is in the VCS listing, so each would warn if it were treated as local.
func remoteConfig(t *testing.T, svc *Service, g *vcs.Git) {
	t.Helper()
	svc.VCSForTypeFunc = func(vcs.Type) (vcs.VCS, error) { return g, nil }
	if err := svc.Config.Write(map[string]any{
		"/a": map[string]any{
			"vcs":  "git",
			"host": map[string]any{"provider": "boxd"},
			"workrooms": map[string]any{
				"local":  map[string]any{"path": "/wr/local"},
				"remote": map[string]any{"path": "/home/wr/remote", "host": map[string]any{"id": "h1"}},
				"gone":   map[string]any{"path": "/home/wr/gone", "host": map[string]any{"id": "h2", "state": "destroyed"}},
			},
		},
	}); err != nil {
		t.Fatal(err)
	}
}

func TestListDataGatesLocalWarningsOnRemoteWorkrooms(t *testing.T) {
	git := &vcs.Git{Executor: &mockExecutor{output: gitWorktrees("/a")}}
	svc, _, _ := newTestService(t, git)
	remoteConfig(t, svc, git)

	for _, level := range []WarningsLevel{WarningsNone, WarningsFast, WarningsFull} {
		res, err := svc.ListData(level)
		if err != nil {
			t.Fatal(err)
		}
		kinds := map[string][]string{}
		for _, w := range res.Projects[0].Workrooms {
			kinds[w.Name] = []string{}
			for _, x := range w.Warnings {
				kinds[w.Name] = append(kinds[w.Name], x.Kind)
			}
		}
		if got := kinds["remote"]; len(got) != 0 {
			t.Fatalf("%s: a live remote workroom must not warn, got %v", level, got)
		}
		if got := kinds["gone"]; len(got) != 1 || got[0] != "HostDestroyed" {
			t.Fatalf("%s: a destroyed host must warn HostDestroyed alone, got %v", level, got)
		}
		// The negative control: the same checks still fire for the local workroom.
		want := map[WarningsLevel]int{WarningsNone: 0, WarningsFast: 1, WarningsFull: 2}[level]
		if got := kinds["local"]; len(got) != want {
			t.Fatalf("%s: the local workroom should carry %d warnings, got %v", level, want, got)
		}
	}
}

func TestListDataReportsHostDescriptors(t *testing.T) {
	git := &vcs.Git{Executor: &mockExecutor{}}
	svc, _, _ := newTestService(t, git)
	remoteConfig(t, svc, git)

	res, err := svc.ListData(WarningsNone)
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(res.Projects[0])
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Host      map[string]any `json:"host"`
		Workrooms []map[string]any
	}
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got.Host["provider"] != "boxd" {
		t.Fatalf("project host = %v, want the stored descriptor", got.Host)
	}
	hosts := map[string]any{}
	for _, w := range got.Workrooms {
		host, present := w["host"]
		if w["name"] == "local" && present {
			t.Fatalf("a local workroom must carry no host key, got %v", host)
		}
		hosts[w["name"].(string)] = host
	}
	if h, _ := hosts["remote"].(map[string]any); h["id"] != "h1" {
		t.Fatalf("remote host = %v, want the stored descriptor", hosts["remote"])
	}
}

func TestListShowsHostDestroyed(t *testing.T) {
	git := &vcs.Git{Executor: &mockExecutor{}}
	svc, _, _ := newTestService(t, git)
	remoteConfig(t, svc, git)

	l, err := svc.Listing("/a")
	if err != nil {
		t.Fatal(err)
	}
	if out := listingText(l); !strings.Contains(out, "host destroyed by its provider") {
		t.Fatalf("expected the destroyed state in the human listing, got %q", out)
	}
}
