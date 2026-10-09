package cmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
)

// A project whose origin cannot be reached, registered in a fresh HOME.
func unreachableOriginProject(t *testing.T) string {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	project := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q"},
		{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "first"},
		{"remote", "add", "origin", filepath.Join(t.TempDir(), "gone.git")},
	} {
		if out, err := exec.Command("git", append([]string{"-C", project}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	canon, _ := config.CanonicalPath(project)
	if err := cfg.AddProject(canon, "git"); err != nil {
		t.Fatal(err)
	}
	// cobra keeps flag values, and Changed, between runs: another test's --host would make this
	// a remote create.
	reset := func() {
		createProject, createNoEditor, createHost, createHostPath = "", false, "", ""
		createCmd.Flags().Lookup("host").Changed = false
	}
	reset()
	t.Cleanup(reset)
	return project
}

// The app reads the fetch warning from create's JSON: on success, and in the error's `created`
// block when setup fails too.
func TestCreateJSONCarriesTheFetchWarning(t *testing.T) {
	project := unreachableOriginProject(t)
	code, envelope := runHostCLI(t, "create", "--json", "--no-editor", "--project", project)
	if warning, _ := envelope["warning"].(string); code != 0 || !strings.Contains(warning, "Could not fetch origin") {
		t.Fatalf("create: exit %d, %v; want a fetch warning", code, envelope)
	}

	scripts := filepath.Join(project, "scripts")
	if err := os.MkdirAll(scripts, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scripts, "workroom_setup"), []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	code, envelope = runHostCLI(t, "create", "--json", "--no-editor", "--project", project)
	created, _ := envelope["created"].(map[string]any)
	if warning, _ := created["warning"].(string); code == 0 || !strings.Contains(warning, "Could not fetch origin") {
		t.Fatalf("failed setup: exit %d, %v; want the warning in created", code, envelope)
	}
}
