package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/fatih/color"
	"github.com/joelmoss/workroom/internal/config"
)

// humanCreate runs the human `workroom create` in a new project, named after the case, and
// returns its exit code, stdout and stderr, with HOME written as contractHome and the random
// workroom name as contractName.
func humanCreate(t *testing.T, home, project string, args ...string) (int, string, string) {
	t.Helper()
	r := runCLI(t, append([]string{"create", "--project", project}, args...)...)
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	subs := []string{home, contractHome}
	if names, _ := cfg.WorkroomNames(project); len(names) == 1 {
		subs = append(subs, names[0], contractName)
	}
	norm := strings.NewReplacer(subs...)
	return r.code, norm.Replace(string(r.stdout)), norm.Replace(string(r.stderr))
}

// The human `workroom create`'s whole output, byte for byte, pinned before its rendering moved out
// of internal/workroom: the success line, the setup log panel when it passes and fails, the fetch
// warning, --verbose's status lines, and colour.
func TestCreateOutput(t *testing.T) {
	home := contractHomeDir(t)
	t.Setenv("EDITOR", "")
	project := func(name, setup string) string {
		p := gitRepo(t, filepath.Join(home, "src", name))
		if setup != "" {
			writeProjectScript(t, p, "workroom_setup", setup)
		}
		return p
	}
	check := func(name string, code int, stdout, stderr string, wantCode int, wantStdout, wantStderr string) {
		t.Helper()
		if code != wantCode || stdout != wantStdout || stderr != wantStderr {
			t.Errorf("%s: exit %d\nstdout %q\nstderr %q\nwant exit %d\nstdout %q\nstderr %q",
				name, code, stdout, stderr, wantCode, wantStdout, wantStderr)
		}
	}

	code, out, errOut := humanCreate(t, home, project("plain", ""))
	check("no setup script", code, out, errOut, 0, "Workroom 'calm-river' created successfully at ~/workrooms/calm-river.\n", "")

	code, out, errOut = humanCreate(t, home, project("setup", "echo installing\necho done\n"))
	check("setup passes", code, out, errOut, 0, "╭─ Setup ───────────────────────────────────────────────────\n│ installing\n│ done\n╰───────────────────────────────────────────────────────────\n\nWorkroom 'calm-river' created successfully at ~/workrooms/calm-river.\n", "")

	code, out, errOut = humanCreate(t, home, project("failing", "echo boom\nexit 3\n"))
	check("setup fails", code, out, errOut, 5, "╭─ Setup ───────────────────────────────────────────────────\n│ boom\n╰─ Setup failed ────────────────────────────────────────────\n", "Error: setup script failed: /Users/dev/src/failing/scripts/workroom_setup returned a non-zero exit code\n")

	warned := project("warned", "")
	run(t, warned, "git", "remote", "add", "origin", filepath.Join(home, "gone.git"))
	code, out, errOut = humanCreate(t, home, warned)
	check("fetch warning", code, out, errOut, 0, "Could not fetch origin. The workroom starts from HEAD, which may be out of date.\nWorkroom 'calm-river' created successfully at ~/workrooms/calm-river.\n", "")

	warnedAndFailing := project("warned-failing", "exit 1\n")
	run(t, warnedAndFailing, "git", "remote", "add", "origin", filepath.Join(home, "gone.git"))
	code, out, errOut = humanCreate(t, home, warnedAndFailing)
	check("fetch warning, setup fails", code, out, errOut, 5,
		"Could not fetch origin. The workroom starts from HEAD, which may be out of date.\n",
		"Error: setup script failed: /Users/dev/src/warned-failing/scripts/workroom_setup returned a non-zero exit code\n")

	code, out, errOut = humanCreate(t, home, project("verbose", "echo installing\n"), "--verbose")
	check("verbose", code, out, errOut, 0, "        repo  Detected Git worktree\n       setup  Running /Users/dev/src/verbose/scripts/workroom_setup from \"/Users/dev/workrooms/calm-river\"\n╭─ Setup ───────────────────────────────────────────────────\n│ installing\n╰───────────────────────────────────────────────────────────\n\nWorkroom 'calm-river' created successfully at ~/workrooms/calm-river.\n", "")

	saved := color.NoColor
	color.NoColor = false
	t.Cleanup(func() { color.NoColor = saved })
	if os.Getenv("NO_COLOR") != "" {
		// internal/ui's colours are made with NO_COLOR already applied, at package init.
		t.Log("NO_COLOR is set: the coloured output is not checked")
		return
	}
	code, out, errOut = humanCreate(t, home, project("colour", "echo installing\n"))
	check("colour", code, out, errOut, 0, "\x1b[90m╭─\x1b[0m\x1b[1m\x1b[34m Setup \x1b[0m\x1b[22m\x1b[90m───────────────────────────────────────────────────\x1b[0m\n\x1b[90m│\x1b[0m installing\n\x1b[90m╰───────────────────────────────────────────────────────────\x1b[0m\n\n\x1b[32mWorkroom 'calm-river' created successfully at ~/workrooms/calm-river.\x1b[0m\n", "")
}
