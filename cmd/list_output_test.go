package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/fatih/color"
	"github.com/joelmoss/workroom/internal/config"
)

// The human `workroom list` from each kind of directory, byte for byte, with and without colour,
// pinned before its rendering moved out of internal/workroom.
func TestListOutput(t *testing.T) {
	home := contractHomeDir(t)
	empty := gitRepo(t, filepath.Join(home, "src", "empty"))
	elsewhere := filepath.Join(home, "elsewhere")
	if err := os.MkdirAll(elsewhere, 0o755); err != nil {
		t.Fatal(err)
	}

	run := func(dir string) string {
		t.Helper()
		t.Chdir(dir)
		r := runCLI(t, "list")
		if r.code != 0 || len(r.stderr) != 0 {
			t.Fatalf("list in %s: exit %d, stderr %q", dir, r.code, r.stderr)
		}
		return string(r.stdout)
	}
	check := func(name, got, want string) {
		t.Helper()
		if got != want {
			t.Errorf("%s:\n got %q\nwant %q", name, got, want)
		}
	}

	// Nothing registered yet.
	check("no workrooms anywhere", run(elsewhere), "No workrooms found.\n")

	app := projectWithWorkroom(t, home)
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddWorkroom(app, "gone", filepath.Join(home, "workrooms", "gone"), "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(empty, "git"); err != nil {
		t.Fatal(err)
	}
	other := gitRepo(t, filepath.Join(home, "src", "other"))
	if err := cfg.AddWorkroom(other, "solo", filepath.Join(home, "workrooms", "solo"), "git"); err != nil {
		t.Fatal(err)
	}
	inWorkroom := filepath.Join(home, "workrooms", contractName)

	for _, colour := range []bool{false, true} {
		if colour && os.Getenv("NO_COLOR") != "" {
			// internal/ui's colours are made with NO_COLOR already applied, at package init.
			t.Log("NO_COLOR is set: the coloured output is not checked")
			continue
		}
		saved := color.NoColor
		color.NoColor = !colour
		t.Cleanup(func() { color.NoColor = saved })

		wrap := func(on, off string) func(string) string {
			return func(s string) string {
				if !colour {
					return s
				}
				return on + s + off
			}
		}
		b := wrap("\x1b[1m", "\x1b[22m")
		d := wrap("\x1b[90m", "\x1b[0m")
		y := wrap("\x1b[33m", "\x1b[0m")
		missing := y("[directory not found, git workspace not found]")

		check("in a workroom", run(inWorkroom),
			y("You are already in a workroom.")+"\nParent project is at ~/src/app\n")
		check("a project with no workrooms", run(empty), "No workrooms found for this project.\n")
		check("a project's root", run(app),
			"  "+b("calm-river")+"  "+d("~/workrooms/calm-river")+"\n"+
				"  "+b("gone")+"        "+d("~/workrooms/gone")+"        "+missing+"\n")
		check("elsewhere", run(elsewhere),
			"~/src/app:\n"+
				"  "+b("calm-river")+"  "+d("~/workrooms/calm-river")+"\n"+
				"  "+b("gone")+"        "+d("~/workrooms/gone")+"        "+missing+"\n"+
				"\n"+
				"~/src/other:\n"+
				"  "+b("solo")+"  "+d("~/workrooms/solo")+"  "+missing+"\n"+
				"\n")
	}
}
