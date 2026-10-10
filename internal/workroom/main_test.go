package workroom

import (
	"os"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs/vcstest"
)

// TestMain clears git's repository variables, which a git hook sets, so the tests' git stays in
// their temporary repositories (see vcstest.ClearRepoEnv).
func TestMain(m *testing.M) {
	vcstest.ClearRepoEnv()
	os.Exit(m.Run())
}
