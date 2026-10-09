package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
)

// Value: protects=the app's `claim-provisioned --json --from --provisioner` call and its envelope;
// fails_when=a flag is renamed or made optional, or the moved count leaves the envelope;
// why_new=internal/config/claim_test.go covers the move, not the command the app runs; seam=none
func TestClaimProvisionedMovesABuildsEntriesIntoItsConfig(t *testing.T) {
	const dev = "com.developwithstyle.workroom.dev"
	dir := t.TempDir()
	shared, mine := filepath.Join(dir, "shared.json"), filepath.Join(dir, "mine.json")
	room := map[string]any{"path": "/home/boxd/a", "host": map[string]any{"provisioner": dev, "id": "w"}}
	data, _ := json.Marshal(map[string]any{
		"/a": map[string]any{"vcs": "git", "workrooms": map[string]any{"room": room}},
	})
	if err := os.WriteFile(shared, data, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv(config.ConfigEnv, mine)

	// The app always names both: without the build, nothing may move.
	if code, _ := runHostCLI(t, "claim-provisioned", "--json", "--from", shared); code == 0 {
		t.Fatal("claimed without --provisioner")
	}
	code, envelope := runHostCLI(t, "claim-provisioned", "--json", "--from", shared, "--provisioner", dev)
	if code != 0 || envelope["ok"] != true || envelope["moved"] != float64(1) {
		t.Fatalf("exit %d, envelope %v", code, envelope)
	}
	cfg, _ := config.New("")
	projects, err := cfg.AllProjects()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := projects["/a"].Workrooms["room"]; !ok {
		t.Fatalf("the build's config holds %v", projects)
	}
}
