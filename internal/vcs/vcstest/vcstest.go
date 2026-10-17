// Package vcstest holds test fixtures shared by packages that exercise VCS detection.
package vcstest

import (
	"os"
	"path/filepath"
	"testing"
)

// MakeGitDir gives dir the smallest `.git` that vcs.IsGitRepo (and git itself) accepts as a
// repository: a HEAD file plus objects/ and refs/ directories. A bare empty `.git` is not one.
func MakeGitDir(t testing.TB, dir string) {
	t.Helper()
	gitDir := filepath.Join(dir, ".git")
	for _, sub := range []string{"objects", "refs"} {
		if err := os.MkdirAll(filepath.Join(gitDir, sub), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(gitDir, "HEAD"), []byte("ref: refs/heads/main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// ClearRepoEnv unsets git's repository variables (`git rev-parse --local-env-vars`), which a git
// hook sets. A test process calls it from TestMain: an inherited GIT_DIR would point every git the
// tests run at the caller's checkout, not their temporary repositories.
func ClearRepoEnv() {
	for _, name := range []string{
		"GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
		"GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
		"GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX",
		"GIT_SHALLOW_FILE", "GIT_COMMON_DIR",
	} {
		_ = os.Unsetenv(name)
	}
}

// SetIdentity gives git a fixed author and committer. A test process calls it from TestMain: the
// tests point HOME at a temporary directory, so git has no user.email, and every ref it writes then
// guesses one from the hostname, a lookup that takes seconds on a Mac whose hostname does not
// resolve at once (5s per git process measured, which made `go test ./cmd` take 12 minutes).
func SetIdentity() {
	for _, kind := range []string{"AUTHOR", "COMMITTER"} {
		_ = os.Setenv("GIT_"+kind+"_NAME", "Workroom Tests")
		_ = os.Setenv("GIT_"+kind+"_EMAIL", "tests@workroom.invalid")
	}
}
