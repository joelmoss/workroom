package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func newTestConfig(t *testing.T) *Config {
	t.Helper()
	dir := t.TempDir()
	c, err := New(filepath.Join(dir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestConfigPath(t *testing.T) {
	c, err := New("")
	if err != nil {
		t.Fatal(err)
	}
	home, _ := os.UserHomeDir()
	expected := filepath.Join(home, ".config", "workroom", "config.json")
	if c.Path() != expected {
		t.Fatalf("expected %s, got %s", expected, c.Path())
	}
}

func TestReadEmpty(t *testing.T) {
	c := newTestConfig(t)
	data, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}
	if len(data) != 0 {
		t.Fatalf("expected empty map, got %v", data)
	}
}

func TestAddWorkroom(t *testing.T) {
	c := newTestConfig(t)

	if err := c.AddWorkroom("/project", "foo", "/foo", "jj"); err != nil {
		t.Fatal(err)
	}

	data, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}

	project := data["/project"].(map[string]any)
	if project["vcs"] != "jj" {
		t.Fatalf("expected vcs jj, got %v", project["vcs"])
	}

	workrooms := project["workrooms"].(map[string]any)
	foo := workrooms["foo"].(map[string]any)
	if foo["path"] != "/foo" {
		t.Fatalf("expected path /foo, got %v", foo["path"])
	}
}

func TestAddMultipleWorkrooms(t *testing.T) {
	c := newTestConfig(t)

	if err := c.AddWorkroom("/project", "foo", "/foo", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.AddWorkroom("/project", "bar", "/bar", "jj"); err != nil {
		t.Fatal(err)
	}

	data, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}

	project := data["/project"].(map[string]any)
	workrooms := project["workrooms"].(map[string]any)

	foo := workrooms["foo"].(map[string]any)
	if foo["path"] != "/foo" {
		t.Fatalf("expected /foo, got %v", foo["path"])
	}
	bar := workrooms["bar"].(map[string]any)
	if bar["path"] != "/bar" {
		t.Fatalf("expected /bar, got %v", bar["path"])
	}
}

func TestRemoveWorkroomCleansUpEmptyParent(t *testing.T) {
	c := newTestConfig(t)

	if err := c.AddWorkroom("/project", "foo", "/foo", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.RemoveWorkroom("/project", "foo"); err != nil {
		t.Fatal(err)
	}

	data, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}

	if _, ok := data["/project"]; ok {
		t.Fatal("expected /project to be removed")
	}
}

func TestRemoveWorkroomKeepsRemainingWorkrooms(t *testing.T) {
	c := newTestConfig(t)

	if err := c.AddWorkroom("/project", "foo", "/foo", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.AddWorkroom("/project", "bar", "/bar", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.RemoveWorkroom("/project", "foo"); err != nil {
		t.Fatal(err)
	}

	data, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}

	project := data["/project"].(map[string]any)
	workrooms := project["workrooms"].(map[string]any)

	if _, ok := workrooms["foo"]; ok {
		t.Fatal("expected foo to be removed")
	}
	bar := workrooms["bar"].(map[string]any)
	if bar["path"] != "/bar" {
		t.Fatalf("expected /bar, got %v", bar["path"])
	}
}

func TestRemoveNonexistentParent(t *testing.T) {
	c := newTestConfig(t)

	if err := c.RemoveWorkroom("/nonexistent", "foo"); err != nil {
		t.Fatal(err)
	}

	data, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}
	if len(data) != 0 {
		t.Fatalf("expected empty config, got %v", data)
	}
}

func TestWorkroomsDirDefault(t *testing.T) {
	c := newTestConfig(t)
	home, _ := os.UserHomeDir()
	expected := filepath.Join(home, "workrooms")
	got, err := c.WorkroomsDir()
	if err != nil {
		t.Fatal(err)
	}
	if got != expected {
		t.Fatalf("expected %s, got %s", expected, got)
	}
}

func TestWorkroomsDirConfigured(t *testing.T) {
	c := newTestConfig(t)
	if err := c.SetWorkroomsDir("/custom/workrooms"); err != nil {
		t.Fatal(err)
	}
	got, err := c.WorkroomsDir()
	if err != nil {
		t.Fatal(err)
	}
	if got != "/custom/workrooms" {
		t.Fatalf("expected /custom/workrooms, got %s", got)
	}
}

func TestWorkroomsDirExpandsTilde(t *testing.T) {
	c := newTestConfig(t)
	if err := c.SetWorkroomsDir("~/my-workrooms"); err != nil {
		t.Fatal(err)
	}
	home, _ := os.UserHomeDir()
	expected := filepath.Join(home, "my-workrooms")
	got, err := c.WorkroomsDir()
	if err != nil {
		t.Fatal(err)
	}
	if got != expected {
		t.Fatalf("expected %s, got %s", expected, got)
	}
}

func TestSetProjectVCSUpdatesAndPreservesWorkrooms(t *testing.T) {
	c := newTestConfig(t)
	if err := c.AddWorkroom("/project", "foo", "/foo", "jj"); err != nil {
		t.Fatal(err)
	}

	if err := c.SetProjectVCS("/project", "git"); err != nil {
		t.Fatal(err)
	}

	data, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}
	project := data["/project"].(map[string]any)
	if project["vcs"] != "git" {
		t.Fatalf("expected vcs git, got %v", project["vcs"])
	}
	workrooms, ok := project["workrooms"].(map[string]any)
	if !ok {
		t.Fatal("workrooms map was clobbered")
	}
	if _, ok := workrooms["foo"].(map[string]any); !ok {
		t.Fatalf("expected workroom foo preserved, got %v", workrooms)
	}
}

func TestSetProjectVCSAbsentProjectIsNoOp(t *testing.T) {
	c := newTestConfig(t)
	if err := c.SetProjectVCS("/nope", "git"); err != nil {
		t.Fatal(err)
	}
	data, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := data["/nope"]; exists {
		t.Fatal("SetProjectVCS must not create an absent project")
	}
}

func TestFindCurrentProjectAsProject(t *testing.T) {
	c := newTestConfig(t)
	if err := c.AddWorkroom("/project", "foo", "/foo", "jj"); err != nil {
		t.Fatal(err)
	}

	path, project, found := c.FindCurrentProject("/project")
	if !found {
		t.Fatal("expected to find project")
	}
	if path != "/project" {
		t.Fatalf("expected /project, got %s", path)
	}
	if project.VCS != "jj" {
		t.Fatalf("expected jj, got %v", project.VCS)
	}
}

func TestFindCurrentProjectAsWorkroom(t *testing.T) {
	c := newTestConfig(t)
	if err := c.AddWorkroom("/project", "foo", "/workrooms/foo", "jj"); err != nil {
		t.Fatal(err)
	}

	path, project, found := c.FindCurrentProject("/workrooms/foo")
	if !found {
		t.Fatal("expected to find project")
	}
	if path != "/project" {
		t.Fatalf("expected /project, got %s", path)
	}
	if project.VCS != "jj" {
		t.Fatalf("expected jj, got %v", project.VCS)
	}
}

func TestFindCurrentProjectNotFound(t *testing.T) {
	c := newTestConfig(t)

	path, project, found := c.FindCurrentProject("/unknown")
	if found {
		t.Fatal("expected not found")
	}
	if path != "/unknown" {
		t.Fatalf("expected /unknown, got %s", path)
	}
	if project != nil {
		t.Fatalf("expected nil project, got %v", project)
	}
}

func TestProjectsWithWorkrooms(t *testing.T) {
	c := newTestConfig(t)
	if err := c.AddWorkroom("/project1", "foo", "/foo", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.AddWorkroom("/project2", "bar", "/bar", "git"); err != nil {
		t.Fatal(err)
	}

	projects, err := c.ProjectsWithWorkrooms()
	if err != nil {
		t.Fatal(err)
	}
	if len(projects) != 2 {
		t.Fatalf("expected 2 projects, got %d", len(projects))
	}
}

func TestCreatesConfigDirOnWrite(t *testing.T) {
	dir := t.TempDir()
	c, err := New(filepath.Join(dir, "subdir", "config.json"))
	if err != nil {
		t.Fatal(err)
	}

	if err := c.AddWorkroom("/project", "foo", "/foo", "jj"); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(dir, "subdir", "config.json")); err != nil {
		t.Fatalf("expected config file to exist: %v", err)
	}
}

// TestHostDescriptorsRoundTripThroughEveryWriter runs each config mutator a CLI command uses
// (create, delete, add-project, delete-project, the vcs heal in list, workrooms_dir, channel)
// and checks that both levels' host descriptors come out exactly as they went in.
func TestHostDescriptorsRoundTripThroughEveryWriter(t *testing.T) {
	c := newTestConfig(t)
	projectHost := map[string]any{"provider": "boxd", "base": map[string]any{"id": "b1"}, "n": json.Number("1")}
	// A provider id above 2^53 is where a float64 round trip changes the value.
	workroomHost := map[string]any{
		"id": "h1", "provider": "boxd", "state": "running", "extra": []any{"x"},
		"instance": json.Number("9007199254740993"),
	}
	if err := c.Write(map[string]any{
		"/p": map[string]any{
			"vcs":  "jj",
			"host": projectHost,
			"workrooms": map[string]any{
				"remote": map[string]any{"path": "/home/wr/remote", "host": workroomHost},
			},
		},
		"/other": map[string]any{"vcs": "git", "workrooms": map[string]any{}},
	}); err != nil {
		t.Fatal(err)
	}

	writers := []struct {
		name string
		run  func() error
	}{
		{"AddWorkroom", func() error { return c.AddWorkroom("/p", "local", "/wr/local", "jj") }},
		{"AddProject", func() error { return c.AddProject("/p", "jj") }},
		{"SetProjectVCS", func() error { return c.SetProjectVCS("/p", "git") }},
		{"RemoveWorkroomKeepProject", func() error { return c.RemoveWorkroomKeepProject("/p", "local") }},
		{"AddWorkroom again", func() error { return c.AddWorkroom("/p", "local", "/wr/local", "git") }},
		{"RemoveWorkroom", func() error { return c.RemoveWorkroom("/p", "local") }},
		{"RemoveProject of another", func() error { return c.RemoveProject("/other") }},
		{"SetWorkroomsDir", func() error { return c.SetWorkroomsDir("~/elsewhere") }},
		{"SetChannel", func() error { return c.SetChannel("pre") }},
	}
	for _, w := range writers {
		if err := w.run(); err != nil {
			t.Fatalf("%s: %v", w.name, err)
		}
		projects, err := c.AllProjects()
		if err != nil {
			t.Fatal(err)
		}
		p := projects["/p"]
		if !reflect.DeepEqual(p.Host, projectHost) {
			t.Fatalf("%s: project host = %v, want %v", w.name, p.Host, projectHost)
		}
		if got := p.Workrooms["remote"]; !reflect.DeepEqual(got.Host, workroomHost) || got.Path != "/home/wr/remote" {
			t.Fatalf("%s: remote workroom = %+v, want host %v", w.name, got, workroomHost)
		}
	}
}

// A project that carries a host descriptor outlives its last workroom: the descriptor is the
// record of a remote machine. One without keeps the old cleanup.
func TestRemoveWorkroomKeepsProjectWithHost(t *testing.T) {
	c := newTestConfig(t)
	c.AddWorkroom("/p", "a", "/wr/a", "git")
	c.AddWorkroom("/q", "b", "/wr/b", "git")
	data, _ := c.Read()
	data["/p"].(map[string]any)["host"] = map[string]any{"provider": "boxd"}
	c.Write(data)

	c.RemoveWorkroom("/p", "a")
	c.RemoveWorkroom("/q", "b")

	data, _ = c.Read()
	if _, ok := data["/p"]; !ok {
		t.Fatal("a project with a host descriptor was dropped with its last workroom")
	}
	if _, ok := data["/q"]; ok {
		t.Fatal("a project without one should still be dropped with its last workroom")
	}
}

func TestDecodeHostDescriptors(t *testing.T) {
	c := newTestConfig(t)
	c.Write(map[string]any{
		"/p": map[string]any{"vcs": "git", "workrooms": map[string]any{
			"local":     map[string]any{"path": "/wr/local"},
			"remote":    map[string]any{"path": "/r", "host": map[string]any{"id": "h1"}},
			"destroyed": map[string]any{"path": "/r", "host": map[string]any{"state": "destroyed"}},
			"malformed": map[string]any{"path": "/r", "host": "boxd"},
			"null":      map[string]any{"path": "/r", "host": nil},
		}},
	})
	projects, err := c.AllProjects()
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string][2]bool{
		"local": {false, false}, "remote": {true, false}, "destroyed": {true, true},
		"malformed": {true, false}, "null": {false, false},
	} {
		w := projects["/p"].Workrooms[name]
		if got := [2]bool{w.IsRemote(), w.HostDestroyed()}; got != want {
			t.Fatalf("%s: (IsRemote, HostDestroyed) = %v, want %v", name, got, want)
		}
	}
	if got := projects["/p"].RemoteWorkroomNames(); !reflect.DeepEqual(got, []string{"destroyed", "malformed", "remote"}) {
		t.Fatalf("RemoteWorkroomNames = %v", got)
	}
}
