package workroom

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/script"
)

// CloneProject backs `add-project --clone` (#620): it clones url into the local path and registers
// the clone as a project. url is anything `git clone` accepts; path is local, so a remote path is
// refused as AddProject refuses it (ADR 0032). git's progress output streams to progress as it
// runs. git never prompts: it has no terminal and GIT_TERMINAL_PROMPT=0, so missing credentials
// fail fast instead of hanging.
//
//	stat(path)
//	 ├── a file ─────────────────────► ErrNotDirectory
//	 ├── a folder with files in it ──► ErrDestinationNotEmpty
//	 └── missing, or an empty folder
//	        ▼
//	 make missing parents; git clone --progress -- url <parent>/.<name>.clone-*   (the staging folder)
//	  ├── ctx cancelled ──► ErrCancelled
//	  ├── git fails ──────► ErrCloneFailed, with git's own error lines
//	  └── ok ─► rename staging onto path ─► register
//	              └── path filled meanwhile ──► ErrDestinationNotEmpty
//
// The clone happens in a staging folder of its own and is renamed into place, so a failure or a
// cancel only ever removes that staging folder, plus any parent folder this run made that is still
// empty. Nothing another run or the user wrote is touched: a concurrent clone into the same path or
// a sibling, or a file saved into a parent folder meanwhile, survives.
//
// Cancelling ctx (the CLI cancels it on SIGTERM) kills git's whole process group, so a transport
// helper or ssh it started dies with it. Under Pretend nothing is cloned or written.
func (s *Service) CloneProject(ctx context.Context, url, path string, progress io.Writer) (_ AddProjectResult, retErr error) {
	if isRemotePath(path) {
		return AddProjectResult{}, fmt.Errorf("%w: %s", errs.ErrRemoteProject, path)
	}
	canon, err := config.CanonicalPath(path)
	if err != nil {
		return AddProjectResult{}, err
	}

	existed, err := cloneDestination(canon)
	if err != nil {
		return AddProjectResult{}, err
	}
	if s.Pretend {
		return AddProjectResult{Path: canon, VCS: "git", WouldClone: true}, nil
	}

	made, err := mkdirParents(filepath.Dir(canon))
	if err != nil {
		return AddProjectResult{}, err
	}
	stage, err := os.MkdirTemp(filepath.Dir(canon), "."+filepath.Base(canon)+".clone-")
	if err != nil {
		removeEmptyDirs(made)
		return AddProjectResult{}, fmt.Errorf("%w: create staging folder for %s: %v", errs.ErrConfigWrite, canon, err)
	}
	moved := false
	defer func() {
		if retErr == nil {
			return
		}
		switch {
		case !moved:
			_ = os.RemoveAll(stage)
		case existed:
			// The rename put this run's clone, and only it, at canon.
			_ = emptyDir(canon)
		default:
			_ = os.RemoveAll(canon)
		}
		removeEmptyDirs(made)
	}()

	if err := runClone(ctx, url, stage, progress); err != nil {
		return AddProjectResult{}, err
	}
	if existed {
		// Finder's junk would make the rename refuse an otherwise empty folder.
		if err := removeDirJunk(canon); err != nil {
			return AddProjectResult{}, err
		}
	}
	// rename(2) itself, not os.Rename, which refuses any existing folder: it replaces an empty one
	// and refuses one that has filled up meanwhile.
	if err := syscall.Rename(stage, canon); err != nil {
		if errors.Is(err, syscall.ENOTEMPTY) || errors.Is(err, syscall.EEXIST) {
			return AddProjectResult{}, fmt.Errorf("%w: %s", errs.ErrDestinationNotEmpty, canon)
		}
		return AddProjectResult{}, fmt.Errorf("%w: move the clone to %s: %v", errs.ErrConfigWrite, canon, err)
	}
	moved = true

	// The clone now exists, so resolve it: a path under a symlinked parent is stored in its
	// symlink-evaluated form, as an existing project's is.
	if resolved, err := config.CanonicalPath(canon); err == nil {
		canon = resolved
	}
	if err := s.Config.AddProject(canon, "git"); err != nil {
		return AddProjectResult{}, err
	}
	return AddProjectResult{Path: canon, VCS: "git"}, nil
}

// cloneDestination checks canon can take a clone, reporting whether it already exists as an empty
// folder (false when it is missing).
func cloneDestination(canon string) (bool, error) {
	info, err := os.Stat(canon)
	switch {
	case err == nil && !info.IsDir():
		return false, errs.ErrNotDirectory
	case err == nil:
		empty, err := dirIsEmpty(canon)
		if err != nil {
			return false, err
		}
		if !empty {
			return false, fmt.Errorf("%w: %s", errs.ErrDestinationNotEmpty, canon)
		}
		return true, nil
	case errors.Is(err, syscall.ENOTDIR):
		return false, errs.ErrNotDirectory
	case !os.IsNotExist(err):
		return false, err
	}
	return false, nil
}

// mkdirParents makes dir and any missing folders above it, returning the ones this call created,
// outermost first. A folder another process creates meanwhile is used but not claimed.
func mkdirParents(dir string) ([]string, error) {
	var missing []string
	for d := dir; ; d = filepath.Dir(d) {
		if _, err := os.Stat(d); err == nil {
			break
		} else if errors.Is(err, syscall.ENOTDIR) {
			return nil, errs.ErrNotDirectory
		}
		missing = append(missing, d)
		if filepath.Dir(d) == d {
			break
		}
	}
	var made []string
	for i := len(missing) - 1; i >= 0; i-- {
		err := os.Mkdir(missing[i], 0o755)
		switch {
		case err == nil:
			made = append(made, missing[i])
		case errors.Is(err, os.ErrExist):
		case errors.Is(err, syscall.ENOTDIR):
			removeEmptyDirs(made)
			return nil, errs.ErrNotDirectory
		default:
			removeEmptyDirs(made)
			return nil, fmt.Errorf("%w: create directory %s: %v", errs.ErrConfigWrite, missing[i], err)
		}
	}
	return made, nil
}

// removeEmptyDirs removes the folders mkdirParents made, innermost first, leaving any that something
// else has written into.
func removeEmptyDirs(made []string) {
	for i := len(made) - 1; i >= 0; i-- {
		_ = os.Remove(made[i])
	}
}

// runClone runs git clone, streaming its stderr to progress and keeping it for the error.
func runClone(ctx context.Context, url, dest string, progress io.Writer) error {
	var stderr bytes.Buffer
	cmd := exec.Command("git", "clone", "--progress", "--", url, dest)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	cmd.Stdout = io.Discard
	cmd.Stderr = io.MultiWriter(progress, &stderr)
	script.SetProcessGroup(cmd)
	// A helper git started can hold the stderr pipe after git is gone; don't wait on it for long.
	cmd.WaitDelay = 2 * time.Second

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("%w: %v", errs.ErrCloneFailed, err)
	}
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			script.KillProcessGroup(cmd)
		case <-done:
		}
	}()
	err := cmd.Wait()
	close(done)

	if ctx.Err() != nil {
		return errs.ErrCancelled
	}
	if err != nil {
		if msg := cloneErrorLines(stderr.String()); msg != "" {
			return fmt.Errorf("%w: %s", errs.ErrCloneFailed, msg)
		}
		return fmt.Errorf("%w: %v", errs.ErrCloneFailed, err)
	}
	return nil
}

// cloneErrorLines is git clone's stderr without its progress: the "Cloning into" line and every
// "<what>: <n>% (…)" counter, \r-overwritten or finished. What's left is git's own account of
// the failure, which doesn't always say "fatal:" ("Permission denied (publickey).").
func cloneErrorLines(stderr string) string {
	var kept []string
	for _, line := range strings.FieldsFunc(stderr, func(r rune) bool { return r == '\n' || r == '\r' }) {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "Cloning into ") || strings.Contains(line, "% (") {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

// removeDirJunk deletes the entries dirIsEmpty ignores, so git sees the folder as empty too.
func removeDirJunk(dir string) error {
	for _, name := range finderJunk {
		if err := os.Remove(filepath.Join(dir, name)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

// emptyDir removes everything inside dir, leaving dir itself.
func emptyDir(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil {
			return err
		}
	}
	return nil
}
