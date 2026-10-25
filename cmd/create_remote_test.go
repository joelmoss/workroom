package cmd

import (
	"os"
	"path"
	"path/filepath"
	"reflect"
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

func TestCreateWithHostParentReservesTheGeneratedLeaf(t *testing.T) {
	requireGit(t)
	t.Setenv("HOME", t.TempDir())
	project := t.TempDir()
	run(t, project, "git", "init", "-q", "-b", "main")
	run(t, project, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	canon, err := config.CanonicalPath(project)
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(canon, "git"); err != nil {
		t.Fatal(err)
	}
	parent := "/srv/joel/workrooms with spaces/"
	descriptor := `{"driver":"ssh","id":"shared-host","destination":"myserver","home":"/home/joel","state":"creating"}`
	var names []string
	for range 2 {
		code, envelope := runHostCLI(t, "create", "--project", project, "--host", descriptor,
			"--host-parent", parent, "--json")
		name, _ := envelope["name"].(string)
		if code != 0 || name == "" || envelope["path"] != path.Join(parent, name) {
			t.Fatalf("create: exit %d, %v", code, envelope)
		}
		names = append(names, name)
		projects, err := cfg.AllProjects()
		if err != nil {
			t.Fatal(err)
		}
		entry := projects[canon].Workrooms[name]
		wantHost, err := decodeHost(descriptor)
		if err != nil {
			t.Fatal(err)
		}
		if entry.Path != path.Join(parent, name) || !reflect.DeepEqual(entry.Host, wantHost) {
			t.Fatalf("entry = %#v, want generated leaf and unchanged SSH descriptor", entry)
		}
		dir, err := cfg.WorkroomsDir()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Fatalf("a directory was made on this Mac: %v", err)
		}
	}
	if names[0] == names[1] {
		t.Fatalf("two reservations used the same name: %q", names[0])
	}
	if branches := run(t, project, "git", "branch", "--list", "workroom/*"); branches != "" {
		t.Fatalf("a branch was made on this Mac: %q", branches)
	}
}

func TestCreateRejectsInvalidHostParentWithoutRecordingAnything(t *testing.T) {
	requireGit(t)
	t.Setenv("HOME", t.TempDir())
	project := t.TempDir()
	run(t, project, "git", "init", "-q", "-b", "main")
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	canon, err := config.CanonicalPath(project)
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(canon, "git"); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(cfg.Path())
	if err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"--host", `{}`, "--host-parent", "relative/workrooms"},
		{"--host", `{}`, "--host-parent", "~/workrooms"},
		{"--host", `{}`, "--host-parent", "/home/joel/workrooms", "--host-path", "/home/joel/checkout"},
		{"--host-parent", "/home/joel/workrooms"},
	} {
		code, envelope := runHostCLI(t, append([]string{"create", "--project", project, "--json"}, args...)...)
		body, _ := envelope["error"].(map[string]any)
		if code != 2 || body["kind"] != "InvalidHostDescriptor" {
			t.Errorf("%v: exit %d, %v", args, code, envelope)
		}
		after, err := os.ReadFile(cfg.Path())
		if err != nil {
			t.Fatal(err)
		}
		if string(after) != string(before) {
			t.Fatalf("%v changed the config:\n%s", args, after)
		}
	}
}
