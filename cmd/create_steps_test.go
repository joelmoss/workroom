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

// Value: protects=create --json streams the local plan's step events in order, with fetch and
// script skipped and their reasons as detail; fails_when=a step is missing, out of order, or
// skipped without its reason; no_claim=a real remote or setup script (the project has neither)
func TestCreateStepsWithNoRemoteAndNoScript(t *testing.T) {
	assertSteps(t, createEvents(t, noRemoteProject(t)),
		"fetch:skipped:No remote to fetch from",
		"worktree:running", "worktree:done",
		"script:skipped:No setup script")
}

// Value: protects=a setup script's output arrives as log events tagged step script;
// fails_when=the line is untagged or tagged with an earlier step; no_claim=fetch and worktree log
// tagging (no remote here), and the app's routing of untagged lines
func TestCreateStepsTagLogsWithTheRunningStep(t *testing.T) {
	project := noRemoteProject(t)
	writeSetup(t, project, "#!/bin/sh\necho hello\n")
	events := createEvents(t, project)
	assertSteps(t, events, "fetch:skipped:No remote to fetch from", "worktree:running", "worktree:done", "script:running", "script:done")
	for _, e := range events {
		if e["type"] == "log" && e["text"] == "hello" && e["step"] == "script" {
			return
		}
	}
	t.Fatalf("no log line 'hello' tagged step script: %v", events)
}

// Value: protects=an unreachable origin ends fetch as a warning with the CLI's text, and its log
// holds the git fetch command line and git's stderr; fails_when=fetch ends done or failed, or the
// log lacks the command or the error; no_claim=a fetch that works (a missing local path stands in
// for an unreachable host)
func TestCreateStepsFailedFetchWarnsAndLogsStderr(t *testing.T) {
	events := createEvents(t, unreachableOriginProject(t))
	got := steps(events)
	if len(got) < 2 || got[0] != "fetch:running" || !strings.HasPrefix(got[1], "fetch:warning:Could not fetch origin") {
		t.Fatalf("steps = %v, want fetch running then a fetch warning", got)
	}
	var cmdLine, stderr bool
	for _, e := range events {
		if e["type"] != "log" || e["step"] != "fetch" {
			continue
		}
		text, _ := e["text"].(string)
		cmdLine = cmdLine || strings.HasPrefix(text, "$ git fetch")
		stderr = stderr || strings.Contains(text, "gone.git")
	}
	if !cmdLine || !stderr {
		t.Fatalf("fetch log lacks the command line (%v) or its stderr (%v): %v", cmdLine, stderr, events)
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

// Value: protects=a setup script that exits non-zero ends script as failed with the error as
// detail, after fetch and worktree; fails_when=script ends done, or the failure has no detail;
// no_claim=the failure's wording, or the created event the app reads alongside it
func TestCreateStepsFailedSetupScript(t *testing.T) {
	project := noRemoteProject(t)
	writeSetup(t, project, "#!/bin/sh\nexit 1\n")
	got := steps(createEvents(t, project))
	want := []string{"fetch:skipped:No remote to fetch from", "worktree:running", "worktree:done", "script:running"}
	if len(got) != 5 || strings.Join(got[:4], "|") != strings.Join(want, "|") || !strings.HasPrefix(got[4], "script:failed:") {
		t.Fatalf("steps = %v, want %v then script:failed with the error", got, want)
	}
}
