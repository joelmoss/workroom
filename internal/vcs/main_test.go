package vcs

import (
	"os"
	"testing"

	"github.com/joelmoss/workroom/internal/vcs/vcstest"
)

// TestMain gives the tests' git a fixed identity (see vcstest.SetIdentity).
func TestMain(m *testing.M) {
	vcstest.SetIdentity()
	os.Exit(m.Run())
}
