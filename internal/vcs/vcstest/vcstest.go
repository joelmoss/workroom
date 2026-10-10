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
