package workroom

import (
	"errors"
	"fmt"
	"io"
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

// IncludeCopy is what copying a root's included files into a workroom did: the files copied and
// their total size, and each file that couldn't be, as "path: reason".
type IncludeCopy struct {
	Copied   []string
	Bytes    int64
	Failures []string
}

// CopyIncluded copies files (IncludedFiles' paths) from root into dest, the new workroom, keeping
// each file's mode exactly: the mode is set after the write, since a mode given at create time is
// filtered by the umask. A file dest already has is left as it is. A file that can't be copied is
// reported and the rest still are, so one unreadable key never costs the others.
func CopyIncluded(root, dest string, files []string) IncludeCopy {
	var res IncludeCopy
	for _, f := range files {
		to := filepath.Join(dest, filepath.FromSlash(f))
		if _, err := os.Lstat(to); err == nil {
			continue
		}
		n, err := copyFile(filepath.Join(root, filepath.FromSlash(f)), to)
		if err != nil {
			res.Failures = append(res.Failures, fmt.Sprintf("%s: %v", f, err))
			continue
		}
		res.Copied = append(res.Copied, f)
		res.Bytes += n
	}
	return res
}

// copyFile copies the regular file from to a new file to, with from's mode, and removes what it
// wrote if the copy fails part way.
func copyFile(from, to string) (int64, error) {
	src, err := os.Open(from)
	if err != nil {
		return 0, err
	}
	defer src.Close()
	info, err := src.Stat()
	if err != nil {
		return 0, err
	}
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return 0, err
	}
	dst, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return 0, err
	}
	n, err := io.Copy(dst, src)
	if closeErr := dst.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Chmod(to, info.Mode().Perm())
	}
	if err != nil {
		_ = os.Remove(to)
		return 0, err
	}
	return n, nil
}
