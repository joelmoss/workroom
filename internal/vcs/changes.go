package vcs

import "bytes"

// StashCommit records the main checkout's uncommitted changes to tracked files, staged or not, as a
// stash commit nothing refers to, without touching the checkout (`git stash create`). "" when there
// are none.
func StashCommit(dir string) (string, error) {
	out, err := gitOutput(dir, nil, "stash", "create")
	return string(bytes.TrimSpace(out)), err
}

// ApplyStash applies a StashCommit to the checkout at dir.
func ApplyStash(dir, commit string) error {
	_, err := gitOutput(dir, nil, "stash", "apply", "--quiet", commit)
	return err
}

// Untracked is the checkout's untracked files that git doesn't ignore, relative to dir.
func Untracked(dir string) ([]string, error) {
	out, err := gitOutput(dir, nil, "ls-files", "-z", "--others", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	return splitNUL(out), nil
}

// HeadCommit is the commit the checkout at dir has out.
func HeadCommit(dir string) (string, error) {
	out, err := gitOutput(dir, nil, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
	return string(bytes.TrimSpace(out)), err
}
