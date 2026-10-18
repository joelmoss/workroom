package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// Value: protects=the --skip-teardown flag on delete and delete-project (the app's Delete Anyway) reaching the service, and a failed teardown exiting 5 TeardownScriptFailed; fails_when=a command stops setting SkipTeardown or drops the flag; why_new=service tests set SkipTeardown directly, nothing runs the real command; seam=none; no_claim=remote hosts
func TestDeleteSkipTeardownThroughTheCLI(t *testing.T) {
	for _, tc := range []struct {
		name string
		args func(project string) []string
	}{
		{"delete", func(p string) []string {
			return []string{"delete", contractName, "--json", "--project", p, "--confirm", contractName}
		}},
		{"delete-project", func(p string) []string {
			return []string{"delete-project", p, "--json", "--confirm", p, "--with-workrooms"}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := contractHomeDir(t)
			project := projectWithWorkroom(t, home)
			marker := filepath.Join(home, "teardown-ran")
			writeProjectScript(t, project, "workroom_teardown", "touch "+marker+"\nexit 1\n")

			// Without the flag, the failing teardown stops the delete (exit 5) and the workroom stays.
			run := runCLI(t, tc.args(project)...)
			var env struct {
				Error struct {
					Kind string `json:"kind"`
				} `json:"error"`
			}
			if err := json.Unmarshal(run.stdout, &env); err != nil {
				t.Fatalf("not one JSON envelope: %q", run.stdout)
			}
			if run.code != 5 || env.Error.Kind != "TeardownScriptFailed" {
				t.Fatalf("exit %d kind %q, want 5 TeardownScriptFailed: %s", run.code, env.Error.Kind, run.stdout)
			}
			if _, err := os.Stat(marker); err != nil {
				t.Fatalf("the teardown script did not run: %v", err)
			}
			if err := os.Remove(marker); err != nil {
				t.Fatal(err)
			}

			// With it, the script does not run and the delete goes through.
			run = runCLI(t, append(tc.args(project), "--skip-teardown")...)
			if run.code != 0 {
				t.Fatalf("exit %d with --skip-teardown: %s", run.code, run.stdout)
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatal("the teardown script ran despite --skip-teardown")
			}
			if _, err := os.Stat(filepath.Join(home, "workrooms", contractName)); !os.IsNotExist(err) {
				t.Fatalf("the workroom is still on disk: %v", err)
			}
		})
	}
}
