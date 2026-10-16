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

func writeSetup(t *testing.T, project, body string) {
	t.Helper()
	scripts := filepath.Join(project, "scripts")
	if err := os.MkdirAll(scripts, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scripts, "workroom_setup"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
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
