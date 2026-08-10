package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAddProjectNewAndIdempotent(t *testing.T) {
	c := newTestConfig(t)

	// A project created via a workroom, then re-registered via AddProject with a
	// different vcs: vcs updates, workrooms are preserved (idempotent, no clobber).
	if err := c.AddWorkroom("/proj", "foo", "/wr/foo", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.AddProject("/proj", "git"); err != nil {
		t.Fatal(err)
	}
	data, _ := c.Read()
	proj := data["/proj"].(map[string]any)
	if proj["vcs"] != "git" {
		t.Fatalf("vcs not refreshed, got %v", proj["vcs"])
	}
	wr := proj["workrooms"].(map[string]any)
	if _, ok := wr["foo"]; !ok {
		t.Fatal("AddProject clobbered existing workrooms")
	}

	// A brand-new project registers with an empty workrooms map.
	if err := c.AddProject("/fresh", "jj"); err != nil {
		t.Fatal(err)
	}
	data, _ = c.Read()
	fresh := data["/fresh"].(map[string]any)
	if m, ok := fresh["workrooms"].(map[string]any); !ok || len(m) != 0 {
		t.Fatalf("expected empty workrooms map, got %v", fresh["workrooms"])
	}
}

func TestAllProjectsIncludesEmptyAndSkipsScalars(t *testing.T) {
	c := newTestConfig(t)
	if err := c.SetWorkroomsDir("/somewhere"); err != nil { // scalar top-level key
		t.Fatal(err)
	}
	if err := c.AddProject("/empty", "git"); err != nil {
		t.Fatal(err)
	}
	if err := c.AddWorkroom("/full", "x", "/wr/x", "jj"); err != nil {
		t.Fatal(err)
	}

	all, err := c.AllProjects()
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 2 {
		t.Fatalf("expected 2 projects (empty+full), got %d: %v", len(all), all)
	}
	if _, ok := all["/empty"]; !ok {
		t.Fatal("AllProjects dropped the empty project")
	}
	if _, ok := all["workrooms_dir"]; ok {
		t.Fatal("AllProjects leaked the workrooms_dir scalar as a project")
	}

	// ProjectsWithWorkrooms still excludes the empty project (CLI unchanged).
	withWr, err := c.ProjectsWithWorkrooms()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := withWr["/empty"]; ok {
		t.Fatal("ProjectsWithWorkrooms should exclude empty projects")
	}
}

func TestAllProjectsHandlesMissingWorkroomsKey(t *testing.T) {
	c := newTestConfig(t)
	if err := c.Write(map[string]any{"/proj": map[string]any{"vcs": "git"}}); err != nil {
		t.Fatal(err)
	}
	all, err := c.AllProjects()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := all["/proj"]; !ok {
		t.Fatal("AllProjects dropped a project that lacks a workrooms key")
	}
}

func TestRemoveWorkroomKeepProject(t *testing.T) {
	c := newTestConfig(t)
	if err := c.AddWorkroom("/proj", "foo", "/wr/foo", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.RemoveWorkroomKeepProject("/proj", "foo"); err != nil {
		t.Fatal(err)
	}
	data, _ := c.Read()
	proj, ok := data["/proj"].(map[string]any)
	if !ok {
		t.Fatal("RemoveWorkroomKeepProject removed the project; expected it kept")
	}
	if wr := proj["workrooms"].(map[string]any); len(wr) != 0 {
		t.Fatalf("expected 0 workrooms, got %d", len(wr))
	}

	// Contrast: plain RemoveWorkroom deletes the now-empty project.
	if err := c.AddWorkroom("/p2", "bar", "/wr/bar", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.RemoveWorkroom("/p2", "bar"); err != nil {
		t.Fatal(err)
	}
	data, _ = c.Read()
	if _, ok := data["/p2"]; ok {
		t.Fatal("RemoveWorkroom should delete an emptied project")
	}
}

func TestRemoveProjectRemovesEntryAndKeepsSiblings(t *testing.T) {
	c := newTestConfig(t)
	if err := c.AddWorkroom("/proj", "foo", "/wr/foo", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.AddWorkroom("/proj", "bar", "/wr/bar", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.AddProject("/other", "git"); err != nil {
		t.Fatal(err)
	}

	if err := c.RemoveProject("/proj"); err != nil {
		t.Fatal(err)
	}

	data, _ := c.Read()
	if _, ok := data["/proj"]; ok {
		t.Fatal("RemoveProject left the project (and its workrooms) in config")
	}
	if _, ok := data["/other"]; !ok {
		t.Fatal("RemoveProject deleted an unrelated sibling project")
	}
}

func TestRemoveProjectAbsentIsNoOp(t *testing.T) {
	c := newTestConfig(t)
	if err := c.AddProject("/keep", "git"); err != nil {
		t.Fatal(err)
	}
	if err := c.RemoveProject("/nonexistent"); err != nil {
		t.Fatalf("removing an absent project should be a nil no-op, got %v", err)
	}
	data, _ := c.Read()
	if _, ok := data["/keep"]; !ok {
		t.Fatal("RemoveProject of an absent path disturbed an existing project")
	}
}

func TestRemoveProjectRefusesReservedKey(t *testing.T) {
	c := newTestConfig(t)
	if err := c.SetWorkroomsDir("/somewhere"); err != nil {
		t.Fatal(err)
	}
	if err := c.RemoveProject("workrooms_dir"); err != nil {
		t.Fatalf("RemoveProject of the reserved key should be a nil no-op, got %v", err)
	}
	data, _ := c.Read()
	if data["workrooms_dir"] != "/somewhere" {
		t.Fatalf("RemoveProject deleted the reserved workrooms_dir key: %v", data)
	}
}

func TestWorkroomNames(t *testing.T) {
	c := newTestConfig(t)
	if err := c.AddWorkroom("/proj", "zebra", "/wr/zebra", "jj"); err != nil {
		t.Fatal(err)
	}
	if err := c.AddWorkroom("/proj", "alpha", "/wr/alpha", "jj"); err != nil {
		t.Fatal(err)
	}

	names, err := c.WorkroomNames("/proj")
	if err != nil {
		t.Fatal(err)
	}
	if len(names) != 2 || names[0] != "alpha" || names[1] != "zebra" {
		t.Fatalf("expected sorted [alpha zebra], got %v", names)
	}

	// Unknown project and the reserved key both yield an empty (non-nil) slice.
	empty, err := c.WorkroomNames("/unknown")
	if err != nil {
		t.Fatal(err)
	}
	if len(empty) != 0 {
		t.Fatalf("expected empty slice for unknown project, got %v", empty)
	}
	if err := c.SetWorkroomsDir("/x"); err != nil {
		t.Fatal(err)
	}
	reserved, err := c.WorkroomNames("workrooms_dir")
	if err != nil {
		t.Fatal(err)
	}
	if len(reserved) != 0 {
		t.Fatalf("expected empty slice for reserved key, got %v", reserved)
	}
}

func TestWriteAtomicLeavesNoTempFiles(t *testing.T) {
	c := newTestConfig(t)
	in := map[string]any{
		"workrooms_dir": "/x",
		"/p":            map[string]any{"vcs": "git", "workrooms": map[string]any{}},
	}
	if err := c.Write(in); err != nil {
		t.Fatal(err)
	}
	out, err := c.Read()
	if err != nil {
		t.Fatal(err)
	}
	if out["workrooms_dir"] != "/x" {
		t.Fatalf("atomic write round-trip mismatch: %v", out)
	}

	// Exercise the lock path and confirm no temp-write artifacts are left behind.
	// The ".lock" sidecar itself is expected to persist across calls — it's a
	// real OS advisory lock (flock), not a create-then-delete marker file, so
	// its file staying on disk between calls is correct, not a leak.
	if err := c.AddProject("/p", "git"); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(filepath.Dir(c.Path()))
	for _, e := range entries {
		n := e.Name()
		if strings.HasPrefix(n, ".config-") {
			t.Fatalf("leftover temp file after write: %s", n)
		}
	}
}
