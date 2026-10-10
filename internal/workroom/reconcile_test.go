package workroom

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/vcs/vcstest"
)

// fakeVCS is a controlled vcs.VCS whose ListWorkrooms returns a fixed set, so tests that
// exercise the reconcile/warning paths don't depend on a real git repo on disk (per the
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
func (f *fakeVCS) Create(dir, vcsName, path, base string, fallback bool) (string, error) {
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
	vcstest.MakeGitDir(t, dir) // plain git now
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

func TestEffectiveVCSPersistFalseDoesNotWrite(t *testing.T) {
	dir := t.TempDir()
	vcstest.MakeGitDir(t, dir)
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
	// Directory exists but is not a git repo.
	empty := t.TempDir()
	if got := svc.effectiveVCS(empty, "git", true); got != "git" {
		t.Fatalf("non-repo dir: effectiveVCS = %q, want fallback git", got)
	}
}

func TestListDataFastHealsDrift(t *testing.T) {
	dir := t.TempDir()
	vcstest.MakeGitDir(t, dir)
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
	vcstest.MakeGitDir(t, dir)
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
	vcstest.MakeGitDir(t, dir) // drift: stored jj, on-disk git
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
	vcstest.MakeGitDir(t, dir) // drift: stored jj, on-disk git
	svc, _, cfg := newTestService(t, nil)
	// Two workrooms whose dirs exist (so only the VCS-workspace warning can fire).
	os.MkdirAll(filepath.Join(dir, "w1"), 0o755)
	os.MkdirAll(filepath.Join(dir, "w2"), 0o755)
	cfg.AddWorkroom(dir, "w1", filepath.Join(dir, "w1"), "jj")
	cfg.AddWorkroom(dir, "w2", filepath.Join(dir, "w2"), "jj")

	fake := &fakeVCS{typ: vcs.TypeGit, list: []string{"w1"}} // w2 absent from VCS
	svc.VCSForTypeFunc = func(tp vcs.Type) (vcs.VCS, error) { return fake, nil }

	l, err := svc.Listing(dir)
	if err != nil {
		t.Fatal(err)
	}
	out := listingText(l)
	if !strings.Contains(out, "git workroom not found") {
		t.Fatalf("expected a 'git workroom not found' warning for w2, got:\n%s", out)
	}
	if fake.listCalls != 1 {
		t.Fatalf("human Listing called ListWorkrooms %d times, want 1 (no N+1)", fake.listCalls)
	}
	if s := storedVCS(t, svc, dir); s != "git" {
		t.Fatalf("human Listing did not heal config; vcs = %q, want git", s)
	}
}

func TestListHumanPathNoFalseWarningWhenListUnavailable(t *testing.T) {
	dir := t.TempDir()
	vcstest.MakeGitDir(t, dir)
	svc, _, cfg := newTestService(t, nil)
	os.MkdirAll(filepath.Join(dir, "w1"), 0o755)
	cfg.AddWorkroom(dir, "w1", filepath.Join(dir, "w1"), "jj")

	// VCS listing unavailable → vcsWorkspaceSet returns nil → no VCS warning (fail-open).
	fake := &fakeVCS{typ: vcs.TypeGit, err: os.ErrPermission}
	svc.VCSForTypeFunc = func(tp vcs.Type) (vcs.VCS, error) { return fake, nil }

	l, err := svc.Listing(dir)
	if err != nil {
		t.Fatal(err)
	}
	if out := listingText(l); strings.Contains(out, "workroom not found") {
		t.Fatalf("must not emit a missing-workroom warning when listing is unavailable, got:\n%s", out)
	}
}

// A project stored as "jj" whose directory holds only .jj (non-colocated, from before #266) is
// unsupported now. Listing must neither fail nor flag its workrooms missing (it cannot ask git),
// and keeps reporting the stored type so the app can show it as unsupported.
func TestListDataFullToleratesAStoredJJProjectWithoutGit(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, ".jj"), 0o755)
	svc, _, cfg := newTestService(t, nil)
	cfg.AddWorkroom(dir, "w1", filepath.Join(dir, "w1"), "jj")

	res, err := svc.ListData(WarningsFull)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Projects) != 1 || res.Projects[0].VCS != "jj" {
		t.Fatalf("projects = %+v, want one project still reported as jj", res.Projects)
	}
	if len(res.Projects[0].Workrooms) != 1 {
		t.Fatalf("workrooms = %+v, want w1 listed", res.Projects[0].Workrooms)
	}
	for _, w := range res.Projects[0].Workrooms {
		for _, x := range w.Warnings {
			if x.Kind == "VCSWorkroomMissing" {
				t.Fatalf("w1 flagged %s although git cannot be asked about a jj-only repo", x.Kind)
			}
		}
	}
	if got := storedVCS(t, svc, dir); got != "jj" {
		t.Fatalf("stored vcs = %q, want jj left untouched", got)
	}
}

// The human list names each project before its checks run, and shows it before the next one's
// run: Listing runs none up front, yields a project's path before running its checks, and runs
// them only when asked, so one that stalls (a hung network volume) is named and holds back
// nothing before it.
func TestListingChecksEachProjectOnlyWhenReached(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	vcstest.MakeGitDir(t, a)
	vcstest.MakeGitDir(t, b)
	svc, _, cfg := newTestService(t, nil)
	cfg.AddWorkroom(a, "w1", filepath.Join(a, "w1"), "git")
	cfg.AddWorkroom(b, "w2", filepath.Join(b, "w2"), "git")
	fake := &fakeVCS{typ: vcs.TypeGit}
	svc.VCSForTypeFunc = func(vcs.Type) (vcs.VCS, error) { return fake, nil }

	l, err := svc.Listing(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if l.Count != 2 || fake.listCalls != 0 {
		t.Fatalf("Listing = %d projects after %d checks, want 2 projects and no checks yet", l.Count, fake.listCalls)
	}
	for path, project := range l.Projects {
		if path != a && path != b || fake.listCalls != 0 {
			t.Fatalf("first project %q reached after %d checks, want a project path and none", path, fake.listCalls)
		}
		project()
		break
	}
	if fake.listCalls != 1 {
		t.Fatalf("checking the first project ran %d checks, want 1", fake.listCalls)
	}
}
