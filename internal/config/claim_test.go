package config

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

const dev = "com.developwithstyle.workroom.dev"

func writeRaw(t *testing.T, c *Config, data map[string]any) {
	t.Helper()
	if err := c.Write(data); err != nil {
		t.Fatal(err)
	}
}

func readRaw(t *testing.T, c *Config) map[string]any {
	t.Helper()
	data, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func host(provisioner, id string) map[string]any {
	return map[string]any{"driver": "boxd", "provisioner": provisioner, "id": id}
}

func TestNewReadsTheConfigNamedByTheEnvironment(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dev", "config.json")
	t.Setenv(ConfigEnv, path)
	c, err := New("")
	if err != nil || c.Path() != path {
		t.Fatalf("got %v, %v; want %s", c.Path(), err, path)
	}
	t.Setenv(ConfigEnv, "")
	if c, _ := New(""); filepath.Base(filepath.Dir(c.Path())) != "workroom" {
		t.Fatalf("without the variable, got %s", c.Path())
	}
}

// What a Dev build made leaves the shared config for its own, in either shape a project's host
// takes, and everything another build made, or nobody, stays.
func TestClaimMovesOnlyWhatTheBuildMade(t *testing.T) {
	dir := t.TempDir()
	shared, _ := New(filepath.Join(dir, "shared.json"))
	mine, _ := New(filepath.Join(dir, "mine.json"))
	writeRaw(t, shared, map[string]any{
		"workrooms_dir": "~/rooms",
		"channel":       "nightly",
		"/a": map[string]any{
			"vcs": "git",
			// The single-host shape, written before a project could have more than one base.
			"host": host(dev, "base-a"),
			"workrooms": map[string]any{
				"dev-room":   map[string]any{"path": "/home/boxd/a", "host": host(dev, "w1")},
				"other-room": map[string]any{"path": "/home/boxd/a", "host": host("nightly", "w2")},
				"local-room": map[string]any{"path": "/tmp/a"},
			},
		},
		"/b": map[string]any{
			"vcs":       "git",
			"host":      map[string]any{"bases": []any{host(dev, "base-b1"), host("nightly", "base-b2")}},
			"workrooms": map[string]any{},
		},
		"/c": map[string]any{"vcs": "git", "workrooms": map[string]any{}},
	})

	moved, err := mine.ClaimProvisioned(shared, dev)
	if err != nil || moved != 3 {
		t.Fatalf("moved %d, %v; want 3", moved, err)
	}
	want := map[string]any{
		"workrooms_dir": "~/rooms",
		"/a": map[string]any{
			"vcs":  "git",
			"host": map[string]any{"bases": []any{host(dev, "base-a")}},
			"workrooms": map[string]any{
				"dev-room": map[string]any{"path": "/home/boxd/a", "host": host(dev, "w1")},
			},
		},
		"/b": map[string]any{
			"vcs":       "git",
			"host":      map[string]any{"bases": []any{host(dev, "base-b1")}},
			"workrooms": map[string]any{},
		},
	}
	if got := readRaw(t, mine); !reflect.DeepEqual(got, want) {
		t.Fatalf("mine:\n%v\nwant:\n%v", got, want)
	}
	left := readRaw(t, shared)
	a := left["/a"].(map[string]any)
	if _, ok := a["host"]; ok {
		t.Fatal("a project with no base left keeps a host")
	}
	if names := a["workrooms"].(map[string]any); len(names) != 2 || names["dev-room"] != nil {
		t.Fatalf("shared /a workrooms: %v", names)
	}
	b := left["/b"].(map[string]any)["host"].(map[string]any)["bases"].([]any)
	if len(b) != 1 || b[0].(map[string]any)["id"] != "base-b2" {
		t.Fatalf("shared /b bases: %v", b)
	}
	if left["channel"] != "nightly" || left["/c"] == nil {
		t.Fatalf("shared lost what is not the build's: %v", left)
	}
}

// Nothing the build made: neither file is written, and the build's own is not created.
func TestClaimWithNothingToMoveTouchesNothing(t *testing.T) {
	dir := t.TempDir()
	shared, _ := New(filepath.Join(dir, "shared.json"))
	mine, _ := New(filepath.Join(dir, "mine.json"))
	writeRaw(t, shared, map[string]any{"/c": map[string]any{"vcs": "git", "workrooms": map[string]any{}}})
	before, _ := os.Stat(shared.Path())
	if moved, err := mine.ClaimProvisioned(shared, dev); err != nil || moved != 0 {
		t.Fatalf("moved %d, %v", moved, err)
	}
	if after, _ := os.Stat(shared.Path()); !after.ModTime().Equal(before.ModTime()) {
		t.Fatal("shared was written")
	}
	if _, err := os.Stat(mine.Path()); !os.IsNotExist(err) {
		t.Fatal("the build's config was created")
	}
}

// A crash after the build's config was written leaves entries in both: the next claim takes them
// out of shared and adds no second copy.
func TestClaimAfterAnInterruptedMoveFinishesIt(t *testing.T) {
	dir := t.TempDir()
	shared, _ := New(filepath.Join(dir, "shared.json"))
	mine, _ := New(filepath.Join(dir, "mine.json"))
	project := func() map[string]any {
		return map[string]any{
			"vcs":  "git",
			"host": map[string]any{"bases": []any{host(dev, "base")}},
			"workrooms": map[string]any{
				"room": map[string]any{"path": "/home/boxd/a", "host": host(dev, "w")},
			},
		}
	}
	writeRaw(t, shared, map[string]any{"/a": project()})
	writeRaw(t, mine, map[string]any{"/a": project()})
	if moved, err := mine.ClaimProvisioned(shared, dev); err != nil || moved != 2 {
		t.Fatalf("moved %d, %v; want 2", moved, err)
	}
	if got := readRaw(t, mine); !reflect.DeepEqual(got, map[string]any{"/a": project()}) {
		t.Fatalf("mine: %v", got)
	}
	a := readRaw(t, shared)["/a"].(map[string]any)
	if _, ok := a["host"]; ok || len(a["workrooms"].(map[string]any)) != 0 {
		t.Fatalf("shared still holds the build's entries: %v", a)
	}
}

// A base joins the ones the build's config already records for the project; it replaces none.
func TestClaimKeepsTheBasesTheBuildAlreadyHas(t *testing.T) {
	dir := t.TempDir()
	shared, _ := New(filepath.Join(dir, "shared.json"))
	mine, _ := New(filepath.Join(dir, "mine.json"))
	writeRaw(t, shared, map[string]any{"/a": map[string]any{
		"vcs": "git", "host": map[string]any{"bases": []any{host(dev, "boxd-base")}},
		"workrooms": map[string]any{},
	}})
	writeRaw(t, mine, map[string]any{"/a": map[string]any{
		"vcs": "git", "host": map[string]any{"bases": []any{host(dev, "container-base")}},
		"workrooms": map[string]any{},
	}})
	if moved, err := mine.ClaimProvisioned(shared, dev); err != nil || moved != 1 {
		t.Fatalf("moved %d, %v; want 1", moved, err)
	}
	got := readRaw(t, mine)["/a"].(map[string]any)["host"].(map[string]any)["bases"].([]any)
	if !reflect.DeepEqual(got, []any{host(dev, "container-base"), host(dev, "boxd-base")}) {
		t.Fatalf("bases: %v", got)
	}
}
