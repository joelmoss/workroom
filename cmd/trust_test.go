package cmd

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
)

// commitScript writes scripts/<name> in project with body and commits it, so the base commit
// ships it.
func commitScript(t *testing.T, project, name, body string) {
	t.Helper()
	writeScriptFile(t, project, name, "#!/bin/sh\n"+body)
	run(t, project, "git", "add", "scripts/"+name)
	run(t, project, "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "add "+name)
}

func digest(body string) string {
	sum := sha256.Sum256([]byte("#!/bin/sh\n" + body))
	return hex.EncodeToString(sum[:])
}

// trustProject is a registered project with no remote whose base commit ships a setup script.
func trustProject(t *testing.T, setup string) (home, project string) {
	t.Helper()
	home = contractHomeDir(t)
	project = gitRepo(t, filepath.Join(home, "src", "app"))
	commitScript(t, project, "workroom_setup", setup)
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(project, "git"); err != nil {
		t.Fatal(err)
	}
	return home, project
}

type untrustedEnvelope struct {
	OK    bool `json:"ok"`
	Error struct {
		Kind string `json:"kind"`
	} `json:"error"`
	Script struct {
		Name   string `json:"name"`
		Origin string `json:"origin"`
		SHA256 string `json:"sha256"`
		Text   string `json:"text"`
	} `json:"script"`
	Created map[string]any `json:"created"`
}

func decodeUntrusted(t *testing.T, stdout []byte) untrustedEnvelope {
	t.Helper()
	var env untrustedEnvelope
	if err := json.Unmarshal(stdout, &env); err != nil {
		t.Fatalf("not one JSON envelope: %q", stdout)
	}
	return env
}

// A create whose base commit ships an unapproved setup script creates nothing and says which
// script, from where, with its digest and text.
func TestCreateRefusesAnUntrustedSetupScriptBeforeAnythingExists(t *testing.T) {
	home, project := trustProject(t, "echo hi\n")

	run := runCLI(t, "create", "--json", "--no-editor", "--project", project)
	if run.code != 3 {
		t.Fatalf("exit %d, want 3: %s", run.code, run.stdout)
	}
	env := decodeUntrusted(t, run.stdout)
	if env.Error.Kind != "ScriptNotTrusted" || env.Created != nil {
		t.Fatalf("envelope = %s", run.stdout)
	}
	if env.Script.Name != "workroom_setup" || env.Script.Origin != "base" ||
		env.Script.SHA256 != digest("echo hi\n") || env.Script.Text != "#!/bin/sh\necho hi\n" {
		t.Fatalf("script = %+v", env.Script)
	}
	if entries, _ := os.ReadDir(filepath.Join(home, "workrooms")); len(entries) != 0 {
		t.Fatalf("workrooms dir has %v, want nothing created", entries)
	}
	names, err := mustConfig(t).WorkroomNames(project)
	if err != nil || len(names) != 0 {
		t.Fatalf("workrooms registered = %v (%v), want none", names, err)
	}
}

// asTerminal makes the CLI see a terminal on stdin, answering each confirmation with answer.
func asTerminal(t *testing.T, answer bool) *[]string {
	t.Helper()
	var asked []string
	savedTerm, savedConfirm := stdinIsTerminal, askConfirm
	stdinIsTerminal = func() bool { return true }
	askConfirm = func(msg string) (bool, error) { asked = append(asked, msg); return answer, nil }
	t.Cleanup(func() { stdinIsTerminal, askConfirm = savedTerm, savedConfirm })
	t.Setenv("EDITOR", "")
	return &asked
}

// In a terminal, create shows the unapproved script and asks; yes records its digest and creates.
func TestCreateInATerminalApprovesTheScriptAndRunsIt(t *testing.T) {
	_, project := trustProject(t, "echo hi\n")
	asked := asTerminal(t, true)

	run := runCLI(t, "create", "--project", project)
	if run.code != 0 {
		t.Fatalf("exit %d: %s %s", run.code, run.stdout, run.stderr)
	}
	if len(*asked) != 1 || !strings.Contains(string(run.stdout), "│ echo hi") {
		t.Fatalf("asked %v, stdout %s", *asked, run.stdout)
	}
	projects, _ := mustConfig(t).AllProjects()
	if got := projects[project].TrustedScripts["workroom_setup"]; got != digest("echo hi\n") {
		t.Fatalf("recorded %q", got)
	}
	if !strings.Contains(string(run.stdout), "│ hi") {
		t.Fatalf("setup did not run: %s", run.stdout)
	}
}

// No ends the create as cancelled, with nothing created and nothing recorded.
func TestCreateInATerminalDeclinedCreatesNothing(t *testing.T) {
	home, project := trustProject(t, "echo hi\n")
	asTerminal(t, false)

	run := runCLI(t, "create", "--project", project)
	if run.code != 4 {
		t.Fatalf("exit %d, want 4: %s %s", run.code, run.stdout, run.stderr)
	}
	if entries, _ := os.ReadDir(filepath.Join(home, "workrooms")); len(entries) != 0 {
		t.Fatalf("workrooms dir has %v", entries)
	}
	projects, _ := mustConfig(t).AllProjects()
	if len(projects[project].TrustedScripts) != 0 || len(projects[project].Workrooms) != 0 {
		t.Fatalf("project = %+v", projects[project])
	}
}

type statusEnvelope struct {
	OK      bool `json:"ok"`
	Trusted bool `json:"trusted"`
	Scripts []struct {
		Name    string `json:"name"`
		Origin  string `json:"origin"`
		SHA256  string `json:"sha256"`
		Trusted bool   `json:"trusted"`
		Exempt  bool   `json:"exempt"`
	} `json:"scripts"`
	Error struct {
		Kind string `json:"kind"`
	} `json:"error"`
}

func trustStatus(t *testing.T, project string, args ...string) (int, statusEnvelope) {
	t.Helper()
	run := runCLI(t, append([]string{"trust", "status", "--json", "--project", project}, args...)...)
	var env statusEnvelope
	if err := json.Unmarshal(run.stdout, &env); err != nil {
		t.Fatalf("not one JSON envelope: %q", run.stdout)
	}
	return run.code, env
}

// `workroom trust` approves what a create would run, after which it runs without asking; one
// changed byte makes it untrusted again. `untrust` forgets it.
func TestTrustApprovesUntilTheScriptChanges(t *testing.T) {
	_, project := trustProject(t, "echo hi\n")
	if code, env := trustStatus(t, project); code != 1 || env.Trusted || len(env.Scripts) != 1 ||
		env.Scripts[0].Name != "workroom_setup" || env.Scripts[0].Origin != "base" || env.Scripts[0].Trusted {
		t.Fatalf("before trust: exit %d, %+v", code, env)
	}

	if run := runCLI(t, "trust", "--project", project); run.code != 0 {
		t.Fatalf("trust: exit %d %s %s", run.code, run.stdout, run.stderr)
	}
	if code, env := trustStatus(t, project); code != 0 || !env.Trusted || env.Scripts[0].SHA256 != digest("echo hi\n") {
		t.Fatalf("after trust: exit %d, %+v", code, env)
	}
	if run := runCLI(t, "create", "--json", "--no-editor", "--project", project); run.code != 0 {
		t.Fatalf("create after trust: exit %d %s", run.code, run.stdout)
	}

	commitScript(t, project, "workroom_setup", "echo hi!\n")
	if run := runCLI(t, "create", "--json", "--no-editor", "--project", project); run.code != 3 {
		t.Fatalf("create after a change: exit %d %s", run.code, run.stdout)
	}

	if run := runCLI(t, "trust", "--project", project); run.code != 0 {
		t.Fatal(run.code)
	}
	if run := runCLI(t, "untrust", "--project", project); run.code != 0 {
		t.Fatalf("untrust: exit %d %s", run.code, run.stdout)
	}
	if code, _ := trustStatus(t, project); code != 1 {
		t.Fatalf("after untrust: exit %d", code)
	}
}

// A root copy git ignores runs without approval and reports exempt; an untracked one that is not
// ignored needs approval.
func TestAGitignoredRootScriptIsExempt(t *testing.T) {
	home := contractHomeDir(t)
	project := gitRepo(t, filepath.Join(home, "src", "app"))
	writeScriptFile(t, project, "workroom_setup", "#!/bin/sh\necho local\n")
	if run := runCLI(t, "create", "--json", "--no-editor", "--project", project); run.code != 3 {
		t.Fatalf("untracked, not ignored: exit %d %s", run.code, run.stdout)
	}

	writeRootFile(t, project, ".gitignore", "scripts/workroom_setup\n")
	code, env := trustStatus(t, project)
	if code != 0 || len(env.Scripts) != 1 || env.Scripts[0].Origin != "root" || !env.Scripts[0].Exempt {
		t.Fatalf("ignored: exit %d, %+v", code, env)
	}
	if run := runCLI(t, "create", "--json", "--no-editor", "--project", project); run.code != 0 {
		t.Fatalf("ignored create: exit %d %s", run.code, run.stdout)
	}
}

// A setup script only the base commit has is judged by its bytes there, not the root's.
func TestTheBaseCommitsSetupScriptIsJudgedNotTheRoots(t *testing.T) {
	_, project := trustProject(t, "echo base\n")
	// The root moves back to a commit without it and keeps an older, approved copy of its own.
	run(t, project, "git", "checkout", "-q", "-b", "old", "HEAD~1")
	writeProjectScript(t, project, "workroom_setup", "echo old\n")
	if err := mustConfig(t).SetTrustedScript(project, "workroom_setup", digest("echo old\n")); err != nil {
		t.Fatal(err)
	}
	if err := mustConfig(t).SetBaseBranch(project, "main"); err != nil {
		t.Fatal(err)
	}
	r := runCLI(t, "create", "--json", "--no-editor", "--project", project)
	if env := decodeUntrusted(t, r.stdout); r.code != 3 || env.Script.Origin != "base" || env.Script.SHA256 != digest("echo base\n") {
		t.Fatalf("exit %d %s", r.code, r.stdout)
	}
}

// trust status says it cannot tell (exit 2) when the base resolves nowhere.
func TestTrustStatusCannotTellWithoutABase(t *testing.T) {
	_, project := trustProject(t, "echo hi\n")
	if err := mustConfig(t).SetBaseBranch(project, "nowhere"); err != nil {
		t.Fatal(err)
	}
	if code, env := trustStatus(t, project); code != 2 || env.OK || env.Error.Kind != "BaseBranchNotFound" {
		t.Fatalf("exit %d, %+v", code, env)
	}
	if run := runCLI(t, "trust", "--project", project); run.code == 0 {
		t.Fatal("trust approved without a base")
	}
}

// With --stdin, trust status judges and trust records the bytes given, reading no file.
func TestTrustTakesAScriptsBytesOnStdin(t *testing.T) {
	_, project := trustProject(t, "echo hi\n")
	body := "#!/bin/sh\necho host\n"
	withStdin(t, body)
	if code, env := trustStatus(t, project, "--stdin", "workroom_teardown"); code != 1 || len(env.Scripts) != 1 ||
		env.Scripts[0].Name != "workroom_teardown" || env.Scripts[0].Origin != "stdin" || env.Scripts[0].SHA256 != digest("echo host\n") {
		t.Fatalf("status: exit %d, %+v", code, env)
	}
	withStdin(t, body)
	if run := runCLI(t, "trust", "--json", "--project", project, "--stdin", "workroom_teardown"); run.code != 0 {
		t.Fatalf("trust: exit %d %s", run.code, run.stdout)
	}
	projects, _ := mustConfig(t).AllProjects()
	if got := projects[project].TrustedScripts; got["workroom_teardown"] != digest("echo host\n") || got["workroom_setup"] != "" {
		t.Fatalf("recorded %v", got)
	}
	withStdin(t, body)
	if code, _ := trustStatus(t, project, "--stdin", "workroom_teardown"); code != 0 {
		t.Fatalf("status after trust: exit %d", code)
	}
}

// An unapproved teardown stops the delete with nothing removed; --skip-teardown deletes without it.
func TestDeleteRefusesAnUntrustedTeardownScript(t *testing.T) {
	home := contractHomeDir(t)
	project := projectWithWorkroom(t, home)
	path := filepath.Join(home, "workrooms", contractName)
	writeScriptFile(t, project, "workroom_teardown", "#!/bin/sh\necho changed\n")

	r := runCLI(t, "delete", contractName, "--json", "--project", project, "--confirm", contractName)
	env := decodeUntrusted(t, r.stdout)
	if r.code != 3 || env.Error.Kind != "ScriptNotTrusted" || env.Script.Name != "workroom_teardown" || env.Script.Origin != "root" {
		t.Fatalf("exit %d %s", r.code, r.stdout)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the workroom went: %v", err)
	}
	if names, _ := mustConfig(t).WorkroomNames(project); len(names) != 1 {
		t.Fatalf("workrooms = %v", names)
	}

	r = runCLI(t, "delete", contractName, "--json", "--project", project, "--confirm", contractName, "--skip-teardown")
	if r.code != 0 {
		t.Fatalf("--skip-teardown: exit %d %s", r.code, r.stdout)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("the workroom is still there: %v", err)
	}
}

// Removing a project removes its approvals, so a project added again asks again.
func TestRemovingAProjectForgetsItsApprovals(t *testing.T) {
	_, project := trustProject(t, "echo hi\n")
	if run := runCLI(t, "trust", "--project", project); run.code != 0 {
		t.Fatal(run.code)
	}
	if run := runCLI(t, "delete-project", project, "--json", "--confirm", project); run.code != 0 {
		t.Fatalf("delete-project: exit %d %s", run.code, run.stdout)
	}
	if run := runCLI(t, "add-project", project, "--json"); run.code != 0 {
		t.Fatalf("add-project: exit %d %s", run.code, run.stdout)
	}
	if code, _ := trustStatus(t, project); code != 1 {
		t.Fatalf("status after re-adding: exit %d", code)
	}
}

// withStdin gives the next CLI run body on stdin.
func withStdin(t *testing.T, body string) {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "stdin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(body); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	saved := os.Stdin
	os.Stdin = f
	t.Cleanup(func() { os.Stdin = saved; _ = f.Close() })
}

func mustConfig(t *testing.T) *config.Config {
	t.Helper()
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}
