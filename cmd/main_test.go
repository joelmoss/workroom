package cmd

import (
	"os"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
)

// TestMain clears $WORKROOM_CONFIG, which a Dev build's terminals set: these tests point HOME at a
// temporary directory and expect the CLI's default config there, never the developer's own. It
// clears git's repository variables (`git rev-parse --local-env-vars`) too, which a git hook sets:
// an inherited GIT_DIR would point the tests' git at the developer's checkout, not their own
// temporary repositories.
func TestMain(m *testing.M) {
	_ = os.Unsetenv(config.ConfigEnv)
	for _, name := range []string{
		"GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
		"GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
		"GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX",
		"GIT_SHALLOW_FILE", "GIT_COMMON_DIR",
	} {
		_ = os.Unsetenv(name)
	}
	os.Exit(m.Run())
}
