package cmd

import (
	"encoding/json"
	"io"
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

// create's JSON carries the fetch warning: in the success payload, and in the error's `created`
// block when setup fails too, for --json callers. The app reads it from the stderr event (below).
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

// The app takes the warning from the stderr "created" event, which arrives before setup runs, so
// a setup script that then fails cannot lose it.
func TestCreateEventCarriesTheFetchWarning(t *testing.T) {
	project := unreachableOriginProject(t)
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stderr := os.Stderr
	os.Stderr = write
	runHostCLI(t, "create", "--json", "--no-editor", "--project", project)
	os.Stderr = stderr
	write.Close()
	events, _ := io.ReadAll(read)
	for _, line := range strings.Split(string(events), "\n") {
		var event map[string]any
		if json.Unmarshal([]byte(line), &event) == nil && event["type"] == "created" {
			if warning, _ := event["warning"].(string); !strings.Contains(warning, "Could not fetch origin") {
				t.Fatalf("created event = %v, want the fetch warning", event)
			}
			return
		}
	}
	t.Fatalf("no created event on stderr: %q", events)
}
