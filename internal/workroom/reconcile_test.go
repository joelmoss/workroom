package workroom

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs"
)

// fakeVCS is a controlled vcs.VCS whose ListWorkrooms returns a fixed set, so tests that
// exercise the reconcile/warning paths don't depend on a real git/jj repo on disk (per the
// eng-review note: a bare .git dir makes real Git.ListWorkrooms shell out and silently yield
// nothing). listCalls counts ListWorkrooms invocations to assert "list once per project".
type fakeVCS struct {
	typ       vcs.Type
	list      []string
	err       error
	listCalls int
}

func (f *fakeVCS) Type() vcs.Type { return f.typ }
func (f *fakeVCS) Label() string  { return string(f.typ) }
func (f *fakeVCS) Create(dir, vcsName, path string) (string, error) {
	return "", nil
}
func (f *fakeVCS) Delete(dir, vcsName, path string) (string, error) {
	return "", nil
}
func (f *fakeVCS) ListWorkrooms(dir string) ([]string, error) {
	f.listCalls++
	return f.list, f.err
}

// storedVCS reads the persisted vcs string for a project path from the config on disk.
func storedVCS(t *testing.T, svc *Service, path string) string {
	t.Helper()
	data, err := svc.Config.Read()
	if err != nil {
		t.Fatal(err)
	}
	proj, ok := data[path].(map[string]any)
	if !ok {
		return "<absent>"
	}
	v, _ := proj["vcs"].(string)
	return v
}

func TestEffectiveVCSHealsDriftAndPersists(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, ".git"), 0o755); err != nil { // plain git now
		t.Fatal(err)
	}
	svc, _, cfg := newTestService(t, nil)
	if err := cfg.AddProject(dir, "jj"); err != nil { // stored as jj (colocated legacy)
		t.Fatal(err)
	}

	got := svc.effectiveVCS(dir, "jj", true)
	if got != "git" {
		t.Fatalf("effectiveVCS = %q, want git", got)
	}
	if s := storedVCS(t, svc, dir); s != "git" {
		t.Fatalf("config vcs = %q, want healed to git", s)
	}
}

func TestEffectiveVCSColocatedNoDrift(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)
	svc, _, cfg := newTestService(t, nil)
	cfg.AddProject(dir, "jj")

	if got := svc.effectiveVCS(dir, "jj", true); got != "jj" { // .jj has detection priority
		t.Fatalf("effectiveVCS = %q, want jj (priority)", got)
	}
	if s := storedVCS(t, svc, dir); s != "jj" {
		t.Fatalf("config vcs = %q, want unchanged jj", s)
	}
}

func TestEffectiveVCSPersistFalseDoesNotWrite(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)
	svc, _, cfg := newTestService(t, nil)
	cfg.AddProject(dir, "jj")

	if got := svc.effectiveVCS(dir, "jj", false); got != "git" {
		t.Fatalf("effectiveVCS = %q, want git", got)
	}
	if s := storedVCS(t, svc, dir); s != "jj" {
		t.Fatalf("config vcs = %q, want unchanged jj (persist=false)", s)
	}
}

func TestEffectiveVCSFallsBackWhenUndetectable(t *testing.T) {
	svc, _, _ := newTestService(t, nil)

	// Missing directory.
	missing := filepath.Join(t.TempDir(), "gone")
	if got := svc.effectiveVCS(missing, "jj", true); got != "jj" {
		t.Fatalf("missing dir: effectiveVCS = %q, want fallback jj", got)
	}
	// Directory exists but is neither a git nor jj repo.
	empty := t.TempDir()
	if got := svc.effectiveVCS(empty, "git", true); got != "git" {
		t.Fatalf("non-repo dir: effectiveVCS = %q, want fallback git", got)
	}
}

func TestListDataFastHealsDrift(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)
	svc, _, cfg := newTestService(t, nil)
	cfg.AddWorkroom(dir, "w1", filepath.Join(dir, "w1"), "jj") // stored jj

	res, err := svc.ListData(WarningsFast)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, p := range res.Projects {
		if p.Path == dir {
			found = true
			if p.VCS != "git" {
				t.Fatalf("reported vcs = %q, want git", p.VCS)
			}
		}
	}
	if !found {
		t.Fatalf("project %s not in listing", dir)
	}
	if s := storedVCS(t, svc, dir); s != "git" {
		t.Fatalf("config vcs = %q, want healed to git", s)
	}
}

func TestListDataNoneDoesNotReconcile(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)
	svc, _, cfg := newTestService(t, nil)
	cfg.AddWorkroom(dir, "w1", filepath.Join(dir, "w1"), "jj")

	res, err := svc.ListData(WarningsNone)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range res.Projects {
		if p.Path == dir && p.VCS != "jj" {
			t.Fatalf("WarningsNone reported vcs = %q, want stored jj (no reconcile)", p.VCS)
		}
	}
	if s := storedVCS(t, svc, dir); s != "jj" {
		t.Fatalf("WarningsNone must not write config; vcs = %q, want jj", s)
	}
}

func TestListDataFullUsesReconciledVCS(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755) // drift: stored jj, on-disk git
	svc, _, cfg := newTestService(t, nil)
	cfg.AddWorkroom(dir, "w1", filepath.Join(dir, "w1"), "jj")
	cfg.AddWorkroom(dir, "w2", filepath.Join(dir, "w2"), "jj")

	fake := &fakeVCS{typ: vcs.TypeGit, list: []string{"w1"}} // git lists bare names; w2 absent
	var gotType vcs.Type
	svc.VCSForTypeFunc = func(tp vcs.Type) (vcs.VCS, error) { gotType = tp; return fake, nil }

	res, err := svc.ListData(WarningsFull)
	if err != nil {
		t.Fatal(err)
	}
	if gotType != vcs.TypeGit {
		t.Fatalf("vcsForType called with %q, want git (reconciled type must drive the listing)", gotType)
	}
	if fake.listCalls != 1 {
		t.Fatalf("ListWorkrooms called %d times, want exactly 1 (once per project)", fake.listCalls)
	}
	warn := map[string]bool{}
	for _, p := range res.Projects {
		for _, w := range p.Workrooms {
			for _, x := range w.Warnings {
				if x.Kind == "VCSWorkroomMissing" {
					warn[w.Name] = true
				}
			}
		}
	}
	if warn["w1"] {
		t.Fatal("w1 is present in the listing; must not be flagged missing")
	}
	if !warn["w2"] {
		t.Fatal("w2 is absent from the listing; must be flagged VCSWorkroomMissing")
	}
}

func TestListHumanPathWarnsAndListsOnce(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755) // drift: stored jj, on-disk git
	svc, buf, cfg := newTestService(t, nil)
	// Two workrooms whose dirs exist (so only the VCS-workspace warning can fire).
	os.MkdirAll(filepath.Join(dir, "w1"), 0o755)
	os.MkdirAll(filepath.Join(dir, "w2"), 0o755)
	cfg.AddWorkroom(dir, "w1", filepath.Join(dir, "w1"), "jj")
	cfg.AddWorkroom(dir, "w2", filepath.Join(dir, "w2"), "jj")

	fake := &fakeVCS{typ: vcs.TypeGit, list: []string{"w1"}} // w2 absent from VCS
	svc.VCSForTypeFunc = func(tp vcs.Type) (vcs.VCS, error) { return fake, nil }

	if err := svc.List(dir); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	if !strings.Contains(out, "git workspace not found") {
		t.Fatalf("expected a 'git workspace not found' warning for w2, got:\n%s", out)
	}
	if fake.listCalls != 1 {
		t.Fatalf("human List called ListWorkrooms %d times, want 1 (no N+1)", fake.listCalls)
	}
	if s := storedVCS(t, svc, dir); s != "git" {
		t.Fatalf("human List did not heal config; vcs = %q, want git", s)
	}
}

func TestListHumanPathNoFalseWarningWhenListUnavailable(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".git"), 0o755)
	svc, buf, cfg := newTestService(t, nil)
	os.MkdirAll(filepath.Join(dir, "w1"), 0o755)
	cfg.AddWorkroom(dir, "w1", filepath.Join(dir, "w1"), "jj")

	// VCS listing unavailable → vcsWorkspaceSet returns nil → no VCS warning (fail-open).
	fake := &fakeVCS{typ: vcs.TypeGit, err: os.ErrPermission}
	svc.VCSForTypeFunc = func(tp vcs.Type) (vcs.VCS, error) { return fake, nil }

	if err := svc.List(dir); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(buf.String(), "workspace not found") {
		t.Fatalf("must not emit a workspace warning when listing is unavailable, got:\n%s", buf.String())
	}
}
