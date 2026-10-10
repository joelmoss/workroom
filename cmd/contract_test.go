package cmd

import (
	"encoding/json"
	"flag"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// The --json contract's goldens live in testdata/contracts: each file is what one command prints
// as the app runs it, byte for byte, with the temporary HOME and the random workroom name replaced
// so the files stay stable. macapp/WorkroomAppTests/CLIContractTests.swift decodes the same files
// with the app's own types, so a change on either side that breaks the other fails a test. A
// deliberate contract change rewrites them:
//
//	go test ./cmd -run TestContract -update
//
// The goldens cover each command whose payload the app decodes into its own type. Commands the app
// reads only as a bare Envelope (host, base, claim-provisioned) have their own tests.
var updateContracts = flag.Bool("update", false, "rewrite testdata/contracts from the CLI's output")

// contractHome stands in for the temporary HOME every path in a golden sits under.
const contractHome = "/Users/dev"

// contractName stands in for a created workroom's random name.
const contractName = "calm-river"

// cliRun is one in-process run of the CLI.
type cliRun struct {
	code           int
	stdout, stderr []byte
}

// runCLI runs the CLI with args as the app runs it, capturing its exit code, stdout and stderr.
func runCLI(t *testing.T, args ...string) cliRun {
	t.Helper()
	resetCLI()
	t.Cleanup(resetCLI)
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, stderr := make(chan []byte), make(chan []byte)
	go func() { b, _ := io.ReadAll(outR); stdout <- b }()
	go func() { b, _ := io.ReadAll(errR); stderr <- b }()
	savedOut, savedErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = outW, errW
	rootCmd.SetArgs(args)
	code := Execute()
	os.Stdout, os.Stderr = savedOut, savedErr
	_ = outW.Close()
	_ = errW.Close()
	return cliRun{code: code, stdout: <-stdout, stderr: <-stderr}
}

// resetCLI puts every flag back to its default, and clears the globals a run leaves behind: cobra
// keeps flag values, and whether each was set, between runs in one process.
func resetCLI() {
	var walk func(*cobra.Command)
	walk = func(c *cobra.Command) {
		for _, set := range []*pflag.FlagSet{c.PersistentFlags(), c.Flags()} {
			set.VisitAll(func(f *pflag.Flag) {
				_ = f.Value.Set(f.DefValue)
				f.Changed = false
			})
		}
		for _, sub := range c.Commands() {
			walk(sub)
		}
	}
	walk(rootCmd)
	currentCommand, jsonErrorExtra = "", nil
	rootCmd.SetArgs(nil)
}

// contractHomeDir points HOME at a fresh directory, by its symlink-resolved path as the CLI
// canonicalizes paths, so the CLI's config and workrooms_dir are there.
func contractHomeDir(t *testing.T) string {
	t.Helper()
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	return home
}

// gitRepo makes a repository with one commit at dir.
func gitRepo(t *testing.T, dir string) string {
	t.Helper()
	requireGit(t)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	run(t, dir, "git", "init", "-q", "-b", "main")
	run(t, dir, "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
		"commit", "-q", "--allow-empty", "-m", "first")
	return dir
}

// writeProjectScript writes scripts/<name> in project with body.
func writeProjectScript(t *testing.T, project, name, body string) {
	t.Helper()
	dir := filepath.Join(project, "scripts")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
}

// createdName is the name in a create's envelope, success or failure.
func createdName(t *testing.T, stdout []byte) string {
	t.Helper()
	var env struct {
		Name    string `json:"name"`
		Created struct {
			Name string `json:"name"`
		} `json:"created"`
	}
	if err := json.Unmarshal(stdout, &env); err != nil {
		t.Fatalf("not one JSON envelope: %q", stdout)
	}
	if env.Name != "" {
		return env.Name
	}
	if env.Created.Name == "" {
		t.Fatalf("no workroom name in %s", stdout)
	}
	return env.Created.Name
}

// checkContract compares got with testdata/contracts/<file> once home and the replacements in
// subs (old, new pairs) are made, or rewrites the file under -update.
func checkContract(t *testing.T, file string, got []byte, home string, subs ...string) {
	t.Helper()
	norm := strings.NewReplacer(append([]string{home, contractHome}, subs...)...).Replace(string(got))
	path := filepath.Join("..", "testdata", "contracts", file)
	if *updateContracts {
		if err := os.WriteFile(path, []byte(norm), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if norm != string(want) {
		t.Errorf("%s no longer matches the contract golden; a deliberate change runs -update and "+
			"keeps CLIContractTests.swift decoding it:\n got: %s\nwant: %s", file, norm, want)
	}
}

func TestContractList(t *testing.T) {
	home := contractHomeDir(t)
	app := gitRepo(t, filepath.Join(home, "src", "app"))
	empty := gitRepo(t, filepath.Join(home, "src", "empty"))
	workrooms := filepath.Join(home, "workrooms")
	run(t, app, "git", "worktree", "add", "-q", "-b", "workroom/ok", filepath.Join(workrooms, "ok"))
	if err := os.MkdirAll(filepath.Join(workrooms, "stray"), 0o755); err != nil {
		t.Fatal(err)
	}

	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"ok", "stray", "missing"} {
		if err := cfg.AddWorkroom(app, name, filepath.Join(workrooms, name), "git"); err != nil {
			t.Fatal(err)
		}
	}
	// The CLI stores and lists a host descriptor verbatim, which the app relies on for every key.
	remote := map[string]any{
		"state": "running", "driver": "container", "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
		"provisioner": "com.developwithstyle.workroom.dev", "credentials": "relay",
		"workroom_id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427", "grant_id": "grant-1",
		"repository": "acme/app", "clone_url": "https://github.com/acme/app.git",
		"org": "acme", "account": "user-1",
		"container": map[string]any{
			"address": "127.0.0.1", "port": 2222, "user": "workroom", "host_key": "ssh-ed25519 AAAA",
			"context": "colima",
		},
	}
	if err := cfg.AddRemoteWorkroom(app, "remote", "/home/workroom/remote", remote); err != nil {
		t.Fatal(err)
	}
	gone := map[string]any{"state": "destroyed", "driver": "boxd"}
	if err := cfg.AddRemoteWorkroom(app, "gone", "/home/workroom/gone", gone); err != nil {
		t.Fatal(err)
	}
	if err := cfg.SetBaseBranch(app, "develop"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.SetGlobalBaseBranch("main"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(empty, "git"); err != nil {
		t.Fatal(err)
	}

	run := runCLI(t, "list", "--json", "--warnings=full")
	if run.code != 0 {
		t.Fatalf("list: exit %d, %s", run.code, run.stdout)
	}
	checkContract(t, "list.json", run.stdout, home)
}

func TestContractCreate(t *testing.T) {
	home := contractHomeDir(t)
	project := gitRepo(t, filepath.Join(home, "src", "app"))
	writeProjectScript(t, project, "workroom_setup", "echo installing\necho done\n")
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(project, "git"); err != nil {
		t.Fatal(err)
	}

	run := runCLI(t, "create", "--json", "--no-editor", "--project", project)
	if run.code != 0 {
		t.Fatalf("create: exit %d, %s %s", run.code, run.stdout, run.stderr)
	}
	name := createdName(t, run.stdout)
	checkContract(t, "create.json", run.stdout, home, name, contractName)
	checkContract(t, "create-events.ndjson", run.stderr, home, name, contractName)
}

func TestContractCreateSetupFailed(t *testing.T) {
	home := contractHomeDir(t)
	project := gitRepo(t, filepath.Join(home, "src", "app"))
	writeProjectScript(t, project, "workroom_setup", "echo boom\nexit 3\n")

	run := runCLI(t, "create", "--json", "--no-editor", "--project", project)
	if run.code == 0 {
		t.Fatalf("create with a failing setup script exited 0: %s", run.stdout)
	}
	checkContract(t, "create-setup-failed.json", run.stdout, home, createdName(t, run.stdout), contractName)
}

// The app records a remote workroom before it makes the host (#253).
func TestContractCreateRemote(t *testing.T) {
	home := contractHomeDir(t)
	project := gitRepo(t, filepath.Join(home, "src", "app"))
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(project, "git"); err != nil {
		t.Fatal(err)
	}

	run := runCLI(t, "create", "--json", "--no-editor", "--project", project,
		"--host", `{"driver":"boxd","state":"creating"}`, "--host-path", "/home/workroom/app")
	if run.code != 0 {
		t.Fatalf("create --host: exit %d, %s", run.code, run.stdout)
	}
	checkContract(t, "create-remote.json", run.stdout, home, createdName(t, run.stdout), contractName)
}

func TestContractAddProject(t *testing.T) {
	home := contractHomeDir(t)
	project := gitRepo(t, filepath.Join(home, "src", "app"))

	run := runCLI(t, "add-project", project, "--json")
	if run.code != 0 {
		t.Fatalf("add-project: exit %d, %s", run.code, run.stdout)
	}
	checkContract(t, "add-project.json", run.stdout, home)

	plain := filepath.Join(home, "src", "plain")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	run = runCLI(t, "add-project", plain, "--json")
	if run.code == 0 {
		t.Fatalf("add-project on a directory that is no repository exited 0: %s", run.stdout)
	}
	checkContract(t, "add-project-unsupported-vcs.json", run.stdout, home)
}

// projectWithWorkroom is a registered project with one real workroom, named contractName, whose
// teardown script prints a line.
func projectWithWorkroom(t *testing.T, home string) string {
	t.Helper()
	project := gitRepo(t, filepath.Join(home, "src", "app"))
	path := filepath.Join(home, "workrooms", contractName)
	run(t, project, "git", "worktree", "add", "-q", "-b", "workroom/"+contractName, path)
	writeProjectScript(t, project, "workroom_teardown", "echo stopping\n")
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddWorkroom(project, contractName, path, "git"); err != nil {
		t.Fatal(err)
	}
	return project
}

func TestContractDelete(t *testing.T) {
	home := contractHomeDir(t)
	project := projectWithWorkroom(t, home)

	run := runCLI(t, "delete", contractName, "--json", "--project", project, "--confirm", contractName)
	if run.code != 0 {
		t.Fatalf("delete: exit %d, %s", run.code, run.stdout)
	}
	checkContract(t, "delete.json", run.stdout, home)
	checkContract(t, "delete-events.ndjson", run.stderr, home)
}

func TestContractDeleteProject(t *testing.T) {
	for _, mode := range []struct {
		file  string
		flags []string
	}{
		{"delete-project.json", nil},
		{"delete-project-with-workrooms.json", []string{"--with-workrooms"}},
		{"delete-project-from-disk.json", []string{"--from-disk"}},
	} {
		t.Run(mode.file, func(t *testing.T) {
			home := contractHomeDir(t)
			project := projectWithWorkroom(t, home)
			args := append([]string{"delete-project", project, "--json", "--confirm", project}, mode.flags...)
			run := runCLI(t, args...)
			if run.code != 0 {
				t.Fatalf("delete-project %v: exit %d, %s", mode.flags, run.code, run.stdout)
			}
			checkContract(t, mode.file, run.stdout, home)
			checkContract(t, strings.TrimSuffix(mode.file, ".json")+"-events.ndjson", run.stderr, home)
		})
	}
}
