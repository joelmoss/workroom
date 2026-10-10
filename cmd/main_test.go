package cmd

import (
	"os"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/vcs/vcstest"
)

// TestMain clears $WORKROOM_CONFIG, which a Dev build's terminals set: these tests point HOME at a
// temporary directory and expect the CLI's default config there, never the developer's own. It
// clears git's repository variables too (see vcstest.ClearRepoEnv).
func TestMain(m *testing.M) {
	_ = os.Unsetenv(config.ConfigEnv)
	vcstest.ClearRepoEnv()
	os.Exit(m.Run())
}
