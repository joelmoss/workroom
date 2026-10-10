package cmd

import (
	"path/filepath"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
)

// delete-project's refusals and failures, byte for byte, pinned before its logic moved into
// internal/workroom. Its three successful modes are pinned by the contract goldens.
func TestDeleteProjectOutput(t *testing.T) {
	home := contractHomeDir(t)
	app := projectWithWorkroom(t, home)
	writeProjectScript(t, app, "workroom_teardown", "echo stopping\nexit 1\n")

	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	remote := gitRepo(t, filepath.Join(home, "src", "remote"))
	if err := cfg.AddProject(remote, "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddRemoteWorkroom(remote, "zulu", "/home/workroom/zulu", map[string]any{"state": "running"}); err != nil {
		t.Fatal(err)
	}
	based := gitRepo(t, filepath.Join(home, "src", "based"))
	if err := cfg.AddProject(based, "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.SetHost(based, "", map[string]any{"state": "running"}); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(home, "git"); err != nil {
		t.Fatal(err)
	}

	refused := func(kind, message string) string {
		return envelope(`"command":"delete-project","error":{"kind":"` + kind + `","message":"` + message + `"},"ok":false,"schema_version":1`)
	}
	checkCLI(t, home, []cliCase{
		{"human mode", []string{"delete-project", app, "--confirm", app}, 1, "",
			"Error: delete-project is only available in --json mode\n"},
		{"no path", []string{"delete-project", "--json"}, 1,
			refused("InternalError", "a path argument is required"), ""},
		{"confirm mismatch", []string{"delete-project", app, "--json", "--confirm", "/nope"}, 2,
			refused("ConfirmationMismatch", "confirmation value does not match the workroom name: --confirm <path> is required and must match the project path"), ""},
		{"remote workrooms", []string{"delete-project", remote, "--json", "--confirm", remote}, 3,
			refused("RemoteWorkroomUnsupported", "not supported for a remote workroom yet: /Users/dev/src/remote has remote workrooms: zulu"), ""},
		{"a base machine", []string{"delete-project", based, "--json", "--confirm", based, "--from-disk"}, 3,
			refused("RemoteWorkroomUnsupported", "not supported for a remote workroom yet: /Users/dev/src/based has a remote host (its base machine)"), ""},
		{"unsafe path", []string{"delete-project", home, "--json", "--confirm", home, "--from-disk"}, 2,
			refused("UnsafeDeletePath", `refusing to delete an unsafe or reserved path: refusing to delete \"/Users/dev\"`), ""},
		{"teardown fails, with workrooms", []string{"delete-project", app, "--json", "--confirm", app, "--with-workrooms"}, 5,
			refused("TeardownScriptFailed", "teardown script failed: /Users/dev/src/app/scripts/workroom_teardown returned a non-zero exit code"),
			`{"type":"log","phase":"teardown","text":"stopping"}` + "\n"},
		{"teardown fails, from disk", []string{"delete-project", app, "--json", "--confirm", app, "--from-disk"}, 5,
			refused("TeardownScriptFailed", "teardown script failed: /Users/dev/src/app/scripts/workroom_teardown returned a non-zero exit code"),
			`{"type":"log","phase":"teardown","text":"stopping"}` + "\n"},
	})
	if projects, _ := cfg.AllProjects(); len(projects[app].Workrooms) != 1 {
		t.Fatalf("a failed teardown dropped the project or its workroom: %#v", projects[app])
	}
}
