package cmd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// createEvents is the NDJSON step and log events create --json streams on stderr, in order.
func createEvents(t *testing.T, project string) []map[string]any {
	t.Helper()
	run := runCLI(t, "create", "--json", "--no-editor", "--project", project)
	var events []map[string]any
	for _, line := range strings.Split(string(run.stderr), "\n") {
		var e map[string]any
		if json.Unmarshal([]byte(line), &e) == nil && (e["type"] == "step" || e["type"] == "log") {
			events = append(events, e)
		}
	}
	return events
}

// steps flattens the step events to "id:state", plus ":detail" when there is one.
func steps(events []map[string]any) []string {
	var out []string
	for _, e := range events {
		if e["type"] != "step" {
			continue
		}
		s := e["id"].(string) + ":" + e["state"].(string)
		if d, ok := e["detail"].(string); ok {
			s += ":" + d
		}
		out = append(out, s)
	}
	return out
}

func noRemoteProject(t *testing.T) string {
	t.Helper()
	project := unreachableOriginProject(t)
	if out, err := exec.Command("git", "-C", project, "remote", "remove", "origin").CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	return project
}

// writeSetup writes the root's setup script, approved to run.
func writeSetup(t *testing.T, project, body string) {
	t.Helper()
	writeScriptFile(t, project, "workroom_setup", body)
	approveForTest(t, project, "workroom_setup", body)
}

func assertSteps(t *testing.T, events []map[string]any, want ...string) {
	t.Helper()
	if got := strings.Join(steps(events), " | "); got != strings.Join(want, " | ") {
		t.Fatalf("steps = %s\nwant    %s", got, strings.Join(want, " | "))
	}
}

// writeRootFile writes path, relative to the project's root, with body.
func writeRootFile(t *testing.T, project, path, body string) {
	t.Helper()
	full := filepath.Join(project, path)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// Value: protects=the root's included files are in the new workroom before its setup script runs,
// and the include step and its log sit between worktree and script; fails_when=the copy runs after
// the script, or the step or its log is missing; no_claim=the remote path
func TestCreateStepsCopyIncludedFilesBeforeTheSetupScript(t *testing.T) {
	project := noRemoteProject(t)
	writeRootFile(t, project, ".gitignore", ".env\n")
	writeRootFile(t, project, ".env", "SECRET=1")
	writeRootFile(t, project, ".worktreeinclude", ".env\n")
	writeSetup(t, project, "#!/bin/sh\ncat .env\n")
	events := createEvents(t, project)
	assertSteps(t, events, "fetch:skipped:No remote to fetch from", "worktree:running", "worktree:done",
		"include:running", "include:done", "script:running", "script:done")
	var copied, read bool
	for _, e := range events {
		copied = copied || (e["type"] == "log" && e["step"] == "include" && e["text"] == "Copied .env")
		read = read || (e["type"] == "log" && e["step"] == "script" && e["text"] == "SECRET=1")
	}
	if !copied || !read {
		t.Fatalf("include log has Copied .env (%v), setup read the file (%v): %v", copied, read, events)
	}
}

// Value: protects=an include file that matches nothing ends the step skipped with its reason;
// fails_when=it ends done, or the row has no reason; no_claim=none beyond protects
func TestCreateStepsIncludeFileThatMatchesNothing(t *testing.T) {
	project := noRemoteProject(t)
	writeRootFile(t, project, ".worktreeinclude", ".env\n")
	assertSteps(t, createEvents(t, project), "fetch:skipped:No remote to fetch from",
		"worktree:running", "worktree:done", "include:running", "include:skipped:No matching files",
		"script:skipped:No setup script")
}

// Value: protects=a symlinked .env, the only match, is named as skipped, in the log and in the
// step's reason (a skipped row's log can't be opened); fails_when=the skip is silent, unnamed, or
// reads "No matching files"; no_claim=the remote path (RemoteIncludeTests)
func TestCreateStepsOnlySymlinksMatched(t *testing.T) {
	project := noRemoteProject(t)
	writeRootFile(t, project, ".gitignore", ".env\nshared.env\n")
	writeRootFile(t, project, "shared.env", "SECRET=1")
	writeRootFile(t, project, ".worktreeinclude", ".env\n")
	if err := os.Symlink(filepath.Join(project, "shared.env"), filepath.Join(project, ".env")); err != nil {
		t.Fatal(err)
	}
	events := createEvents(t, project)
	assertSteps(t, events, "fetch:skipped:No remote to fetch from", "worktree:running", "worktree:done",
		"include:running", "include:skipped:Only symlinks matched: .env", "script:skipped:No setup script")
	for _, e := range events {
		if e["type"] == "log" && e["step"] == "include" && e["text"] == "Skipped .env: it's a symlink" {
			return
		}
	}
	t.Fatalf("no log line naming the skipped symlink: %v", events)
}

// Value: protects=an unreadable included file ends the step as a warning naming it, and the
// create carries on to the setup script; fails_when=the copy fails the create, or the warning
// doesn't name the file; no_claim=the warning's exact wording past the file name
func TestCreateStepsUnreadableIncludedFileWarns(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-000 file")
	}
	project := noRemoteProject(t)
	writeRootFile(t, project, ".gitignore", "*.key\n")
	writeRootFile(t, project, "master.key", "k")
	writeRootFile(t, project, ".worktreeinclude", "*.key\n")
	if err := os.Chmod(filepath.Join(project, "master.key"), 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(project, "master.key"), 0o644) })
	writeSetup(t, project, "#!/bin/sh\necho ran\n")
	got := steps(createEvents(t, project))
	if len(got) != 7 || !strings.HasPrefix(got[4], "include:warning:") || !strings.Contains(got[4], "master.key") ||
		got[5] != "script:running" || got[6] != "script:done" {
		t.Fatalf("steps = %v, want include to warn naming master.key, then the script to run", got)
	}
}
