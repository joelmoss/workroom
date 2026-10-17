package workroom

import (
	"archive/tar"
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

// Included is what a root's include file matches: the files to copy, and the symlinks that matched
// but are never copied, so a step can say why a symlinked .env didn't arrive. Both are relative,
// slash-separated and sorted, as vcs.Included returns them.
type Included struct {
	Files    []string
	Symlinks []string
}

// IncludedFiles is the root's included files: the regular files that match a pattern in the root's
// include file and that git ignores in the root. A symlink is never one, so nothing outside the root
// is ever copied; it is reported in Symlinks instead. ok is false when the root has no include file.
func IncludedFiles(root string) (inc Included, ok bool, err error) {
	patterns := filepath.Join(root, IncludeFile)
	if _, err := os.Stat(patterns); errors.Is(err, fs.ErrNotExist) {
		return inc, false, nil
	} else if err != nil {
		return inc, false, err
	}
	matched, err := vcs.Included(root, patterns)
	if err != nil {
		return inc, true, err
	}
	for _, f := range matched {
		info, err := os.Lstat(filepath.Join(root, filepath.FromSlash(f)))
		switch {
		case err != nil:
		case info.Mode().IsRegular():
			inc.Files = append(inc.Files, f)
		case info.Mode()&fs.ModeSymlink != 0:
			inc.Symlinks = append(inc.Symlinks, f)
		}
	}
	return inc, true, nil
}

// SkippedSymlink is the log line for a symlink the include file matched but that isn't copied.
func SkippedSymlink(path string) string { return fmt.Sprintf("Skipped %s: it's a symlink", path) }

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

// ArchiveIncluded writes files (IncludedFiles' paths) from root to w as a tar, for a remote
// workroom's host to extract (#367): each a regular member with its mode. A file that can't be
// read is reported and the rest are still written, as CopyIncluded does. A member name must stay
// inside the checkout it is extracted into, so one that wouldn't is refused. An error is one that
// leaves the archive itself unusable.
func ArchiveIncluded(root string, files []string, w io.Writer) (IncludeCopy, error) {
	var res IncludeCopy
	tw := tar.NewWriter(w)
	for _, f := range files {
		if !filepath.IsLocal(filepath.FromSlash(f)) {
			res.Failures = append(res.Failures, fmt.Sprintf("%s: not a path inside the root", f))
			continue
		}
		src, err := os.Open(filepath.Join(root, filepath.FromSlash(f)))
		if err != nil {
			res.Failures = append(res.Failures, fmt.Sprintf("%s: %v", f, err))
			continue
		}
		n, err := archiveFile(tw, f, src)
		_ = src.Close()
		if err != nil {
			return res, err
		}
		res.Copied = append(res.Copied, f)
		res.Bytes += n
	}
	return res, tw.Close()
}

// archiveFile writes src to tw as the member name, with src's mode, size and time.
func archiveFile(tw *tar.Writer, name string, src *os.File) (int64, error) {
	info, err := src.Stat()
	if err != nil {
		return 0, err
	}
	header := &tar.Header{
		Typeflag: tar.TypeReg, Name: name, Mode: int64(info.Mode().Perm()), Size: info.Size(),
		ModTime: info.ModTime(), Format: tar.FormatPAX,
	}
	if err := tw.WriteHeader(header); err != nil {
		return 0, err
	}
	// Exactly the size the header gave: a file that grew since is cut there, and one that shrank
	// fails the archive rather than writing a short member.
	return io.CopyN(tw, src, info.Size())
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
