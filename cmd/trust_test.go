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
	"github.com/joelmoss/workroom/internal/ui"
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

// trust names each script it recorded, and each one the project has none of.
func TestTrustReportsWhatItRecordedAndWhatIsAbsent(t *testing.T) {
	_, project := trustProject(t, "echo hi\n")
	r := runCLI(t, "trust", "--project", project)
	want := ui.Green("Approved scripts/workroom_setup from the base commit.") + "\nNo scripts/workroom_teardown.\n"
	if r.code != 0 || string(r.stdout) != want {
		t.Fatalf("exit %d, stdout %q, want %q", r.code, r.stdout, want)
	}
}

// Value: protects=`workroom trust` run in one of a project's workrooms (where every app terminal
// opens) approves for that project, so its next create runs; fails_when=the workroom's path is
// judged and registered as a project of its own; why_new=found by /ship's red team; seam=none;
// no_claim=untrust and trust status share trustedProject and are not run here
func TestTrustInAWorkroomApprovesForItsProject(t *testing.T) {
	home, project := trustProject(t, "echo hi\n")
	wr := filepath.Join(home, "workrooms", "wr")
	run(t, project, "git", "worktree", "add", "-q", "-b", "workroom/wr", wr)
	if err := mustConfig(t).AddWorkroom(project, "wr", wr, "git"); err != nil {
		t.Fatal(err)
	}
	t.Chdir(wr)

	if r := runCLI(t, "trust"); r.code != 0 {
		t.Fatalf("trust in a workroom: exit %d %s %s", r.code, r.stdout, r.stderr)
	}
	projects, _ := mustConfig(t).AllProjects()
	if _, ok := projects[wr]; ok {
		t.Fatalf("the workroom was registered as a project: %v", projects)
	}
	if code, _ := trustStatus(t, project); code != 0 {
		t.Fatalf("the project's script is not approved: exit %d", code)
	}
}

// Value: protects=the terminal shows a script's escape sequences, carriage returns and invisible
// characters as text, so a script cannot hide what it runs from the person approving it;
// fails_when=raw control or format characters reach the terminal; why_new=found by /ship's
// security review; seam=none; no_claim=how a particular terminal would have drawn them
func TestTheApprovalPromptShowsWhatTheTerminalWouldHide(t *testing.T) {
	// A bidi override (U+202E) and a zero-width space (U+200B), built so the source shows them.
	format := string(rune(0x202e)) + string(rune(0x200b))
	got := visibleText([]byte("echo safe\x1b[1A\x1b[2K\rrm -rf x" + format + "\xff\n\tok\n"))
	want := `echo safe\u{001b}[1A\u{001b}[2K\u{000d}rm -rf x\u{202e}\u{200b}\xff` + "\n\tok\n"
	if got != want {
		t.Fatalf("visibleText = %q\nwant %q", got, want)
	}
}

// Value: protects=plain `trust status` names each script's state and the one the project lacks,
// and exits 1 while one is not approved; fails_when=the human output or its exit drifts from the
// --json path; why_new=every other status test passes --json; seam=none; no_claim=colour
func TestTrustStatusInPlainText(t *testing.T) {
	_, project := trustProject(t, "echo hi\n")
	r := runCLI(t, "trust", "status", "--project", project)
	want := "scripts/workroom_setup from the base commit: " + ui.Red("not approved") + "\nNo scripts/workroom_teardown.\n"
	if r.code != 1 || string(r.stdout) != want {
		t.Fatalf("exit %d, stdout %q, want 1 and %q", r.code, r.stdout, want)
	}
}

// Value: protects=a committed symlinked setup script, once approved by `workroom trust`, runs on
// create; fails_when=the early check approves the link's text while the run-time check hashes the
// target, refusing every create after its worktree exists; why_new=reproduced by /ship's QA probe;
// seam=none; no_claim=a link pointing outside the repository
func TestAnApprovedSymlinkedSetupScriptRuns(t *testing.T) {
	_, project := trustProject(t, "echo hi\n")
	writeScriptFile(t, project, "real.sh", "#!/bin/sh\necho real-ran\n")
	link := filepath.Join(project, "scripts", "workroom_setup")
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("real.sh", link); err != nil {
		t.Fatal(err)
	}
	run(t, project, "git", "add", "-A")
	run(t, project, "git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "link")

	if r := runCLI(t, "trust", "--project", project); r.code != 0 {
		t.Fatalf("trust: exit %d %s", r.code, r.stdout)
	}
	if r := runCLI(t, "create", "--json", "--no-editor", "--project", project); r.code != 0 {
		t.Fatalf("create after approving a symlinked script: exit %d %s", r.code, r.stdout)
	}
}

// Value: protects=`trust status --base` judges the setup script at the branch a remote create
// checks out, not the project's own base; fails_when=--base is ignored and the project's base is
// judged (an approval that the host then refuses, after a paid machine is made); why_new=found by
// Codex on PR #510; seam=none; no_claim=a real origin (a local branch stands in for it)
func TestTrustStatusJudgesTheBaseItIsGiven(t *testing.T) {
	_, project := trustProject(t, "echo main\n")
	run(t, project, "git", "checkout", "-q", "-b", "other")
	commitScript(t, project, "workroom_setup", "echo other\n")
	if err := mustConfig(t).SetBaseBranch(project, "other"); err != nil {
		t.Fatal(err)
	}

	if _, env := trustStatus(t, project); len(env.Scripts) != 1 || env.Scripts[0].SHA256 != digest("echo other\n") {
		t.Fatalf("project's base: %+v", env)
	}
	if _, env := trustStatus(t, project, "--base", "main"); len(env.Scripts) != 1 || env.Scripts[0].SHA256 != digest("echo main\n") {
		t.Fatalf("--base main: %+v", env)
	}
}

// Value: protects=a gitignored root setup script that is a symlink is not exempt, since what it
// points to may be tracked and changed by a pull; fails_when=the exemption follows the link and a
// pulled change runs unapproved; why_new=found by Codex's adversarial review; seam=none;
// no_claim=none beyond protects
func TestAnIgnoredSymlinkedRootScriptIsNotExempt(t *testing.T) {
	home := contractHomeDir(t)
	project := gitRepo(t, filepath.Join(home, "src", "app"))
	commitScript(t, project, "shared.sh", "echo shared\n")
	if err := os.Symlink("shared.sh", filepath.Join(project, "scripts", "workroom_setup")); err != nil {
		t.Fatal(err)
	}
	writeRootFile(t, project, ".gitignore", "scripts/workroom_setup\n")

	r := runCLI(t, "create", "--json", "--no-editor", "--project", project)
	if env := decodeUntrusted(t, r.stdout); r.code != 3 || env.Script.Origin != "root" {
		t.Fatalf("exit %d %s, want the linked root copy refused", r.code, r.stdout)
	}
}

// Value: protects=a script file that is not a regular file (a link to /dev/zero) is refused
// without being read; fails_when=the judge reads it without end; why_new=found by Codex's review;
// seam=none; no_claim=the app's bounded read on a host (RemoteScriptTests)
func TestADeviceScriptIsRefusedUnread(t *testing.T) {
	home := contractHomeDir(t)
	project := gitRepo(t, filepath.Join(home, "src", "app"))
	if err := os.MkdirAll(filepath.Join(project, "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/dev/zero", filepath.Join(project, "scripts", "workroom_setup")); err != nil {
		t.Fatal(err)
	}
	r := runCLI(t, "create", "--json", "--no-editor", "--project", project)
	if r.code != 3 || !strings.Contains(string(r.stdout), "not a regular file") {
		t.Fatalf("exit %d %s", r.code, r.stdout)
	}
}

// Value: protects=a committed setup script larger than a script may be is refused before anything
// exists, as the check before it runs would refuse it after; fails_when=the early check approves
// it and the create fails with its workroom (or a paid host) made; why_new=found by Codex and the
// delta review; seam=none; no_claim=none beyond protects
func TestAnOversizeBaseSetupScriptIsRefusedBeforeAnythingExists(t *testing.T) {
	home, project := trustProject(t, "echo hi\n")
	commitScript(t, project, "workroom_setup", strings.Repeat("#", 1<<20)+"\n")
	r := runCLI(t, "create", "--json", "--no-editor", "--project", project)
	if r.code != 3 || !strings.Contains(string(r.stdout), "larger than") {
		t.Fatalf("exit %d %.300s", r.code, r.stdout)
	}
	if entries, _ := os.ReadDir(filepath.Join(home, "workrooms")); len(entries) != 0 {
		t.Fatalf("workrooms dir has %v", entries)
	}
}

// Value: protects=bytes that change while the terminal prompt is open are not run on the strength
// of the approval given for what was shown; fails_when=the file is executed by path after
// recording the digest of the earlier bytes; why_new=found by Codex's adversarial review;
// seam=none; no_claim=a change in the instant between the last hash and exec
func TestAScriptChangedWhileThePromptIsOpenIsRefused(t *testing.T) {
	home := contractHomeDir(t)
	project := projectWithWorkroom(t, home)
	marker := filepath.Join(home, "ran")
	writeScriptFile(t, project, "workroom_teardown", "#!/bin/sh\necho shown\n")
	saved, savedTerm := askConfirm, stdinIsTerminal
	stdinIsTerminal = func() bool { return true }
	askConfirm = func(string) (bool, error) {
		writeScriptFile(t, project, "workroom_teardown", "#!/bin/sh\ntouch "+marker+"\n")
		return true, nil
	}
	t.Cleanup(func() { askConfirm, stdinIsTerminal = saved, savedTerm })

	r := runCLI(t, "delete", contractName, "--project", project, "--confirm", contractName)
	if r.code != 3 {
		t.Fatalf("exit %d %s %s", r.code, r.stdout, r.stderr)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("the replaced script ran")
	}
	if _, err := os.Stat(filepath.Join(home, "workrooms", contractName)); err != nil {
		t.Fatalf("the workroom went: %v", err)
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

// Value: protects=delete-project --from-disk and --with-workrooms refuse an unapproved teardown (exit 3) and keep the project and workroom; fails_when=either path runs the script unjudged or drops the project first; why_new=only delete is covered, and delete-project has two RunTeardown loops; seam=none; no_claim=remote hosts
func TestDeleteProjectRefusesAnUntrustedTeardownScript(t *testing.T) {
	for _, flag := range []string{"--from-disk", "--with-workrooms"} {
		t.Run(flag, func(t *testing.T) {
			home := contractHomeDir(t)
			project := projectWithWorkroom(t, home)
			marker := filepath.Join(home, "teardown-ran")
			writeScriptFile(t, project, "workroom_teardown", "#!/bin/sh\ntouch "+marker+"\n")

			r := runCLI(t, "delete-project", project, "--json", "--confirm", project, flag)
			env := decodeUntrusted(t, r.stdout)
			if r.code != 3 || env.Error.Kind != "ScriptNotTrusted" || env.Script.Name != "workroom_teardown" {
				t.Fatalf("exit %d %s", r.code, r.stdout)
			}
			if _, err := os.Stat(marker); err == nil {
				t.Fatal("the unapproved teardown ran")
			}
			projects, _ := mustConfig(t).AllProjects()
			if len(projects[project].Workrooms) != 1 {
				t.Fatalf("project = %+v", projects[project])
			}
			if _, err := os.Stat(filepath.Join(home, "workrooms", contractName)); err != nil {
				t.Fatalf("the workroom went: %v", err)
			}
		})
	}
}

// Value: protects=in a terminal, delete shows an unapproved teardown script and asks: yes records its digest and runs it, no ends the delete as cancelled (exit 4) with the workroom kept; fails_when=the teardown gate stops using the approval prompt or runs the script after a no; why_new=terminal approval is covered for create only; seam=none; no_claim=a real TTY (stdinIsTerminal and askConfirm are replaced)
func TestDeleteInATerminalAsksBeforeAnUnapprovedTeardownScript(t *testing.T) {
	for _, yes := range []bool{false, true} {
		t.Run(map[bool]string{false: "declined", true: "approved"}[yes], func(t *testing.T) {
			home := contractHomeDir(t)
			project := projectWithWorkroom(t, home)
			marker := filepath.Join(home, "teardown-ran")
			body := "#!/bin/sh\ntouch " + marker + "\n"
			writeScriptFile(t, project, "workroom_teardown", body)
			asked := asTerminal(t, yes)

			r := runCLI(t, "delete", contractName, "--project", project, "--confirm", contractName)
			if len(*asked) != 1 {
				t.Fatalf("asked %v, stdout %s", *asked, r.stdout)
			}
			projects, _ := mustConfig(t).AllProjects()
			sum := sha256.Sum256([]byte(body))
			approved := projects[project].TrustedScripts["workroom_teardown"] == hex.EncodeToString(sum[:])
			_, ran := os.Stat(marker)
			if yes {
				if r.code != 0 || !approved || ran != nil {
					t.Fatalf("approved: exit %d, approved %v, ran %v: %s %s", r.code, approved, ran, r.stdout, r.stderr)
				}
				return
			}
			if r.code != 4 || approved || ran == nil || len(projects[project].Workrooms) != 1 {
				t.Fatalf("declined: exit %d, approved %v, ran %v, project %+v", r.code, approved, ran, projects[project])
			}
		})
	}
}

// Value: protects=`trust` in a terminal records nothing for a script the person declines, and `trust --stdin` rejects a name other than the two scripts; fails_when=a no still records the digest, or --stdin accepts an arbitrary script name into the project's approvals; why_new=trust tests run non-interactively and only with valid stdin names; seam=none; no_claim=a real TTY (stdinIsTerminal and askConfirm are replaced)
func TestTrustLeavesADeclinedScriptUnapprovedAndRejectsOtherStdinNames(t *testing.T) {
	_, project := trustProject(t, "echo hi\n")
	asTerminal(t, false)
	r := runCLI(t, "trust", "--project", project)
	if r.code != 0 || !strings.Contains(string(r.stdout), "scripts/workroom_setup was left unapproved.") {
		t.Fatalf("declined: exit %d %s %s", r.code, r.stdout, r.stderr)
	}
	projects, _ := mustConfig(t).AllProjects()
	if len(projects[project].TrustedScripts) != 0 {
		t.Fatalf("recorded %v", projects[project].TrustedScripts)
	}

	withStdin(t, "#!/bin/sh\n")
	if r := runCLI(t, "trust", "--project", project, "--stdin", "other_script"); r.code == 0 {
		t.Fatalf("--stdin other_script succeeded: %s", r.stdout)
	}
	projects, _ = mustConfig(t).AllProjects()
	if len(projects[project].TrustedScripts) != 0 {
		t.Fatalf("recorded %v", projects[project].TrustedScripts)
	}
}
