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
// repository's filters and line-ending conversion applied, and whether rev has it as a file (#363).
// A symlink anywhere along the path (the file itself, or a linked directory such as scripts/) is
// followed within the commit, as running the checkout's file follows it; one that leaves the
// repository is ErrLinkOutside. A rev that names no commit, as HEAD in a repository with none, has
// no file, and neither has a path that is a directory or a submodule.
func FileAt(dir, rev, path string) ([]byte, bool, error) {
	if rev == "" {
		rev = "HEAD"
	}
	if _, err := gitOutput(dir, nil, "rev-parse", "--verify", "--quiet", rev+"^{commit}"); err != nil {
		return nil, false, nil
	}
	// A chain of links is followed only so far, as the system follows one only so far.
	for hops := 0; hops <= 8; {
		parts := strings.Split(path, "/")
		linked := false
		for i := range parts {
			prefix := strings.Join(parts[:i+1], "/")
			mode, err := treeMode(dir, rev, prefix)
			if err != nil {
				return nil, false, err
			}
			switch {
			case mode == "":
				return nil, false, nil
			case mode == "120000":
				target, err := gitOutput(dir, nil, "cat-file", "blob", rev+":"+prefix)
				if err != nil {
					return nil, false, err
				}
				if pathpkg.IsAbs(string(target)) {
					return nil, false, ErrLinkOutside
				}
				next := pathpkg.Join(append([]string{pathpkg.Dir(prefix), string(target)}, parts[i+1:]...)...)
				if next == ".." || strings.HasPrefix(next, "../") {
					return nil, false, ErrLinkOutside
				}
				path, linked = next, true
				hops++
			case i < len(parts)-1 && mode != "040000":
				return nil, false, nil
			case i == len(parts)-1 && mode != "100644" && mode != "100755":
				return nil, false, nil
			}
			if linked {
				break
			}
		}
		if !linked {
			out, err := filteredBlob(dir, rev, path)
			if err != nil {
				return nil, false, err
			}
			return out, true, nil
		}
	}
	return nil, false, fmt.Errorf("%s: too many levels of symbolic links", path)
}

// filteredBlob is path in rev converted by rev's own .gitattributes (--attr-source), as a checkout
// of rev converts it: the root's attributes can differ, as when a branch changes its line endings.
// A git older than 2.40 has no --attr-source and falls back to the root's attributes.
func filteredBlob(dir, rev, path string) ([]byte, error) {
	out, err := gitOutput(dir, nil, "--attr-source="+rev, "cat-file", "--filters", rev+":"+path)
	if err != nil && strings.Contains(err.Error(), "unknown option") {
		return gitOutput(dir, nil, "cat-file", "--filters", rev+":"+path)
	}
	return out, err
}

// treeMode is the mode of path in commit rev, such as 100755, 120000 (a symlink) or 040000 (a
// directory), or "" when rev has nothing there.
func treeMode(dir, rev, path string) (string, error) {
	// Without a trailing slash, a directory is listed as its own entry, not its contents.
	listed, err := gitOutput(dir, nil, "ls-tree", "-z", rev, "--", path)
	if err != nil {
		return "", err
	}
	mode, _, _ := strings.Cut(string(bytes.TrimSpace(listed)), " ")
	return mode, nil
}

// Ignored reports whether git ignores path, relative to dir, in dir's checkout: an untracked file
// a pull never brings. A tracked file is never ignored, and any trouble asking git counts as not.
func Ignored(dir, path string) bool {
	cmd := exec.Command("git", "check-ignore", "-q", "--", path)
	cmd.Dir = dir
	cmd.Env = childEnvironment(dir)
	return cmd.Run() == nil
}
