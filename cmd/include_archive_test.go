package cmd

import (
	"archive/tar"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// archiveMembers reads the tar at path: each member's name, mode and contents.
func archiveMembers(t *testing.T, path string) map[string]string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	members := map[string]string{}
	r := tar.NewReader(f)
	for {
		h, err := r.Next()
		if errors.Is(err, io.EOF) {
			return members
		}
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(r)
		members[h.Name] = os.FileMode(h.Mode).String() + " " + string(body)
	}
}

// Value: protects=the remote copy's archive holds exactly the included files with their modes, and
// stdout stays one JSON envelope listing them, their size and each file it couldn't read (ADR 0013);
// fails_when=the tar goes to stdout, a mode or member is wrong, or a failure goes unreported;
// no_claim=extraction on a host (see the app's tests)
func TestIncludeArchive(t *testing.T) {
	project := noRemoteProject(t)
	writeRootFile(t, project, ".gitignore", ".env\nsecrets/\n*.key\n")
	writeRootFile(t, project, ".worktreeinclude", ".env\nsecrets/\n*.key\n")
	writeRootFile(t, project, ".env", "SECRET=1")
	writeRootFile(t, project, "secrets/a.json", "{}")
	writeRootFile(t, project, "bad.key", "k")
	if err := os.Chmod(filepath.Join(project, ".env"), 0o600); err != nil {
		t.Fatal(err)
	}
	unreadable := os.Geteuid() != 0
	if unreadable {
		if err := os.Chmod(filepath.Join(project, "bad.key"), 0); err != nil {
			t.Fatal(err)
		}
	}
	archive := filepath.Join(t.TempDir(), "included.tar")

	run := runCLI(t, "include-archive", "--json", "--project", project, "--output", archive)
	if run.code != 0 {
		t.Fatalf("exit %d: %s %s", run.code, run.stdout, run.stderr)
	}
	var env struct {
		OK       bool     `json:"ok"`
		Command  string   `json:"command"`
		Paths    []string `json:"paths"`
		Count    int      `json:"count"`
		Bytes    int64    `json:"bytes"`
		Warnings []string `json:"warnings"`
	}
	if err := json.Unmarshal(run.stdout, &env); err != nil {
		t.Fatalf("stdout is not one JSON envelope: %v\n%s", err, run.stdout)
	}
	wantPaths := []string{".env", "secrets/a.json"}
	if !unreadable {
		wantPaths = []string{".env", "bad.key", "secrets/a.json"}
	}
	if !env.OK || env.Command != "include-archive" || !slices.Equal(env.Paths, wantPaths) || env.Count != len(wantPaths) {
		t.Fatalf("envelope = %+v, want paths %v", env, wantPaths)
	}
	if unreadable && (len(env.Warnings) != 1 || !strings.Contains(env.Warnings[0], "bad.key")) {
		t.Fatalf("warnings = %q, want one naming bad.key", env.Warnings)
	}
	if env.Bytes != int64(len("SECRET=1")+len("{}")) && unreadable {
		t.Fatalf("bytes = %d", env.Bytes)
	}
	members := archiveMembers(t, archive)
	if members[".env"] != "-rw------- SECRET=1" || members["secrets/a.json"] != "-rw-r--r-- {}" || len(members) != len(wantPaths) {
		t.Fatalf("archive = %q", members)
	}
}

// The include-archive envelope, as the app decodes it into IncludeArchive (CLIContractTests.swift).
func TestContractIncludeArchive(t *testing.T) {
	home := contractHomeDir(t)
	project := gitRepo(t, filepath.Join(home, "src", "app"))
	writeRootFile(t, project, ".gitignore", ".env\n")
	writeRootFile(t, project, ".worktreeinclude", ".env\n")
	writeRootFile(t, project, ".env", "SECRET=1")
	r := runCLI(t, "include-archive", "--json", "--project", project, "--output", filepath.Join(t.TempDir(), "a.tar"))
	if r.code != 0 {
		t.Fatalf("exit %d: %s", r.code, r.stdout)
	}
	checkContract(t, "include-archive.json", r.stdout, home)
}

// Value: protects=a root with no include file archives nothing and says so, without failing;
// fails_when=the command errors or invents files; no_claim=none beyond protects
func TestIncludeArchiveWithoutAnIncludeFile(t *testing.T) {
	project := noRemoteProject(t)
	archive := filepath.Join(t.TempDir(), "included.tar")
	run := runCLI(t, "include-archive", "--json", "--project", project, "--output", archive)
	var env struct {
		OK    bool     `json:"ok"`
		Paths []string `json:"paths"`
		Count int      `json:"count"`
	}
	if err := json.Unmarshal(run.stdout, &env); err != nil || run.code != 0 || !env.OK || env.Count != 0 || len(env.Paths) != 0 {
		t.Fatalf("exit %d, envelope %s, err %v", run.code, run.stdout, err)
	}
	if members := archiveMembers(t, archive); len(members) != 0 {
		t.Fatalf("archive = %q, want empty", members)
	}
}
