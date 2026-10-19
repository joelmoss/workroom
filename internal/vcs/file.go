package vcs

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"
	pathpkg "path"
	"strings"
)

// ErrLinkOutside is a file in a commit that is a symlink pointing outside the repository, whose
// bytes depend on where the checkout lands and so can't be read from the commit.
var ErrLinkOutside = errors.New("the file is a symlink outside the repository")

// FileAt is path's contents in commit rev ("" is HEAD) as a checkout of it writes them, with the
// repository's filters and line-ending conversion applied, and whether rev has it (#363). A
// symlink is followed within the commit, as running the checkout's file follows it; one that
// leaves the repository is ErrLinkOutside. A rev that names no commit, as HEAD in a repository
// with none, has no file.
func FileAt(dir, rev, path string) ([]byte, bool, error) {
	if rev == "" {
		rev = "HEAD"
	}
	if _, err := gitOutput(dir, nil, "rev-parse", "--verify", "--quiet", rev+"^{commit}"); err != nil {
		return nil, false, nil
	}
	// A chain of links is followed only so far: git refuses a longer one on checkout too.
	for range 8 {
		listed, err := gitOutput(dir, nil, "ls-tree", "-z", rev, "--", path)
		if err != nil {
			return nil, false, err
		}
		if len(bytes.TrimSpace(listed)) == 0 {
			return nil, false, nil
		}
		if !bytes.HasPrefix(listed, []byte("120000 ")) {
			out, err := gitOutput(dir, nil, "cat-file", "--filters", rev+":"+path)
			if err != nil {
				return nil, false, err
			}
			return out, true, nil
		}
		target, err := gitOutput(dir, nil, "cat-file", "blob", rev+":"+path)
		if err != nil {
			return nil, false, err
		}
		next := pathpkg.Join(pathpkg.Dir(path), string(target))
		if pathpkg.IsAbs(string(target)) || next == ".." || strings.HasPrefix(next, "../") {
			return nil, false, ErrLinkOutside
		}
		path = next
	}
	return nil, false, fmt.Errorf("%s: too many levels of symbolic links", path)
}

// Ignored reports whether git ignores path, relative to dir, in dir's checkout: an untracked file
// a pull never brings. A tracked file is never ignored, and any trouble asking git counts as not.
func Ignored(dir, path string) bool {
	cmd := exec.Command("git", "check-ignore", "-q", "--", path)
	cmd.Dir = dir
	cmd.Env = childEnvironment(dir)
	return cmd.Run() == nil
}
