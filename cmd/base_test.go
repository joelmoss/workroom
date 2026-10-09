package cmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/vcs/vcstest"
)

func TestBaseCommandsSetClearAndListTheBranch(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	project := t.TempDir()
	vcstest.MakeGitDir(t, project)
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	canon, _ := config.CanonicalPath(project)
	if err := cfg.AddProject(canon, "git"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { baseProject, listProject, baseGlobal = "", "", false })

	code, envelope := runHostCLI(t, "base", "set", "develop", "--project", project, "--json")
	if code != 0 || envelope["ok"] != true || envelope["base_branch"] != "develop" {
		t.Fatalf("set: exit %d, %v", code, envelope)
	}
	code, envelope = runHostCLI(t, "list", "--json", "--project", project)
	projects, _ := envelope["projects"].([]any)
	if code != 0 || len(projects) != 1 || projects[0].(map[string]any)["base_branch"] != "develop" {
		t.Fatalf("list: exit %d, %v", code, envelope)
	}

	if code, envelope = runHostCLI(t, "base", "set", "bad..name", "--project", project, "--json"); code == 0 {
		t.Fatalf("an invalid branch name was accepted: %v", envelope)
	}
	// A remote-qualified base is a valid setting: `upstream/main` for a fork.
	if code, envelope = runHostCLI(t, "base", "set", "upstream/main", "--project", project, "--json"); code != 0 {
		t.Fatalf("upstream/main was refused: %v", envelope)
	}

	code, envelope = runHostCLI(t, "base", "clear", "--project", project, "--json")
	if code != 0 || envelope["ok"] != true {
		t.Fatalf("clear: exit %d, %v", code, envelope)
	}
	got, _ := cfg.AllProjects()
	if got[canon].BaseBranch != "" {
		t.Fatalf("base after clear = %q", got[canon].BaseBranch)
	}
}

func TestBaseGlobalSetsTheDefaultAndListShowsIt(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Cleanup(func() { baseProject, listProject, baseGlobal = "", "", false })
	code, envelope := runHostCLI(t, "base", "set", "upstream/main", "--global", "--json")
	if code != 0 || envelope["global"] != true {
		t.Fatalf("set --global: exit %d, %v", code, envelope)
	}
	baseGlobal = false
	if code, envelope = runHostCLI(t, "list", "--json"); code != 0 || envelope["base_branch"] != "upstream/main" {
		t.Fatalf("list: exit %d, %v", code, envelope)
	}
	if code, _ = runHostCLI(t, "base", "clear", "--global", "--json"); code != 0 {
		t.Fatalf("clear --global: exit %d", code)
	}
	baseGlobal = false
	if _, envelope = runHostCLI(t, "list", "--json"); envelope["base_branch"] != nil {
		t.Fatalf("list after clear: %v", envelope)
	}
}

// A CLI user may need a base before the first create, which is what registers a project.
func TestBaseSetRegistersTheRepository(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	project := t.TempDir()
	vcstest.MakeGitDir(t, project)
	t.Cleanup(func() { baseProject, listProject, baseGlobal = "", "", false })
	if code, envelope := runHostCLI(t, "base", "set", "main", "--project", project, "--json"); code != 0 {
		t.Fatalf("set on an unregistered repository: exit %d, %v", code, envelope)
	}
	cfg, _ := config.New("")
	canon, _ := config.CanonicalPath(project)
	projects, _ := cfg.AllProjects()
	if projects[canon].BaseBranch != "main" {
		t.Fatalf("project = %#v, want it registered with base main", projects[canon])
	}
	if code, _ := runHostCLI(t, "base", "set", "main", "--project", t.TempDir(), "--json"); code == 0 {
		t.Fatal("a directory that is no repository was registered")
	}
}

// A base belongs to the root checkout: from a workroom terminal, `base set` must not register the
// workroom as a project of its own.
func TestBaseRefusesAWorkroom(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Cleanup(func() { baseProject, listProject, baseGlobal = "", "", false })
	project := t.TempDir()
	wr := filepath.Join(t.TempDir(), "wr")
	for _, args := range [][]string{
		{"init", "-q"},
		{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "first"},
		{"worktree", "add", "-q", "-b", "workroom/wr", wr},
	} {
		if out, err := exec.Command("git", append([]string{"-C", project}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	for _, verb := range []string{"set", "clear"} {
		args := []string{"base", verb}
		if verb == "set" {
			args = append(args, "develop")
		}
		code, envelope := runHostCLI(t, append(args, "--project", wr, "--json")...)
		kind, _ := envelope["error"].(map[string]any)["kind"].(string)
		if code == 0 || kind != "InWorkroom" {
			t.Fatalf("base %s in a workroom: exit %d, %v", verb, code, envelope)
		}
	}
	cfg, _ := config.New("")
	if projects, _ := cfg.AllProjects(); len(projects) != 0 {
		t.Fatalf("a workroom was registered: %v", projects)
	}
}

// `clear` only edits: it works for a project whose folder has gone, and registers nothing.
func TestBaseClearWorksForAMovedProjectAndRegistersNothing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Cleanup(func() { baseProject, listProject, baseGlobal = "", "", false })
	cfg, _ := config.New("")
	gone := filepath.Join(t.TempDir(), "gone")
	if err := cfg.AddProject(gone, "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.SetBaseBranch(gone, "develop"); err != nil {
		t.Fatal(err)
	}
	if code, envelope := runHostCLI(t, "base", "clear", "--project", gone, "--json"); code != 0 {
		t.Fatalf("clear for a moved project: exit %d, %v", code, envelope)
	}
	plain := t.TempDir()
	if err := os.MkdirAll(filepath.Join(plain, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	runHostCLI(t, "base", "clear", "--project", plain, "--json")
	canon, _ := config.CanonicalPath(plain)
	if projects, _ := cfg.AllProjects(); projects[canon].VCS != "" {
		t.Fatalf("clear registered a project: %v", projects)
	}
}
