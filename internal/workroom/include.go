package workroom

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/joelmoss/workroom/internal/vcs"
)

// IncludeFile is the root's include file (#367): .gitignore-style patterns naming the gitignored
// files every new workroom gets a copy of. Only the root's copy counts, whatever the new
// workroom's branch, so a feature branch can't change which of the root's files are copied.
const IncludeFile = ".worktreeinclude"

// IncludedFiles is the root's included files, relative, slash-separated and sorted (as
// vcs.Included returns them): the regular
// files that match a pattern in the root's include file and that git ignores in the root. A
// symlink is never one, so nothing outside the root is ever copied. ok is false when the root has
// no include file.
func IncludedFiles(root string) (files []string, ok bool, err error) {
	patterns := filepath.Join(root, IncludeFile)
	if _, err := os.Stat(patterns); errors.Is(err, fs.ErrNotExist) {
		return nil, false, nil
	} else if err != nil {
		return nil, false, err
	}
	matched, err := vcs.Included(root, patterns)
	if err != nil {
		return nil, true, err
	}
	for _, f := range matched {
		if info, err := os.Lstat(filepath.Join(root, filepath.FromSlash(f))); err == nil && info.Mode().IsRegular() {
			files = append(files, f)
		}
	}
	return files, true, nil
}
