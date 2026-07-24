package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/workroom"
)

// requireGit skips a test when the git binary is not on PATH (the create flow
// shells out to real git, like the delete-project integration tests).
func requireGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
}

// newCreateSvc returns a Service backed by a throwaway config file, plus the
// config, for exercising add-project --create. The config lives in its own temp
// dir so project directories created by the tests stay separate.
func newCreateSvc(t *testing.T) (*workroom.Service, *config.Config) {
	t.Helper()
	cfg, err := config.New(filepath.Join(t.TempDir(), "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	return &workroom.Service{Config: cfg, Out: &bytes.Buffer{}}, cfg
}

func decodeEnvelope(t *testing.T, b []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("decode envelope: %v\n%s", err, b)
	}
	return m
}

// TestAddProjectCreate_MissingPath: --create on a path that does not exist
// creates the directory, git-inits it with an initial commit, registers it as a
// git project, and reports {path, vcs:"git"}.
func TestAddProjectCreate_MissingPath(t *testing.T) {
	requireGit(t)
	svc, cfg := newCreateSvc(t)
	target := filepath.Join(t.TempDir(), "new", "project") // nested + missing

	var out bytes.Buffer
	canon, err := config.CanonicalPath(target)
	if err != nil {
		t.Fatal(err)
	}
	if err := runAddProjectCreate(svc, canon, &out); err != nil {
		t.Fatalf("create failed: %v", err)
	}

	// The registered/reported path is re-canonicalized once the dir exists (C4),
	// which resolves symlinks (e.g. /var -> /private/var on macOS), so it is the
	// source of truth — not the pre-create `canon`.
	env := decodeEnvelope(t, out.Bytes())
	got, _ := env["path"].(string)
	if env["vcs"] != "git" || got == "" || env["ok"] != true {
		t.Fatalf("unexpected envelope: %v", env)
	}
	if info, err := os.Stat(got); err != nil || !info.IsDir() {
		t.Fatalf("directory not created: err=%v", err)
	}
	if info, err := os.Stat(filepath.Join(got, ".git")); err != nil || !info.IsDir() {
		t.Fatalf(".git not created: err=%v", err)
	}
	if c := run(t, got, "git", "rev-list", "--count", "HEAD"); c != "1" {
		t.Fatalf("expected 1 commit, got %q", c)
	}
	data, _ := cfg.Read()
	if _, ok := data[got]; !ok {
		t.Fatalf("project not registered under %q: %v", got, data)
	}
}

// TestAddProjectCreate_ExistingEmptyDir: a pre-existing empty directory is
// git-inited (not rejected as non-repo).
func TestAddProjectCreate_ExistingEmptyDir(t *testing.T) {
	requireGit(t)
	svc, _ := newCreateSvc(t)
	canon := t.TempDir() // exists, empty

	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); err != nil {
		t.Fatalf("create on empty dir failed: %v", err)
	}
	if info, err := os.Stat(filepath.Join(canon, ".git")); err != nil || !info.IsDir() {
		t.Fatalf(".git not created in empty dir: err=%v", err)
	}
}

// TestAddProjectCreate_DSStoreOnlyDirCountsEmpty: a folder containing only macOS
// junk (.DS_Store) is treated as empty and gets git-inited (OV4).
func TestAddProjectCreate_DSStoreOnlyDirCountsEmpty(t *testing.T) {
	requireGit(t)
	svc, _ := newCreateSvc(t)
	canon := t.TempDir()
	if err := os.WriteFile(filepath.Join(canon, ".DS_Store"), []byte("junk"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); err != nil {
		t.Fatalf("create on .DS_Store-only dir failed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(canon, ".git")); err != nil {
		t.Fatalf(".git not created in junk-only dir: %v", err)
	}
}

// TestAddProjectCreate_ExistingGitRepoUsedAsIs: an existing git repo is used
// without re-initializing — its existing commit history is preserved.
func TestAddProjectCreate_ExistingGitRepoUsedAsIs(t *testing.T) {
	requireGit(t)
	svc, cfg := newCreateSvc(t)
	canon, err := config.CanonicalPath(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	run(t, canon, "git", "init", "-q")
	run(t, canon, "git", "config", "user.email", "t@e.com")
	run(t, canon, "git", "config", "user.name", "T")
	run(t, canon, "git", "commit", "-q", "--allow-empty", "-m", "real work")
	run(t, canon, "git", "commit", "-q", "--allow-empty", "-m", "more")
	before := run(t, canon, "git", "rev-list", "--count", "HEAD")

	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); err != nil {
		t.Fatalf("create on existing repo failed: %v", err)
	}
	if after := run(t, canon, "git", "rev-list", "--count", "HEAD"); after != before {
		t.Fatalf("existing repo was modified: commits %s -> %s", before, after)
	}
	data, _ := cfg.Read()
	proj, _ := data[canon].(map[string]any)
	if proj["vcs"] != "git" {
		t.Fatalf("expected vcs=git, got %v", proj["vcs"])
	}
}

// TestAddProjectCreate_ExistingJJRepoUsedAsIs: an existing jj repo registers as
// vcs=jj and is NOT git-inited. Skipped without jj.
func TestAddProjectCreate_ExistingJJRepoUsedAsIs(t *testing.T) {
	if _, err := exec.LookPath("jj"); err != nil {
		t.Skip("jj not available")
	}
	svc, cfg := newCreateSvc(t)
	canon, err := config.CanonicalPath(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	run(t, canon, "jj", "git", "init")

	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); err != nil {
		t.Fatalf("create on existing jj repo failed: %v", err)
	}
	// vcs=jj proves Detect took the jj branch and InitGit was NOT run (jj git init
	// may colocate a .git, so .git presence is not a reliable signal here).
	data, _ := cfg.Read()
	proj, _ := data[canon].(map[string]any)
	if proj["vcs"] != "jj" {
		t.Fatalf("expected vcs=jj, got %v", proj["vcs"])
	}
}

// TestAddProjectCreate_EndToEndWorkroomCreatable is the load-bearing proof for
// 1A+OV1: after creating a new project, a workroom can actually be created in it,
// and it branches from the initial commit (a real base, not an orphan).
func TestAddProjectCreate_EndToEndWorkroomCreatable(t *testing.T) {
	requireGit(t)
	svc, _ := newCreateSvc(t)
	canon, err := config.CanonicalPath(filepath.Join(t.TempDir(), "proj"))
	if err != nil {
		t.Fatal(err)
	}
	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); err != nil {
		t.Fatalf("create failed: %v", err)
	}

	wrPath := filepath.Join(t.TempDir(), "feat")
	g := &vcs.Git{Executor: &vcs.RealExecutor{}}
	if _, err := g.Create(canon, "feat", wrPath); err != nil {
		t.Fatalf("workroom creation in fresh project failed: %v", err)
	}
	if !branchExists(t, canon, "feat") {
		t.Fatal("workroom branch not created")
	}
	// Not an orphan: the worktree's HEAD is the project's initial commit.
	projHead := run(t, canon, "git", "rev-parse", "HEAD")
	wtHead := run(t, wrPath, "git", "rev-parse", "HEAD")
	if projHead != wtHead {
		t.Fatalf("worktree is an orphan branch (HEAD %s != project HEAD %s)", wtHead, projHead)
	}
}

// TestAddProjectCreate_HardenedCommitNoGitIdentity proves OV1: the initial commit
// succeeds even when global git has no user.name/user.email configured.
func TestAddProjectCreate_HardenedCommitNoGitIdentity(t *testing.T) {
	requireGit(t)
	// Strip any git identity from the environment for this test: empty global +
	// system config, and UNSET the GIT_*_NAME/EMAIL vars (setting them empty would
	// instead override our `-c user.name` and break the commit — env wins over -c).
	emptyCfg := filepath.Join(t.TempDir(), "gitconfig")
	if err := os.WriteFile(emptyCfg, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", emptyCfg)
	t.Setenv("GIT_CONFIG_SYSTEM", os.DevNull)
	for _, k := range []string{"GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"} {
		if v, ok := os.LookupEnv(k); ok {
			t.Cleanup(func() { _ = os.Setenv(k, v) })
			_ = os.Unsetenv(k)
		}
	}

	svc, _ := newCreateSvc(t)
	canon, err := config.CanonicalPath(filepath.Join(t.TempDir(), "proj"))
	if err != nil {
		t.Fatal(err)
	}
	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); err != nil {
		t.Fatalf("create with no git identity failed (OV1 regression): %v", err)
	}
	if c := run(t, canon, "git", "rev-list", "--count", "HEAD"); c != "1" {
		t.Fatalf("expected 1 commit, got %q", c)
	}
}

// TestAddProjectCreate_PathIsFile: --create on a path that exists as a regular
// file returns ErrNotDirectory.
func TestAddProjectCreate_PathIsFile(t *testing.T) {
	svc, _ := newCreateSvc(t)
	f := filepath.Join(t.TempDir(), "afile")
	if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	canon, _ := config.CanonicalPath(f)
	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); !errors.Is(err, errs.ErrNotDirectory) {
		t.Fatalf("expected ErrNotDirectory, got %v", err)
	}
}

// TestAddProjectCreate_FileInParentComponent: --create where a parent component
// is a file (MkdirAll → ENOTDIR) maps to ErrNotDirectory (codex C7).
func TestAddProjectCreate_FileInParentComponent(t *testing.T) {
	svc, _ := newCreateSvc(t)
	parent := filepath.Join(t.TempDir(), "afile")
	if err := os.WriteFile(parent, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	// CanonicalPath would fail to resolve the missing child but returns Abs.
	canon, err := config.CanonicalPath(filepath.Join(parent, "child"))
	if err != nil {
		t.Fatal(err)
	}
	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); !errors.Is(err, errs.ErrNotDirectory) {
		t.Fatalf("expected ErrNotDirectory for ENOTDIR, got %v", err)
	}
}

// TestAddProjectCreate_NonEmptyNonRepo: an existing non-empty directory that is
// not a repo is rejected (never inited over existing files).
func TestAddProjectCreate_NonEmptyNonRepo(t *testing.T) {
	svc, _ := newCreateSvc(t)
	canon := t.TempDir()
	if err := os.WriteFile(filepath.Join(canon, "README.md"), []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); !errors.Is(err, errs.ErrUnsupportedVCS) {
		t.Fatalf("expected ErrUnsupportedVCS, got %v", err)
	}
	if _, err := os.Stat(filepath.Join(canon, ".git")); !os.IsNotExist(err) {
		t.Fatal("non-empty dir must not be git-inited")
	}
}

// TestAddProjectCreate_RollbackOnRegisterFailure proves OV2: if registration
// fails after we created the directory, the directory is removed so a retry is
// clean. The config write is forced to fail by pointing it under a regular file.
func TestAddProjectCreate_RollbackOnRegisterFailure(t *testing.T) {
	requireGit(t)
	// A config whose parent is a file: any read/write fails.
	blocker := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.New(filepath.Join(blocker, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	svc := &workroom.Service{Config: cfg, Out: &bytes.Buffer{}}

	canon, err := config.CanonicalPath(filepath.Join(t.TempDir(), "proj"))
	if err != nil {
		t.Fatal(err)
	}
	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); err == nil {
		t.Fatal("expected an error from the failing config write")
	}
	if _, err := os.Stat(canon); !os.IsNotExist(err) {
		t.Fatalf("created directory must be rolled back on failure, stat err = %v", err)
	}
}

// TestAddProjectCreate_RollbackKeepsPreExistingDir: rollback must NEVER remove a
// directory that already existed (only one we created).
func TestAddProjectCreate_RollbackKeepsPreExistingDir(t *testing.T) {
	requireGit(t)
	blocker := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.New(filepath.Join(blocker, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	svc := &workroom.Service{Config: cfg, Out: &bytes.Buffer{}}

	canon := t.TempDir() // pre-existing empty dir
	if err := runAddProjectCreate(svc, canon, &bytes.Buffer{}); err == nil {
		t.Fatal("expected an error from the failing config write")
	}
	if _, err := os.Stat(canon); err != nil {
		t.Fatalf("pre-existing directory must survive rollback, stat err = %v", err)
	}
}

// TestAddProjectExisting_RepoOnlyUnchanged is the regression guard: WITHOUT
// --create, add-project still rejects a missing path and a non-repo directory
// (the repo-only contract is preserved).
func TestAddProjectExisting_RepoOnlyUnchanged(t *testing.T) {
	svc, _ := newCreateSvc(t)

	missing, _ := config.CanonicalPath(filepath.Join(t.TempDir(), "nope"))
	if err := runAddProjectExisting(svc, missing, &bytes.Buffer{}); !errors.Is(err, errs.ErrUnsupportedVCS) {
		t.Fatalf("missing path without --create should be UnsupportedVCS, got %v", err)
	}

	nonRepo := t.TempDir() // exists, not a repo
	if err := runAddProjectExisting(svc, nonRepo, &bytes.Buffer{}); !errors.Is(err, errs.ErrUnsupportedVCS) {
		t.Fatalf("non-repo dir without --create should be UnsupportedVCS, got %v", err)
	}
	if _, err := os.Stat(filepath.Join(nonRepo, ".git")); !os.IsNotExist(err) {
		t.Fatal("no-create path must never git-init")
	}
}

// TestAddProjectCreate_PretendDryRun proves OV3: --create --pretend mutates
// nothing and reports the intended action.
func TestAddProjectCreate_PretendDryRun(t *testing.T) {
	old := pretend
	pretend = true
	defer func() { pretend = old }()

	svc, cfg := newCreateSvc(t)
	canon, err := config.CanonicalPath(filepath.Join(t.TempDir(), "proj"))
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := runAddProjectCreate(svc, canon, &out); err != nil {
		t.Fatalf("pretend dry-run failed: %v", err)
	}
	if _, err := os.Stat(canon); !os.IsNotExist(err) {
		t.Fatal("pretend must not create the directory")
	}
	data, _ := cfg.Read()
	if _, ok := data[canon]; ok {
		t.Fatal("pretend must not register the project")
	}
	env := decodeEnvelope(t, out.Bytes())
	if env["would_create"] != true || env["vcs"] != "git" {
		t.Fatalf("unexpected dry-run envelope: %v", env)
	}
}

// TestAddProjectExisting_PretendDryRun proves the non-create path now honors
// --pretend symmetrically with --create: the repo is detected (so a bad path
// still errors) but the project is never registered.
func TestAddProjectExisting_PretendDryRun(t *testing.T) {
	requireGit(t)
	old := pretend
	pretend = true
	defer func() { pretend = old }()

	svc, cfg := newCreateSvc(t)
	canon, err := config.CanonicalPath(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	run(t, canon, "git", "init", "-q")
	run(t, canon, "git", "config", "user.email", "t@e.com")
	run(t, canon, "git", "config", "user.name", "T")
	run(t, canon, "git", "commit", "-q", "--allow-empty", "-m", "real work")

	var out bytes.Buffer
	if err := runAddProjectExisting(svc, canon, &out); err != nil {
		t.Fatalf("pretend dry-run failed: %v", err)
	}
	data, _ := cfg.Read()
	if _, ok := data[canon]; ok {
		t.Fatal("pretend must not register the project")
	}
	env := decodeEnvelope(t, out.Bytes())
	if env["would_create"] != false || env["vcs"] != "git" {
		t.Fatalf("unexpected dry-run envelope: %v", env)
	}
}

// TestAddProjectExisting_PretendNonRepoStillErrors proves detection still runs
// under --pretend: a non-repo path errors with ErrUnsupportedVCS, it is never
// registered, and no dry-run envelope is written for it.
func TestAddProjectExisting_PretendNonRepoStillErrors(t *testing.T) {
	old := pretend
	pretend = true
	defer func() { pretend = old }()

	svc, cfg := newCreateSvc(t)
	nonRepo := t.TempDir() // exists, not a repo

	var out bytes.Buffer
	err := runAddProjectExisting(svc, nonRepo, &out)
	if !errors.Is(err, errs.ErrUnsupportedVCS) {
		t.Fatalf("non-repo dir under --pretend should be UnsupportedVCS, got %v", err)
	}
	if out.Len() != 0 {
		t.Fatalf("no envelope should be written on error, got %q", out.String())
	}
	data, _ := cfg.Read()
	if _, ok := data[nonRepo]; ok {
		t.Fatal("pretend must not register the project")
	}
}
