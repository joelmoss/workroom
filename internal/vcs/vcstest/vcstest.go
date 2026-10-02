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
