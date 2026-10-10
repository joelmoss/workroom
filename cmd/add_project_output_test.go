package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// cliCase is one run of the CLI and everything it prints, byte for byte, with HOME written as
// contractHome.
type cliCase struct {
	name   string
	args   []string
	code   int
	stdout string
	stderr string
}

// checkCLI runs each case in order, in the HOME home, and compares its exit code and output.
func checkCLI(t *testing.T, home string, cases []cliCase) {
	t.Helper()
	norm := strings.NewReplacer(home, contractHome)
	for _, c := range cases {
		run := runCLI(t, c.args...)
		if stdout := norm.Replace(string(run.stdout)); run.code != c.code || stdout != c.stdout {
			t.Errorf("%s: exit %d, stdout:\n%s\nwant exit %d, stdout:\n%s", c.name, run.code, stdout, c.code, c.stdout)
		}
		if stderr := norm.Replace(string(run.stderr)); stderr != c.stderr {
			t.Errorf("%s: stderr:\n%q\nwant:\n%q", c.name, stderr, c.stderr)
		}
	}
}

// envelope is an envelope line as the CLI prints it, from its keys after "cli_version":"dev".
func envelope(fields string) string {
	return `{"cli_version":"dev",` + fields + "}\n"
}

// add-project's whole output, pinned before its logic moved into internal/workroom.
func TestAddProjectOutput(t *testing.T) {
	home := contractHomeDir(t)
	repo := gitRepo(t, filepath.Join(home, "src", "repo"))
	file := filepath.Join(home, "src", "file")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	full := filepath.Join(home, "src", "full")
	if err := os.MkdirAll(full, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(full, "README"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	fresh := filepath.Join(home, "src", "fresh")

	checkCLI(t, home, []cliCase{
		{"human mode", []string{"add-project", repo}, 1, "",
			"Error: add-project is only available in --json mode\n"},
		{"no path", []string{"add-project", "--json"}, 1,
			envelope(`"command":"add-project","error":{"kind":"InternalError","message":"a path argument is required"},"ok":false,"schema_version":1`), ""},
		{"pretend", []string{"add-project", repo, "--json", "--pretend"}, 0,
			envelope(`"command":"add-project","ok":true,"path":"/Users/dev/src/repo","schema_version":1,"vcs":"git","would_create":false`), ""},
		{"create, pretend", []string{"add-project", fresh, "--json", "--create", "--pretend"}, 0,
			envelope(`"command":"add-project","ok":true,"path":"/Users/dev/src/fresh","schema_version":1,"vcs":"git","would_create":true`), ""},
		{"create", []string{"add-project", fresh, "--json", "--create"}, 0,
			envelope(`"command":"add-project","ok":true,"path":"/Users/dev/src/fresh","schema_version":1,"vcs":"git"`), ""},
		{"create, existing repo, pretend", []string{"add-project", repo, "--json", "--create", "--pretend"}, 0,
			envelope(`"command":"add-project","ok":true,"path":"/Users/dev/src/repo","schema_version":1,"vcs":"git","would_create":false`), ""},
		{"existing repo", []string{"add-project", repo, "--json"}, 0,
			envelope(`"command":"add-project","ok":true,"path":"/Users/dev/src/repo","schema_version":1,"vcs":"git"`), ""},
		{"remote", []string{"add-project", "git@example.com:org/repo.git", "--json", "--create"}, 3,
			envelope(`"command":"add-project","error":{"kind":"RemoteProjectUnsupported","message":"remote projects are not supported: add the project from a local Git repository. A remote workroom belongs to a local project: git@example.com:org/repo.git"},"ok":false,"schema_version":1`), ""},
		{"create on a file", []string{"add-project", file, "--json", "--create"}, 3,
			envelope(`"command":"add-project","error":{"kind":"NotADirectory","message":"path exists but is not a directory"},"ok":false,"schema_version":1`), ""},
		{"create in a full directory", []string{"add-project", full, "--json", "--create"}, 3,
			envelope(`"command":"add-project","error":{"kind":"UnsupportedVCS","message":"no supported VCS detected in this directory. Workroom requires Git to manage workrooms"},"ok":false,"schema_version":1`), ""},
		{"not a repository", []string{"add-project", full, "--json", "--pretend"}, 3,
			envelope(`"command":"add-project","error":{"kind":"UnsupportedVCS","message":"no supported VCS detected in this directory. Workroom requires Git to manage workrooms"},"ok":false,"schema_version":1`), ""},
	})
}
