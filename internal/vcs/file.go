package vcs

import (
	"bytes"
	"os/exec"
)

// FileAt is path's contents in commit rev ("" is HEAD) as a checkout of it writes them, with the
// repository's filters and line-ending conversion applied, and whether rev has it (#363). A rev
// that names no commit, as HEAD in a repository with none, has no file.
func FileAt(dir, rev, path string) ([]byte, bool, error) {
	if rev == "" {
		rev = "HEAD"
	}
	if _, err := gitOutput(dir, nil, "rev-parse", "--verify", "--quiet", rev+"^{commit}"); err != nil {
		return nil, false, nil
	}
	listed, err := gitOutput(dir, nil, "ls-tree", "-z", rev, "--", path)
	if err != nil {
		return nil, false, err
	}
	if len(bytes.TrimSpace(listed)) == 0 {
		return nil, false, nil
	}
	out, err := gitOutput(dir, nil, "cat-file", "--filters", rev+":"+path)
	if err != nil {
		return nil, false, err
	}
	return out, true, nil
}

// Ignored reports whether git ignores path, relative to dir, in dir's checkout: an untracked file
// a pull never brings. A tracked file is never ignored, and any trouble asking git counts as not.
func Ignored(dir, path string) bool {
	cmd := exec.Command("git", "check-ignore", "-q", "--", path)
	cmd.Dir = dir
	cmd.Env = childEnvironment(dir)
	return cmd.Run() == nil
}
