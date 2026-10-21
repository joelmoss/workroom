package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/workroom"
)

func commitAll(t *testing.T, dir, msg string) {
	t.Helper()
	run(t, dir, "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
		"commit", "-q", "-m", msg)
}

// originProjectAt is a project registered under home whose origin has main, with local main equal
// to it and a clean tree. base.txt is a tracked file for a test to modify. origin/HEAD is set, as a
// real clone (or an earlier create's fetch) leaves it: without it a start that can't be fetched
// falls back to the checkout's own HEAD, and an offline test passes whatever the code does.
func originProjectAt(t *testing.T, home, name string) string {
	t.Helper()
	origin := filepath.Join(home, name+".git")
	run(t, home, "git", "init", "-q", "--bare", "-b", "main", origin)
	project := gitRepo(t, filepath.Join(home, "src", name))
	writeFile(t, filepath.Join(project, "base.txt"), "base\n")
	run(t, project, "git", "add", "base.txt")
	commitAll(t, project, "base")
	run(t, project, "git", "remote", "add", "origin", origin)
	run(t, project, "git", "push", "-q", "-u", "origin", "main")
	run(t, project, "git", "remote", "set-head", "origin", "main")
	if err := mustConfig(t).AddProject(project, "git"); err != nil {
		t.Fatal(err)
	}
	return project
}

func originProject(t *testing.T) (home, project string) {
	t.Helper()
	home = contractHomeDir(t)
	return home, originProjectAt(t, home, "app")
}

// aheadProject is a registered project whose origin has main, and whose local main is one commit
// ahead of it, adding local.txt.
func aheadProject(t *testing.T) (home, project string) {
	t.Helper()
	home, project = originProject(t)
	writeFile(t, filepath.Join(project, "local.txt"), "unpushed\n")
	run(t, project, "git", "add", "local.txt")
	commitAll(t, project, "local")
	return home, project
}

func writeFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

type localWorkEnvelope struct {
	Error struct {
		Kind    string `json:"kind"`
		Message string `json:"message"`
	} `json:"error"`
	LocalWork struct {
		Branch      string `json:"branch"`
		Remote      string `json:"remote"`
		Ahead       int    `json:"ahead"`
		Behind      int    `json:"behind"`
		Uncommitted bool   `json:"uncommitted"`
		Summary     string `json:"summary"`
		BehindNote  string `json:"behind_note"`
	} `json:"local_work"`
	Name    string `json:"name"`
	Warning string `json:"warning"`
}

func decodeLocalWork(t *testing.T, stdout []byte) localWorkEnvelope {
	t.Helper()
	var env localWorkEnvelope
	if err := json.Unmarshal(stdout, &env); err != nil {
		t.Fatalf("not one JSON envelope: %q", stdout)
	}
	return env
}

// Value: protects=the app's start choice: --start ask refuses a create that would leave unpushed
// commits out, before anything exists, saying what they are; fails_when=it creates, exits other
// than 3, or the payload misses the branch, remote or count; seam=none
func TestCreateStartAskRefusesWithTheLocalWork(t *testing.T) {
	home, project := aheadProject(t)

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "ask", "--project", project)
	env := decodeLocalWork(t, r.stdout)
	if r.code != 3 || env.Error.Kind != "LocalWorkLeftOut" {
		t.Fatalf("exit %d kind %q, want 3 LocalWorkLeftOut: %s", r.code, env.Error.Kind, r.stdout)
	}
	w := env.LocalWork
	if w.Branch != "main" || w.Remote != "origin" || w.Ahead != 1 || w.Uncommitted ||
		w.Summary != "You have 1 commit on main that you haven't pushed yet" {
		t.Fatalf("local_work = %+v", w)
	}
	if entries, _ := os.ReadDir(filepath.Join(home, "workrooms")); len(entries) != 0 {
		t.Fatalf("workrooms dir has %v, want nothing created", entries)
	}
}

// Value: protects=a create nobody can ask (a script, --json without --start) still starts from
// origin as before, now saying what it left out; fails_when=it refuses, starts from local, or
// says nothing; seam=none
func TestCreateWithNobodyToAskStartsFromOriginAndWarns(t *testing.T) {
	home, project := aheadProject(t)

	r := runCLI(t, "create", "--json", "--no-editor", "--project", project)
	env := decodeLocalWork(t, r.stdout)
	if r.code != 0 || env.Warning != "You have 1 commit on main that you haven't pushed yet. This workroom "+
		"doesn't include that work, because new workrooms start from what you've pushed." {
		t.Fatalf("exit %d warning %q: %s", r.code, env.Warning, r.stdout)
	}
	if _, err := os.Stat(filepath.Join(home, "workrooms", env.Name, "local.txt")); !os.IsNotExist(err) {
		t.Fatal("the workroom has the unpushed commit, want origin's main")
	}
}

// The refusal the app decodes to ask where a create starts.
func TestContractLocalWorkLeftOut(t *testing.T) {
	home, project := aheadProject(t)
	writeFile(t, filepath.Join(project, "untracked.txt"), "untracked\n")

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "ask", "--project", project)
	if r.code != 3 {
		t.Fatalf("create: exit %d, %s", r.code, r.stdout)
	}
	checkContract(t, "create-local-work.json", r.stdout, home)
}

// Value: protects=--start local starts from the local branch, with its unpushed commits;
// fails_when=the workroom lacks them; seam=none
func TestCreateStartLocalHasTheUnpushedCommits(t *testing.T) {
	home, project := aheadProject(t)

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "local", "--project", project)
	env := decodeLocalWork(t, r.stdout)
	if r.code != 0 || env.Warning != "" {
		t.Fatalf("exit %d warning %q: %s", r.code, env.Warning, r.stdout)
	}
	if _, err := os.Stat(filepath.Join(home, "workrooms", env.Name, "local.txt")); err != nil {
		t.Fatalf("the workroom lacks the unpushed commit: %v", err)
	}
}

// Value: protects=--start local-with-changes copies the main checkout's uncommitted changes (a
// modified tracked file, a staged new file and an untracked one) into the new workroom and leaves
// them in the main checkout; fails_when=any change is missing from the workroom, an ignored file
// is copied, or the main checkout loses its changes; seam=none
func TestCreateStartLocalWithChangesCopiesThem(t *testing.T) {
	home, project := aheadProject(t)
	writeFile(t, filepath.Join(project, "local.txt"), "edited\n")
	writeFile(t, filepath.Join(project, "staged.txt"), "staged\n")
	run(t, project, "git", "add", "staged.txt")
	writeFile(t, filepath.Join(project, "untracked.txt"), "untracked\n")
	writeFile(t, filepath.Join(project, ".gitignore"), "ignored.txt\n")
	writeFile(t, filepath.Join(project, "ignored.txt"), "secret\n")
	before := run(t, project, "git", "status", "--porcelain")

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "local-with-changes", "--project", project)
	env := decodeLocalWork(t, r.stdout)
	if r.code != 0 {
		t.Fatalf("exit %d: %s %s", r.code, r.stdout, r.stderr)
	}
	if !strings.Contains(string(r.stderr), `"id":"changes","state":"done"`) {
		t.Fatalf("no changes step: %s", r.stderr)
	}
	wr := filepath.Join(home, "workrooms", env.Name)
	for file, want := range map[string]string{
		"local.txt": "edited\n", "staged.txt": "staged\n", "untracked.txt": "untracked\n", ".gitignore": "ignored.txt\n",
	} {
		if got, err := os.ReadFile(filepath.Join(wr, file)); err != nil || string(got) != want {
			t.Fatalf("%s = %q (%v), want %q", file, got, err, want)
		}
	}
	if _, err := os.Stat(filepath.Join(wr, "ignored.txt")); !os.IsNotExist(err) {
		t.Fatal("an ignored file was copied")
	}
	if after := run(t, project, "git", "status", "--porcelain"); after != before {
		t.Fatalf("the main checkout changed: %q, was %q", after, before)
	}
}

// Value: protects=a person at a terminal is asked where to start, offered only the choices that
// apply; fails_when=no question, a choice that doesn't apply is offered, or the answer is
// ignored; seam=askSelect
func TestCreateInATerminalAsksWhereToStart(t *testing.T) {
	home, project := aheadProject(t)
	asTerminal(t, false)
	var offered []string
	saved := askSelect
	askSelect = func(_, _ string, options []string) (int, error) { offered = options; return 0, nil }
	t.Cleanup(func() { askSelect = saved })

	r := runCLI(t, "create", "--project", project)
	if r.code != 0 {
		t.Fatalf("exit %d: %s %s", r.code, r.stdout, r.stderr)
	}
	if want := []string{"Include my commits", "Leave it out"}; strings.Join(offered, "|") != strings.Join(want, "|") {
		t.Fatalf("offered %q, want %q", offered, want)
	}
	entries, _ := os.ReadDir(filepath.Join(home, "workrooms"))
	if len(entries) != 1 {
		t.Fatalf("workrooms dir has %v", entries)
	}
	if _, err := os.Stat(filepath.Join(home, "workrooms", entries[0].Name(), "local.txt")); err != nil {
		t.Fatalf("chose local, but the workroom lacks the unpushed commit: %v", err)
	}
}

// Value: protects=trust status reports the work a create from its base leaves out, which a remote
// create warns about; fails_when=local_work is missing or wrong; seam=none
func TestTrustStatusReportsTheLocalWork(t *testing.T) {
	_, project := aheadProject(t)

	r := runCLI(t, "trust", "status", "--json", "--project", project, "--base", "")
	env := decodeLocalWork(t, r.stdout)
	if r.code != 0 || env.LocalWork.Ahead != 1 || env.LocalWork.Branch != "main" {
		t.Fatalf("exit %d local_work %+v: %s", r.code, env.LocalWork, r.stdout)
	}
}

// Value: protects=a mistyped --start value is refused before anything exists, naming what is
// allowed; fails_when=the value is accepted, the exit is 0, the message omits the allowed values,
// or a workroom is created; why_new=every other test passes a valid value; seam=none;
// no_claim=the wording beyond the allowed values
func TestCreateRefusesAnUnknownStart(t *testing.T) {
	home, project := aheadProject(t)

	r := runCLI(t, "create", "--json", "--start", "bogus", "--project", project)
	out := string(r.stdout) + string(r.stderr)
	if r.code == 0 || !strings.Contains(out, "--start must be one of origin, local, local-with-changes, ask") {
		t.Fatalf("exit %d, want a refusal naming the allowed values: %s", r.code, out)
	}
	if entries, _ := os.ReadDir(filepath.Join(home, "workrooms")); len(entries) != 0 {
		t.Fatalf("workrooms dir has %v, want nothing created", entries)
	}
}

// Value: protects=--start ask refuses only for work a create would really leave out: not when main
// matches origin, not for changes on a branch other than the one the workroom starts from, and it
// does refuse uncommitted changes alone; fails_when=ask refuses with no local work, refuses for
// another branch's changes, or lets uncommitted-only work through; why_new=the other ask tests all
// have an unpushed commit; seam=none; no_claim=the contract payload shape
func TestCreateStartAskOnlyRefusesForWorkItWouldLeaveOut(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T, project string)
		code  int
	}{
		{"main equals origin and the tree is clean", func(t *testing.T, project string) {}, 0},
		{"changes on another branch", func(t *testing.T, project string) {
			run(t, project, "git", "checkout", "-q", "-b", "other")
			writeFile(t, filepath.Join(project, "base.txt"), "edited\n")
		}, 0},
		{"uncommitted changes only", func(t *testing.T, project string) {
			writeFile(t, filepath.Join(project, "base.txt"), "edited\n")
		}, 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, project := originProject(t)
			tc.setup(t, project)

			r := runCLI(t, "create", "--json", "--no-editor", "--start", "ask", "--project", project)
			env := decodeLocalWork(t, r.stdout)
			if r.code != tc.code {
				t.Fatalf("exit %d, want %d: %s %s", r.code, tc.code, r.stdout, r.stderr)
			}
			w := env.LocalWork
			if tc.code == 0 && (w.Ahead != 0 || w.Uncommitted || w.Summary != "") {
				t.Fatalf("created, but local_work = %+v", w)
			}
			if tc.code == 3 && (env.Error.Kind != "LocalWorkLeftOut" || w.Ahead != 0 || !w.Uncommitted ||
				w.Summary != "You have changes on main that you haven't committed yet") {
				t.Fatalf("kind %q local_work = %+v", env.Error.Kind, w)
			}
		})
	}
}

// Value: protects=--start origin leaves unpushed commits out silently, since the person chose it;
// fails_when=the workroom has the commit or a warning is given; why_new=the no-start path warns
// and --start local includes, nothing pins the explicit choice to leave it out; seam=none
func TestCreateStartOriginLeavesTheUnpushedCommitsOut(t *testing.T) {
	home, project := aheadProject(t)

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "origin", "--project", project)
	env := decodeLocalWork(t, r.stdout)
	if r.code != 0 || env.Warning != "" {
		t.Fatalf("exit %d warning %q: %s", r.code, env.Warning, r.stdout)
	}
	if _, err := os.Stat(filepath.Join(home, "workrooms", env.Name, "local.txt")); !os.IsNotExist(err) {
		t.Fatal("the workroom has the unpushed commit, want origin's main")
	}
}

// Value: protects=the choices chooseStart offers for each kind of local work, that each maps to the
// start it says, and the plural summary as the prompt; fails_when=an option is missing, reworded,
// or maps to another start, or the title is wrong; why_new=the terminal test covers only the
// commits-only question and choice 0; seam=askSelect
func TestChooseStartOffersAndMapsEachChoice(t *testing.T) {
	saved := askSelect
	t.Cleanup(func() { askSelect = saved })
	const question = "New workrooms start from what you've pushed. Include this work in the new one?"
	for _, tc := range []struct {
		name     string
		work     vcs.LocalWork
		title    string
		question string
		options  []string
		starts   []workroom.Start
	}{
		{"commits and changes", vcs.LocalWork{Branch: "main", Ahead: 2, Uncommitted: true},
			"You have 2 commits on main that you haven't pushed yet, and some changes you haven't committed.",
			question,
			[]string{"Include my commits and changes", "Include my commits only", "Leave it out"},
			[]workroom.Start{workroom.StartLocalWithChanges, workroom.StartLocal, workroom.StartOrigin}},
		{"changes only, behind origin", vcs.LocalWork{Branch: "main", Remote: "origin", Uncommitted: true, Behind: 3},
			"You have changes on main that you haven't committed yet.",
			"Your main is also 3 commits behind origin, so including your work starts from your older copy. " + question,
			[]string{"Include my changes", "Leave it out"},
			[]workroom.Start{workroom.StartLocalWithChanges, workroom.StartOrigin}},
	} {
		for i, want := range tc.starts {
			var title, asked string
			var offered []string
			askSelect = func(prompt, description string, options []string) (int, error) {
				title, asked, offered = prompt, description, options
				return i, nil
			}
			got, err := chooseStart(tc.work)
			if err != nil || got != want {
				t.Fatalf("%s: choice %d = %q (%v), want %q", tc.name, i, got, err, want)
			}
			if title != tc.title || asked != tc.question || strings.Join(offered, "|") != strings.Join(tc.options, "|") {
				t.Fatalf("%s: title %q question %q options %q, want %q %q %q", tc.name, title, asked, offered,
					tc.title, tc.question, tc.options)
			}
		}
	}
}

// Value: protects=trust status shows local_work only for the project asked about; fails_when=a
// later run that reads no local work (--stdin) reports the earlier run's, through state kept
// between runs; why_new=the existing test runs one project per process; seam=none
func TestTrustStatusDoesNotLeakLocalWorkBetweenRuns(t *testing.T) {
	home, ahead := aheadProject(t)
	clean := originProjectAt(t, home, "clean")

	r := runCLI(t, "trust", "status", "--json", "--project", ahead, "--base", "")
	if env := decodeLocalWork(t, r.stdout); r.code != 0 || env.LocalWork.Ahead != 1 {
		t.Fatalf("first run: exit %d local_work %+v: %s", r.code, env.LocalWork, r.stdout)
	}
	// --stdin judges one script and never looks at local work, so any it reports is left over.
	withStdin(t, "#!/bin/sh\necho hi\n")
	r = runCLI(t, "trust", "status", "--json", "--project", clean, "--stdin", "workroom_setup")
	if r.code == 2 || !strings.Contains(string(r.stdout), `"scripts"`) || strings.Contains(string(r.stdout), "local_work") {
		t.Fatalf("second run: exit %d, want scripts and no local_work: %s", r.code, r.stdout)
	}
}

// Value: protects=the setup gate judges the script at the start actually chosen, so a script that
// exists only on the unpushed local commit is refused, unrun, when --start local picks it;
// fails_when=gateSetup is given the remote start, so a local-only script is never judged and runs
// unapproved; why_new=the other trust tests ship the script on the base commit; seam=none;
// no_claim=the wording of the refusal
func TestCreateStartLocalGatesAScriptOnlyTheUnpushedCommitHas(t *testing.T) {
	home, project := originProject(t)
	marker := filepath.Join(home, "ran")
	commitScript(t, project, "workroom_setup", "touch "+marker+"\n")

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "local", "--project", project)
	if r.code != 3 {
		t.Fatalf("exit %d, want 3: %s %s", r.code, r.stdout, r.stderr)
	}
	env := decodeUntrusted(t, r.stdout)
	if env.Error.Kind != "ScriptNotTrusted" || env.Script.Origin != "base" || env.Created != nil {
		t.Fatalf("envelope = %s", r.stdout)
	}
	if entries, _ := os.ReadDir(filepath.Join(home, "workrooms")); len(entries) != 0 {
		t.Fatalf("workrooms dir has %v, want nothing created", entries)
	}
	if names, err := mustConfig(t).WorkroomNames(project); err != nil || len(names) != 0 {
		t.Fatalf("workrooms registered = %v (%v), want none", names, err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("the unapproved setup script ran")
	}
}

// Value: protects=including changes judges the edited setup script that will run, not the committed
// one, before anything exists, so the app can ask for approval and Approve covers what runs;
// fails_when=the committed (approved) copy is judged and the edited one is refused only after the
// workroom exists, or runs unapproved; why_new=PR #520 review (Codex); seam=none;
// no_claim=the app's sheet
func TestIncludingChangesJudgesTheEditedSetupScriptFirst(t *testing.T) {
	home, project := originProject(t)
	commitScript(t, project, "workroom_setup", "echo hi\n")
	run(t, project, "git", "push", "-q", "origin", "main")
	approveForTest(t, project, "workroom_setup", "#!/bin/sh\necho hi\n")
	marker := filepath.Join(home, "ran")
	writeScriptFile(t, project, "workroom_setup", "#!/bin/sh\ntouch "+marker+"\n")

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "local-with-changes", "--project", project)
	env := decodeUntrusted(t, r.stdout)
	if r.code != 3 || env.Error.Kind != "ScriptNotTrusted" || env.Created != nil ||
		env.Script.Text != "#!/bin/sh\ntouch "+marker+"\n" {
		t.Fatalf("exit %d, want the edited script refused before creating: %s %s", r.code, r.stdout, r.stderr)
	}
	if entries, _ := os.ReadDir(filepath.Join(home, "workrooms")); len(entries) != 0 {
		t.Fatalf("workrooms dir has %v, want nothing created", entries)
	}

	// Approving the bytes shown lets the same create through, running the edited script.
	approveForTest(t, project, "workroom_setup", "#!/bin/sh\ntouch "+marker+"\n")
	if r = runCLI(t, "create", "--json", "--no-editor", "--start", "local-with-changes", "--project", project); r.code != 0 {
		t.Fatalf("after approving: exit %d: %s %s", r.code, r.stdout, r.stderr)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("the approved edited script didn't run: %v", err)
	}
}

// Value: protects=the app decodes trust status's local_work, so a remote create's notice appears;
// fails_when=the "local_work" key or any of its fields is renamed or dropped in the JSON;
// why_new=TestTrustStatusReportsTheLocalWork reads the Go struct, not the shape the app decodes;
// seam=none; no_claim=the other trust status fields
func TestContractTrustStatusLocalWork(t *testing.T) {
	home, project := aheadProject(t)

	r := runCLI(t, "trust", "status", "--json", "--project", project, "--base", "")
	if r.code != 0 {
		t.Fatalf("exit %d: %s", r.code, r.stdout)
	}
	checkContract(t, "trust-status-local-work.json", r.stdout, home)
}

// An offline create that starts from the local branch, as chosen: the events the app turns into the
// checklist, and the envelope its notice reads. The fetch row and the warning name the same start.
func TestContractCreateOfflineLocalStart(t *testing.T) {
	home, project := aheadProject(t)
	run(t, project, "git", "remote", "set-url", "origin", filepath.Join(home, "gone.git"))

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "local", "--project", project)
	if r.code != 0 {
		t.Fatalf("create: exit %d, %s %s", r.code, r.stdout, r.stderr)
	}
	name := createdName(t, r.stdout)
	checkContract(t, "create-offline-local-start.json", r.stdout, home, name, contractName)
	checkContract(t, "create-offline-local-start-events.ndjson", r.stderr, home, name, contractName)
}

// Value: protects=the choice says when the local branch is behind origin, since including the work
// then starts from the older copy; fails_when=behind isn't counted or the note is missing from the
// payload or the message; why_new=every other fixture's main has all of origin's commits;
// seam=none; no_claim=the app's wording of the note
func TestCreateStartAskSaysWhenTheLocalBranchIsBehind(t *testing.T) {
	home, project := originProject(t)
	// A teammate pushes a commit this checkout hasn't pulled.
	other := filepath.Join(home, "other")
	run(t, home, "git", "clone", "-q", filepath.Join(home, "app.git"), other)
	writeFile(t, filepath.Join(other, "theirs.txt"), "theirs\n")
	run(t, other, "git", "add", "theirs.txt")
	commitAll(t, other, "theirs")
	run(t, other, "git", "push", "-q", "origin", "main")
	writeFile(t, filepath.Join(project, "base.txt"), "edited\n")

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "ask", "--project", project)
	env := decodeLocalWork(t, r.stdout)
	note := "Your main is also 1 commit behind origin, so including your work starts from your older copy."
	if r.code != 3 || env.LocalWork.Behind != 1 || env.LocalWork.Ahead != 0 || env.LocalWork.BehindNote != note ||
		!strings.Contains(env.Error.Message, note) {
		t.Fatalf("exit %d local_work %+v message %q", r.code, env.LocalWork, env.Error.Message)
	}
}

// Value: protects=a start chosen beforehand holds when the fetch fails, and nobody is asked against
// a stale copy; fails_when=--start local silently starts from origin's stale copy, or --start ask
// refuses on counts against it; why_new=every other fixture's fetch works; seam=none;
// no_claim=the fetch warning's wording
func TestAChosenStartHoldsWhenTheFetchFails(t *testing.T) {
	home, project := aheadProject(t)
	run(t, project, "git", "remote", "set-url", "origin", filepath.Join(home, "gone.git"))

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "local", "--project", project)
	env := decodeLocalWork(t, r.stdout)
	// The warning says where it really starts, not origin's stale copy, and so does the fetch row.
	want := "The workroom starts from your local main, as you chose. It couldn't be compared with what you've pushed, so the two may differ."
	if r.code != 0 || env.Warning != want {
		t.Fatalf("--start local: exit %d warning %q, want %q: %s", r.code, env.Warning, want, r.stdout)
	}
	if row := `{"detail":"` + want + `","id":"fetch","state":"warning","type":"step"}`; !strings.Contains(string(r.stderr), row) ||
		strings.Contains(string(r.stderr), "starts from origin/main") {
		t.Fatalf("the fetch step doesn't say the workroom starts from the local branch: %s", r.stderr)
	}
	if _, err := os.Stat(filepath.Join(home, "workrooms", env.Name, "local.txt")); err != nil {
		t.Fatalf("--start local ignored offline, the workroom lacks the unpushed commit: %v", err)
	}

	r = runCLI(t, "create", "--json", "--no-editor", "--start", "ask", "--project", project)
	if r.code != 0 {
		t.Fatalf("--start ask asked against a stale copy: exit %d: %s", r.code, r.stdout)
	}
}

// Value: protects=a local start against the fallback from a missing app-wide default base keeps
// that fact and doesn't claim origin couldn't be checked, since its fetch worked; fails_when=the
// warning still names origin's copy, drops the missing base, or says the check failed;
// why_new=the offline test covers only a failed fetch; seam=none; no_claim=the fallback itself
func TestALocalStartAgainstAMissingDefaultBaseSaysWhy(t *testing.T) {
	home, project := aheadProject(t)
	if code, env := runHostCLI(t, "base", "set", "nope", "--global", "--json"); code != 0 {
		t.Fatalf("base set --global: exit %d, %v", code, env)
	}

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "local", "--project", project)
	env := decodeLocalWork(t, r.stdout)
	want := "The default base branch nope doesn't exist in this project. The workroom starts from your local main, as you chose."
	if r.code != 0 || env.Warning != want {
		t.Fatalf("exit %d warning %q, want %q: %s %s", r.code, env.Warning, want, r.stdout, r.stderr)
	}
	if _, err := os.Stat(filepath.Join(home, "workrooms", env.Name, "local.txt")); err != nil {
		t.Fatalf("the workroom lacks the unpushed commit: %v", err)
	}
}

// Value: protects=copying changes says when it leaves out a new folder that is a git repository of
// its own, rather than ending done; fails_when=the folder is skipped silently and the step is done;
// why_new=the copy test has only plain files; seam=none; no_claim=what is inside the folder
func TestCopyingChangesSaysWhenItSkipsANestedRepository(t *testing.T) {
	_, project := aheadProject(t)
	nested := gitRepo(t, filepath.Join(project, "vendored"))
	writeFile(t, filepath.Join(nested, "lib.txt"), "lib\n")
	writeFile(t, filepath.Join(project, "mine.txt"), "mine\n")

	r := runCLI(t, "create", "--json", "--no-editor", "--start", "local-with-changes", "--project", project)
	if r.code != 0 {
		t.Fatalf("exit %d: %s %s", r.code, r.stdout, r.stderr)
	}
	want := `"detail":"Didn't copy vendored/: each is a separate git repository","id":"changes","state":"warning"`
	if !strings.Contains(string(r.stderr), want) || !strings.Contains(string(r.stderr), "Copied mine.txt") {
		t.Fatalf("want the changes step to warn about vendored/ and still copy mine.txt: %s", r.stderr)
	}
}
