package cmd

import (
	"os"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
)

// TestMain clears $WORKROOM_CONFIG, which a Dev build's terminals set: these tests point HOME at a
// temporary directory and expect the CLI's default config there, never the developer's own.
func TestMain(m *testing.M) {
	_ = os.Unsetenv(config.ConfigEnv)
	os.Exit(m.Run())
}
