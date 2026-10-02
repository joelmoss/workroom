package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
)

// The app records a remote workroom it is about to make (#253): a generated name, the host's path
// and its descriptor in one entry, and nothing made on this Mac.
func TestCreateWithHostRecordsARemoteWorkroomAndMakesNothingHere(t *testing.T) {
	requireGit(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := t.TempDir()
	run(t, project, "git", "init", "-q", "-b", "main")
	run(t, project, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	canon, _ := config.CanonicalPath(project)
	if err := cfg.AddProject(canon, "git"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { createHost, createHostPath, createProject = "", "", "" })

	code, envelope := runHostCLI(t, "create", "--project", project, "--host", `{"driver":"container","state":"creating"}`,
		"--host-path", "/home/workroom/project", "--json")
	createHost, createHostPath, createProject = "", "", ""
	name, _ := envelope["name"].(string)
	if code != 0 || envelope["ok"] != true || name == "" || envelope["path"] != "/home/workroom/project" {
		t.Fatalf("create: exit %d, %v", code, envelope)
	}
	projects, _ := cfg.AllProjects()
	entry := projects[canon].Workrooms[name]
	if !entry.IsRemote() || entry.Path != "/home/workroom/project" {
		t.Fatalf("entry = %#v, want remote at the host's path", entry)
	}
	if branches := run(t, project, "git", "branch", "--list", "workroom/*"); branches != "" {
		t.Fatalf("a branch was made on this Mac: %q", branches)
	}
	dir, _ := cfg.WorkroomsDir()
	if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
		t.Fatalf("a directory was made on this Mac: %v", err)
	}

	code, envelope = runHostCLI(t, "create", "--project", project, "--host", `{}`, "--json")
	createHost, createHostPath, createProject = "", "", ""
	body, _ := envelope["error"].(map[string]any)
	if code != 2 || body["kind"] != "InvalidHostDescriptor" {
		t.Fatalf("no --host-path: exit %d, %v", code, envelope)
	}
}
