package cmd

import (
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
