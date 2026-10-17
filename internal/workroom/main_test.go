package workroom

import (
	"os"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs/vcstest"
)

// TestMain clears git's repository variables, which a git hook sets, so the tests' git stays in
// their temporary repositories (see vcstest.ClearRepoEnv), and gives git a fixed identity (see
// vcstest.SetIdentity).
func TestMain(m *testing.M) {
	vcstest.ClearRepoEnv()
	vcstest.SetIdentity()
	os.Exit(m.Run())
}
