//go:build !windows

package workroom

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

// createStagingLock makes and locks a new lock file at path. It reports fs.ErrExist when the name is
// taken and errLockLost when a sweep took the fresh file before it was locked (the caller tries
// another name), and errLockUnsupported when the filesystem has no flock; the file is then removed,
// so no unlocked lock file sits beside live staging for a sweep to take for a dead clone's.
func createStagingLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			// A sweep or a --pretend probe has it. The file is this run's (O_EXCL), and left behind
			// it would block the folder this run is about to clone into.
			_ = os.Remove(path)
			return nil, errLockLost
		}
		_ = os.Remove(path)
		return nil, fmt.Errorf("%w: %v", errLockUnsupported, err)
	}
	if !sameFileAt(f, path) {
		// A sweep removed it between the create and the lock.
		_ = f.Close()
		return nil, errLockLost
	}
	return f, nil
}

// probeStagingLock tries a staging lock file's lock without waiting, opening it read-only so
// --pretend writes nothing. lockFree hands back the file, still locked; lockMissing means there is no
// lock file to judge by; lockUnsupported that the filesystem can't say. Anything else it can't
// settle is lockHeld, which keeps the staging.
func probeStagingLock(path string) (*os.File, lockState) {
	// O_NONBLOCK: a FIFO planted at the path would otherwise block this open until a writer came.
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return nil, lockMissing
	case err != nil:
		return nil, lockHeld
	}
	if info, err := f.Stat(); err != nil || !info.Mode().IsRegular() {
		_ = f.Close()
		return nil, lockHeld
	}
	err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	switch {
	case err == nil && sameFileAt(f, path):
		return f, lockFree
	case errors.Is(err, syscall.ENOTSUP), errors.Is(err, syscall.EOPNOTSUPP), errors.Is(err, syscall.ENOLCK):
		_ = f.Close()
		return nil, lockUnsupported
	default:
		_ = f.Close()
		return nil, lockHeld
	}
}

// sameFileAt reports whether f is still the file at path.
func sameFileAt(f *os.File, path string) bool {
	open, err := f.Stat()
	if err != nil {
		return false
	}
	named, err := os.Lstat(path)
	return err == nil && os.SameFile(open, named)
}
