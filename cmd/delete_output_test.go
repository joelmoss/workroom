package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/fatih/color"
	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/workroom"
)

// The human `workroom delete`'s whole output, byte for byte, pinned before its rendering moved out
// of internal/workroom. Paths with --confirm run through the CLI; the confirmation and pick prompts
// need a terminal, so those paths run through runDeleteHuman with the prompts answered.
func TestDeleteOutput(t *testing.T) {
	t.Run("cli", func(t *testing.T) {
		cases := []struct {
			name   string
			setup  func(t *testing.T, home, project string) []string // extra args
			code   int
			stdout string
			stderr string
		}{
			{"deleted", nil, 0, "╭─ Teardown ────────────────────────────────────────────────\n│ stopping\n╰───────────────────────────────────────────────────────────\n\nWorkroom 'calm-river' deleted successfully.\n\nNote: Git branch 'workroom/calm-river' was not deleted.\n      Delete manually with `git branch -D workroom/calm-river` if needed.\n", ""},
			{"quiet teardown", func(t *testing.T, _, project string) []string {
				writeProjectScript(t, project, "workroom_teardown", "true\n")
				return nil
			}, 0, "Workroom 'calm-river' deleted successfully.\n\nNote: Git branch 'workroom/calm-river' was not deleted.\n      Delete manually with `git branch -D workroom/calm-river` if needed.\n", ""},
			{"verbose", func(*testing.T, string, string) []string { return []string{"--verbose"} }, 0, "        repo  Detected Git worktree\n    teardown  Running /Users/dev/src/app/scripts/workroom_teardown from \"/Users/dev/workrooms/calm-river\"\n╭─ Teardown ────────────────────────────────────────────────\n│ stopping\n╰───────────────────────────────────────────────────────────\n\nWorkroom 'calm-river' deleted successfully.\n\nNote: Git branch 'workroom/calm-river' was not deleted.\n      Delete manually with `git branch -D workroom/calm-river` if needed.\n", ""},
			{"teardown fails", func(t *testing.T, _, project string) []string {
				writeProjectScript(t, project, "workroom_teardown", "echo boom\nexit 1\n")
				return nil
			}, 5, "╭─ Teardown ────────────────────────────────────────────────\n│ boom\n╰─ Teardown failed ─────────────────────────────────────────\n", "Error: teardown script failed: /Users/dev/src/app/scripts/workroom_teardown returned a non-zero exit code\n"},
			{"not a git worktree", func(t *testing.T, home, project string) []string {
				plain := filepath.Join(home, "workrooms", "plain")
				if err := os.MkdirAll(plain, 0o755); err != nil {
					t.Fatal(err)
				}
				addWorkroom(t, project, "plain", plain)
				return []string{"plain"}
			}, 0, "Workroom 'plain' removed from Workroom. It is not a git worktree, so no git or teardown ran.\nNote: its folder was left at ~/workrooms/plain. Delete it manually if needed.\n", ""},
			{"host destroyed", func(t *testing.T, _, project string) []string {
				cfg, _ := config.New("")
				if err := cfg.AddRemoteWorkroom(project, "gone", "/home/workroom/gone", map[string]any{"state": "destroyed"}); err != nil {
					t.Fatal(err)
				}
				return []string{"gone"}
			}, 0, "Workroom 'gone' deleted successfully.\n", ""},
			{"no such workroom", func(*testing.T, string, string) []string { return []string{"nope"} }, 3, "", "Error: git worktree does not exist: Git worktree 'nope' does not exist\n"},
		}
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				home := contractHomeDir(t)
				project := projectWithWorkroom(t, home)
				var extra []string
				if c.setup != nil {
					extra = c.setup(t, home, project)
				}
				name := contractName
				if len(extra) > 0 && !strings.HasPrefix(extra[0], "-") {
					name, extra = extra[0], extra[1:]
				}
				args := append([]string{"delete", name, "--confirm", name, "--project", project}, extra...)
				r := runCLI(t, args...)
				norm := strings.NewReplacer(home, contractHome)
				stdout, stderr := norm.Replace(string(r.stdout)), norm.Replace(string(r.stderr))
				if r.code != c.code || stdout != c.stdout || stderr != c.stderr {
					t.Errorf("exit %d\nstdout %q\nstderr %q\nwant exit %d\nstdout %q\nstderr %q",
						r.code, stdout, stderr, c.code, c.stdout, c.stderr)
				}
			})
		}
	})

	t.Run("colour", func(t *testing.T) {
		if os.Getenv("NO_COLOR") != "" {
			// internal/ui's colours are made with NO_COLOR already applied, at package init.
			t.Skip("NO_COLOR is set: the coloured output is not checked")
		}
		saved := color.NoColor
		color.NoColor = false
		t.Cleanup(func() { color.NoColor = saved })
		home := contractHomeDir(t)
		project := projectWithWorkroom(t, home)
		r := runCLI(t, "delete", contractName, "--confirm", contractName, "--project", project)
		if got := strings.ReplaceAll(string(r.stdout), home, contractHome); r.code != 0 || got != "\x1b[90m╭─\x1b[0m\x1b[1m\x1b[34m Teardown \x1b[0m\x1b[22m\x1b[90m────────────────────────────────────────────────\x1b[0m\n\x1b[90m│\x1b[0m stopping\n\x1b[90m╰───────────────────────────────────────────────────────────\x1b[0m\n\n\x1b[32mWorkroom 'calm-river' deleted successfully.\x1b[0m\n\nNote: Git branch 'workroom/calm-river' was not deleted.\n      Delete manually with `git branch -D workroom/calm-river` if needed.\n" {
			t.Errorf("exit %d, stdout %q", r.code, got)
		}
	})

	t.Run("prompts", func(t *testing.T) {
		cases := []struct {
			name      string
			args      []string
			empty     bool     // the project has no workrooms
			pick      []string // what the user picks
			confirm   bool     // the user's answer
			prompts   string   // every prompt, in order
			stdout    string
			remaining []string // workrooms left in config
		}{
			{"declined", []string{contractName}, false, nil, false,
				"Are you sure you want to delete workroom 'calm-river'?\n", "Aborting. Workroom 'calm-river' was not deleted.\n", []string{"bright-star", contractName}},
			{"confirmed", []string{contractName}, false, nil, true,
				"Are you sure you want to delete workroom 'calm-river'?\n", "╭─ Teardown ────────────────────────────────────────────────\n│ stopping calm-river\n╰───────────────────────────────────────────────────────────\n\nWorkroom 'calm-river' deleted successfully.\n\nNote: Git branch 'workroom/calm-river' was not deleted.\n      Delete manually with `git branch -D workroom/calm-river` if needed.\n", []string{"bright-star"}},
			{"no workrooms", nil, true, nil, true, "", "No workrooms found for this project.\n", nil},
			{"none picked", nil, false, nil, true,
				"Select workrooms to delete: bright-star,calm-river\n", "Aborting. No workrooms were selected.\n", []string{"bright-star", contractName}},
			{"picks declined", nil, false, []string{"bright-star", contractName}, false,
				"Select workrooms to delete: bright-star,calm-river\nAre you sure you want to delete 2 workroom(s): 'bright-star', 'calm-river'?\n", "Aborting. No workrooms were deleted.\n", []string{"bright-star", contractName}},
			{"picks confirmed", nil, false, []string{"bright-star", contractName}, true,
				"Select workrooms to delete: bright-star,calm-river\nAre you sure you want to delete 2 workroom(s): 'bright-star', 'calm-river'?\n", "╭─ Teardown ────────────────────────────────────────────────\n│ stopping bright-star\n╰───────────────────────────────────────────────────────────\n\nWorkroom 'bright-star' deleted successfully.\n\nNote: Git branch 'workroom/bright-star' was not deleted.\n      Delete manually with `git branch -D workroom/bright-star` if needed.\n╭─ Teardown ────────────────────────────────────────────────\n│ stopping calm-river\n╰───────────────────────────────────────────────────────────\n\nWorkroom 'calm-river' deleted successfully.\n\nNote: Git branch 'workroom/calm-river' was not deleted.\n      Delete manually with `git branch -D workroom/calm-river` if needed.\n", nil},
		}
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				home := contractHomeDir(t)
				project := gitRepo(t, filepath.Join(home, "src", "app"))
				writeProjectScript(t, project, "workroom_teardown", "echo stopping $WORKROOM_NAME\n")
				cfg, err := config.New("")
				if err != nil {
					t.Fatal(err)
				}
				if c.empty {
					if err := cfg.AddProject(project, "git"); err != nil {
						t.Fatal(err)
					}
				} else {
					for _, name := range []string{contractName, "bright-star"} {
						path := filepath.Join(home, "workrooms", name)
						run(t, project, "git", "worktree", "add", "-q", "-b", "workroom/"+name, path)
						addWorkroom(t, project, name, path)
					}
				}

				var prompts strings.Builder
				svc := &workroom.Service{
					Config:           cfg,
					KeepEmptyProject: true,
					PromptFn: func(message string, options []string) ([]string, error) {
						sorted := slices.Sorted(slices.Values(options)) // the prompt's order is the config's
						prompts.WriteString(message + " " + strings.Join(sorted, ",") + "\n")
						return c.pick, nil
					},
					ConfirmFn: func(message string) (bool, error) {
						prompts.WriteString(message + "\n")
						return c.confirm, nil
					},
				}
				var out bytes.Buffer
				if err := runDeleteHuman(svc, project, c.args, "", &out); err != nil {
					t.Fatal(err)
				}
				norm := strings.NewReplacer(home, contractHome)
				if got := norm.Replace(prompts.String()); got != c.prompts {
					t.Errorf("prompts %q\nwant %q", got, c.prompts)
				}
				if got := norm.Replace(out.String()); got != c.stdout {
					t.Errorf("stdout %q\nwant %q", got, c.stdout)
				}
				left, _ := cfg.WorkroomNames(project)
				slices.Sort(left)
				if !slices.Equal(left, c.remaining) {
					t.Errorf("workrooms left %v, want %v", left, c.remaining)
				}
			})
		}
	})
}

// addWorkroom registers workroom name of project at path.
func addWorkroom(t *testing.T, project, name, path string) {
	t.Helper()
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddWorkroom(project, name, path, "git"); err != nil {
		t.Fatal(err)
	}
}
