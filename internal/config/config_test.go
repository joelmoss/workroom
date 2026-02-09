package config

import (
	"os"
	"path/filepath"
	"testing"
)

func newTestConfig(t *testing.T) *Config {
	t.Helper()
	dir := t.TempDir()
	return New(filepath.Join(dir, "config.json"))
}

func TestConfigPath(t *testing.T) {
	c := New("")
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
	if c.WorkroomsDir() != expected {
		t.Fatalf("expected %s, got %s", expected, c.WorkroomsDir())
	}
}

func TestWorkroomsDirConfigured(t *testing.T) {
	c := newTestConfig(t)
	if err := c.SetWorkroomsDir("/custom/workrooms"); err != nil {
		t.Fatal(err)
	}
	if c.WorkroomsDir() != "/custom/workrooms" {
		t.Fatalf("expected /custom/workrooms, got %s", c.WorkroomsDir())
	}
}

func TestWorkroomsDirExpandsTilde(t *testing.T) {
	c := newTestConfig(t)
	if err := c.SetWorkroomsDir("~/my-workrooms"); err != nil {
		t.Fatal(err)
	}
	home, _ := os.UserHomeDir()
	expected := filepath.Join(home, "my-workrooms")
	if c.WorkroomsDir() != expected {
		t.Fatalf("expected %s, got %s", expected, c.WorkroomsDir())
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
	if project["vcs"] != "jj" {
		t.Fatalf("expected jj, got %v", project["vcs"])
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
	if project["vcs"] != "jj" {
		t.Fatalf("expected jj, got %v", project["vcs"])
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
	c := New(filepath.Join(dir, "subdir", "config.json"))

	if err := c.AddWorkroom("/project", "foo", "/foo", "jj"); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(dir, "subdir", "config.json")); err != nil {
		t.Fatalf("expected config file to exist: %v", err)
	}
}
