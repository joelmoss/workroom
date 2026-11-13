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
//	 ├── missing ──► MkdirAll           (the topmost folder made is removed on failure)
//	 └── an empty folder ──────────────  (emptied again on failure, but kept)
//	        ▼
//	 git clone --progress -- url path
//	  ├── ctx cancelled ──► ErrCancelled
//	  ├── git fails ──────► ErrCloneFailed, with git's own error lines
//	  └── ok ─► register
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

	made, err := cloneDestination(canon)
	if err != nil {
		return AddProjectResult{}, err
	}
	if s.Pretend {
		return AddProjectResult{Path: canon, VCS: "git", WouldClone: true}, nil
	}

	if made == "" {
		// An empty folder: Finder's junk would make git call it non-empty.
		if err := removeDirJunk(canon); err != nil {
			return AddProjectResult{}, err
		}
	} else if err := os.MkdirAll(canon, 0o755); err != nil {
		if errors.Is(err, syscall.ENOTDIR) {
			return AddProjectResult{}, errs.ErrNotDirectory
		}
		return AddProjectResult{}, fmt.Errorf("%w: create directory %s: %v", errs.ErrConfigWrite, canon, err)
	}
	// Whatever fails past here, the destination is left as it was found.
	defer func() {
		if retErr == nil {
			return
		}
		if made != "" {
			_ = os.RemoveAll(made)
		} else {
			_ = emptyDir(canon)
		}
	}()

	if err := runClone(ctx, url, canon, progress); err != nil {
		return AddProjectResult{}, err
	}

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

// cloneDestination checks canon can take a clone and reports the topmost folder a clone into it
// has to make: canon or a missing ancestor, or "" when canon is already an empty folder.
func cloneDestination(canon string) (string, error) {
	info, err := os.Stat(canon)
	switch {
	case err == nil && !info.IsDir():
		return "", errs.ErrNotDirectory
	case err == nil:
		empty, err := dirIsEmpty(canon)
		if err != nil {
			return "", err
		}
		if !empty {
			return "", fmt.Errorf("%w: %s", errs.ErrDestinationNotEmpty, canon)
		}
		return "", nil
	case errors.Is(err, syscall.ENOTDIR):
		return "", errs.ErrNotDirectory
	case !os.IsNotExist(err):
		return "", err
	}
	top := canon
	for parent := filepath.Dir(top); parent != top; parent = filepath.Dir(top) {
		if _, err := os.Stat(parent); err == nil {
			break
		}
		top = parent
	}
	return top, nil
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
