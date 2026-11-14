package workroom

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"io/fs"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/script"
)

// CloneProject backs `add-project --clone` (#620): it clones url into the local path and registers
// the clone as a project. url is anything `git clone` accepts; path is local, so a remote path is
// refused as AddProject refuses it (ADR 0032). git's progress output streams to progress as it
// runs. git never prompts: it runs in a session of its own with no controlling terminal and
// GIT_TERMINAL_PROMPT=0, so missing credentials fail fast instead of hanging. It inherits none of
// the repository variables (GIT_DIR, GIT_INDEX_FILE, …) a git hook or alias would pass down.
//
//	sweep a dead clone's staging in path and beside it ── ctx cancelled ──► ErrCancelled
//	stat(path)
//	 ├── a file ─────────────────────► ErrNotDirectory
//	 ├── a folder with files in it ──► ErrDestinationNotEmpty (naming any staging in the way)
//	 ├── an empty folder ──► lock path/.clone-*.lock; git clone --progress -- url path/.clone-*
//	 │                        └── ok ─► move each entry up into path ─┐
//	 │                                   └── a name taken meanwhile ──► ErrDestinationNotEmpty
//	 └── missing ──► make missing parents; lock <parent>/.<name>.clone-*.lock;
//	                 git clone --progress -- url <parent>/.<name>.clone-* (0755 less umask)
//	                  └── ok ─► rename staging to path ─────────────┐
//	                             └── path created meanwhile ──► ErrDestinationNotEmpty
//	  either clone ├── ctx cancelled ──► ErrCancelled                │
//	               └── git fails ──────► ErrCloneFailed, with git's own error lines
//	                                                                 ▼
//	                                      remove the lock; register ── fails ──► ErrConfigWrite; the clone is kept
//
// The clone happens in a staging folder of its own and is moved into place, so a failure or a
// cancel before then only ever removes that staging folder, its lock file and what it moved, plus any
// parent folder this run made that is still empty. An existing folder is cloned into, never replaced, so it keeps
// its mode, ACLs, xattrs and Finder tags, the staging folder never crosses filesystems (an external
// drive's root, a mount point), and nothing renames over a directory, which Windows can't do.
// Nothing another run or the user wrote is touched: a concurrent clone into the same path or a
// sibling, or a file saved into a parent folder meanwhile, survives. Finder junk (.DS_Store,
// .localized) in the folder is no obstacle. Once the clone is in place it is kept, even if
// registering it fails.
//
// Cancelling ctx (the CLI cancels it on SIGTERM) SIGTERMs git's whole process group, so a transport
// helper or ssh it started dies with it, and SIGKILLs what is left after cloneKillGrace or once git
// has exited. Under Pretend nothing is cloned or written.
func (s *Service) CloneProject(ctx context.Context, url, path string, progress io.Writer) (_ AddProjectResult, retErr error) {
	if isRemotePath(path) {
		return AddProjectResult{}, fmt.Errorf("%w: %s", errs.ErrRemoteProject, path)
	}
	canon, err := config.CanonicalPath(path)
	if err != nil {
		return AddProjectResult{}, err
	}

	// Staging a crashed or killed clone left behind would make the destination look taken. What is
	// provably dead is swept first (not under Pretend, which only looks past it).
	host, hostOK := machineHost()
	if !hostOK {
		host = "" // without a machine id no owned staging can be told apart from another machine's
	}
	staleInside, staleBeside := staleStagingFor(canon, host)
	var ignore []string
	if s.Pretend {
		for _, st := range staleInside {
			ignore = append(ignore, st.paths()...)
		}
		releaseAll(append(staleInside, staleBeside...))
	} else if err := removeStale(ctx, progress, append(staleInside, staleBeside...)); err != nil {
		return AddProjectResult{}, err
	}
	existed, err := cloneDestination(canon, ignore)
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
	stage, lock, err := makeStaging(canon, existed, stagingOwner())
	if err != nil {
		removeEmptyDirs(made)
		return AddProjectResult{}, err
	}
	var placed []string // what moveUp has put in canon so far
	published := false  // the whole clone is at canon: from here on it is kept
	defer func() {
		if retErr == nil || published {
			return
		}
		for _, name := range placed {
			_ = os.RemoveAll(filepath.Join(canon, name))
		}
		_ = os.RemoveAll(stage)
		// The lock goes last, so no sweep sees the staging unlocked, and before the parents, which
		// it may be the last thing in.
		releaseStagingLock(lock, stage)
		removeEmptyDirs(made)
	}()

	if err := runClone(ctx, url, stage, progress, lock); err != nil {
		return AddProjectResult{}, err
	}
	if existed {
		err = moveUp(stage, canon, &placed)
	} else {
		err = renameInto(stage, canon)
	}
	if err != nil {
		return AddProjectResult{}, err
	}
	published = true
	releaseStagingLock(lock, stage)

	// The clone now exists, so resolve it: a path under a symlinked parent is stored in its
	// symlink-evaluated form, as an existing project's is.
	if resolved, err := config.CanonicalPath(canon); err == nil {
		canon = resolved
	}
	if err := s.Config.AddProject(canon, "git"); err != nil {
		return AddProjectResult{}, fmt.Errorf("%w: the clone is at %s but could not be registered: %v", errs.ErrConfigWrite, canon, err)
	}
	return AddProjectResult{Path: canon, VCS: "git"}, nil
}

// makeStaging makes the folder the clone runs in: inside canon (.clone-*, 0700) when canon already
// exists, else beside it (.<name>.clone-*), made 0755 less the umask since it becomes canon itself.
// Its lock file (the staging name plus .lock, beside the folder) is made and locked first, so a
// sweep never sees this run's staging unlocked; lock is nil where there is no lock (Windows, a
// filesystem without flock), which leaves the pid in the name to speak for the run.
func makeStaging(canon string, existed bool, owner string) (stage string, lock *os.File, err error) {
	parent, prefix, mode := canon, ".clone-"+owner, fs.FileMode(0o700)
	if !existed {
		// The new project folder takes the user's umask like any folder they make, so a private
		// umask keeps a private repo private.
		parent, prefix, mode = filepath.Dir(canon), "."+filepath.Base(canon)+".clone-"+owner, 0o755
	}
	for range 100 {
		stage := filepath.Join(parent, prefix+strconv.FormatUint(uint64(rand.Uint32()), 36))
		lock, err := createStagingLock(stage + ".lock")
		switch {
		case errors.Is(err, fs.ErrExist), errors.Is(err, errLockLost):
			continue
		case errors.Is(err, errLockUnsupported):
			lock = nil
		case err != nil:
			return "", nil, fmt.Errorf("%w: create staging lock for %s: %v", errs.ErrConfigWrite, canon, err)
		}
		err = os.Mkdir(stage, mode)
		if err == nil {
			return stage, lock, nil
		}
		releaseStagingLock(lock, stage)
		if !errors.Is(err, fs.ErrExist) {
			return "", nil, fmt.Errorf("%w: create staging folder for %s: %v", errs.ErrConfigWrite, canon, err)
		}
	}
	return "", nil, fmt.Errorf("%w: create staging folder for %s: no free name", errs.ErrConfigWrite, canon)
}

// releaseStagingLock removes a staging folder's lock file and then closes it. It never unlocks
// (LOCK_UN would release git's inherited hold too); closing drops only this process's.
func releaseStagingLock(lock *os.File, stage string) {
	if lock == nil {
		return
	}
	_ = os.Remove(stage + ".lock")
	_ = lock.Close()
}

// renameInto renames the staging folder to canon, which did not exist when the clone started. If
// something has created canon meanwhile the rename fails (os.Rename refuses an existing folder on
// Unix; Windows refuses any existing path), and canon then existing is what says why, the error
// itself differing by platform (EEXIST, ENOTEMPTY, ENOTDIR, access denied, already exists).
func renameInto(stage, canon string) error {
	if err := os.Rename(stage, canon); err != nil {
		if _, statErr := os.Lstat(canon); statErr == nil {
			return fmt.Errorf("%w: %s", errs.ErrDestinationNotEmpty, canon)
		}
		return fmt.Errorf("%w: move the clone to %s: %v", errs.ErrConfigWrite, canon, err)
	}
	return nil
}

// moveUp moves the clone out of a staging folder inside canon into canon itself, recording each
// entry it moves. It refuses if anything but Finder junk and the staging's own lock file has appeared
// in canon, or if a clone entry would land on a name that is taken.
func moveUp(stage, canon string, placed *[]string) error {
	// Junk the clone might also hold (a tracked .DS_Store) would otherwise clash with Finder's.
	removeDirJunk(canon)
	others, err := os.ReadDir(canon)
	if err != nil {
		return err
	}
	for _, e := range others {
		if e.Name() != filepath.Base(stage) && e.Name() != filepath.Base(stage)+".lock" && !slices.Contains(finderJunk, e.Name()) {
			return fmt.Errorf("%w: %s", errs.ErrDestinationNotEmpty, canon)
		}
	}
	entries, err := os.ReadDir(stage)
	if err != nil {
		return err
	}
	for _, e := range entries {
		to := filepath.Join(canon, e.Name())
		if _, err := os.Lstat(to); err == nil {
			return fmt.Errorf("%w: %s", errs.ErrDestinationNotEmpty, canon)
		}
		if err := os.Rename(filepath.Join(stage, e.Name()), to); err != nil {
			if _, statErr := os.Lstat(filepath.Join(stage, e.Name())); statErr != nil {
				// It moved after all; claim it so a cleanup removes it.
				*placed = append(*placed, e.Name())
			} else if _, statErr := os.Lstat(to); statErr == nil {
				return fmt.Errorf("%w: %s", errs.ErrDestinationNotEmpty, canon)
			}
			return fmt.Errorf("%w: move the clone to %s: %v", errs.ErrConfigWrite, canon, err)
		}
		*placed = append(*placed, e.Name())
	}
	return os.Remove(stage)
}

// cloneDestination checks canon can take a clone, reporting whether it already exists as an empty
// folder (false when it is missing).
func cloneDestination(canon string, ignore []string) (bool, error) {
	// A symlink left at canon is one CanonicalPath couldn't resolve: it points nowhere (an unmounted
	// drive, say). It is refused, not taken for a missing folder and replaced by the clone.
	if info, err := os.Lstat(canon); err == nil && info.Mode()&fs.ModeSymlink != 0 {
		return false, errs.ErrNotDirectory
	}
	info, err := os.Stat(canon)
	switch {
	case err == nil && !info.IsDir():
		return false, errs.ErrNotDirectory
	case err == nil:
		empty, err := dirIsEmptyExcept(canon, ignore)
		if err != nil {
			return false, err
		}
		if !empty {
			if blocking := stagingInTheWay(canon, ignore); len(blocking) > 0 {
				return false, fmt.Errorf("%w: %s (a clone's staging is in the way: %s; remove it if no clone is running)",
					errs.ErrDestinationNotEmpty, canon, strings.Join(blocking, ", "))
			}
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

// cloneKillGrace is how long git's process group has to exit after the SIGTERM a cancel sends it,
// before a SIGKILL.
const cloneKillGrace = 3 * time.Second

// runClone runs git clone, streaming its stderr to progress and keeping its tail for the error. git
// inherits lock (when there is one) as an extra open file, so it and every helper it starts hold the
// staging's lock too: a clone whose CLI was SIGKILLed still counts as alive while any of them runs.
func runClone(ctx context.Context, url, dest string, progress io.Writer, lock *os.File) error {
	var stderr tailBuffer
	cmd := exec.Command("git", "clone", "--progress", "--", url, dest)
	cmd.Env = cloneEnvironment(os.Environ())
	cmd.Stdout = io.Discard
	cmd.Stderr = io.MultiWriter(progress, &stderr)
	if lock != nil {
		cmd.ExtraFiles = []*os.File{lock}
	}
	script.SetSession(cmd)
	// A helper git started can hold the stderr pipe after git is gone; don't wait on it for long.
	cmd.WaitDelay = 2 * time.Second

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("%w: %v", errs.ErrCloneFailed, err)
	}
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
		case <-done:
			return
		}
		// Both may be ready at once: once git is reaped its group id is free for reuse, so never
		// signal it after done.
		select {
		case <-done:
			return
		default:
		}
		script.KillProcessGroup(cmd)
		select {
		case <-done:
		case <-time.After(cloneKillGrace):
			script.KillProcessGroupHard(cmd)
		}
	}()
	err := cmd.Wait()
	close(done)

	if ctx.Err() != nil {
		// git is gone. A member of its group that ignored the SIGTERM (a helper still holding stderr)
		// keeps the group id allocated, so SIGKILLing the group then reaches only it; with no member
		// left the id is free for reuse and is not signalled.
		if script.ProcessGroupAlive(cmd) {
			script.KillProcessGroupHard(cmd)
		}
		return errs.ErrCancelled
	}
	if err != nil && errors.Is(err, exec.ErrWaitDelay) && cmd.ProcessState != nil && cmd.ProcessState.Success() {
		// git exited 0; only a helper it left behind kept stderr open.
		err = nil
	}
	if err != nil {
		if msg := cloneErrorLines(stderr.String()); msg != "" {
			return fmt.Errorf("%w: %s", errs.ErrCloneFailed, msg)
		}
		return fmt.Errorf("%w: %v", errs.ErrCloneFailed, err)
	}
	return nil
}

// cloneRepoVariables are the inherited variables that would aim the clone at another repository's
// files, which a `workroom` run from a git hook or alias inherits: internal/vcs's gitRedirects
// (unexported, so mirrored here) plus GIT_NAMESPACE, GIT_PREFIX and the rest of `git rev-parse
// --local-env-vars` but its config variables. git's config, ssh and protocol variables
// (GIT_CONFIG*, GIT_SSH_COMMAND, GIT_ASKPASS, GIT_ALLOW_PROTOCOL…) are the user's and are kept.
var cloneRepoVariables = []string{
	"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
	"GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX",
	"GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE",
	"GIT_SHALLOW_FILE",
}

// cloneEnvironment is env without cloneRepoVariables, and with GIT_TERMINAL_PROMPT=0. Names
// compare case-insensitively, as Windows does.
func cloneEnvironment(env []string) []string {
	out := make([]string, 0, len(env)+1)
	for _, kv := range env {
		key, _, _ := strings.Cut(kv, "=")
		if strings.EqualFold(key, "GIT_TERMINAL_PROMPT") ||
			slices.ContainsFunc(cloneRepoVariables, func(v string) bool { return strings.EqualFold(v, key) }) {
			continue
		}
		out = append(out, kv)
	}
	return append(out, "GIT_TERMINAL_PROMPT=0")
}

// cloneStderrCap is how much of git's stderr runClone keeps for the error: its tail, where git
// says why it failed. A server streaming progress forever can't grow it further.
const cloneStderrCap = 64 << 10

// tailBuffer is an io.Writer that keeps only the last cloneStderrCap bytes written to it.
type tailBuffer struct {
	buf       []byte
	truncated bool
}

// Write never fails, so an io.MultiWriter carrying it keeps streaming.
func (b *tailBuffer) Write(p []byte) (int, error) {
	n := len(p)
	if len(p) >= cloneStderrCap {
		p = p[len(p)-cloneStderrCap:]
		b.buf = b.buf[:0]
		b.truncated = true
	} else if over := len(b.buf) + len(p) - cloneStderrCap; over > 0 {
		b.buf = b.buf[over:]
		b.truncated = true
	}
	b.buf = append(b.buf, p...)
	return n, nil
}

// String is what is kept, without the line the cap cut into, which a filter could mistake for an
// error line.
func (b *tailBuffer) String() string {
	s := string(b.buf)
	if b.truncated {
		if i := strings.IndexAny(s, "\r\n"); i >= 0 {
			return s[i+1:]
		}
		return ""
	}
	return s
}

// cloneErrorLines is git clone's stderr without its progress: the "Cloning into" line, every
// "<what>: <n>% (…)" counter, \r-overwritten or finished, every finished "…, done." line, and the
// server's own object counts ("remote: Counting objects: 5", "remote: Total …"). What's left is
// git's own account of the failure, which doesn't always say "fatal:" ("Permission denied
// (publickey).", "remote: Repository not found.").
func cloneErrorLines(stderr string) string {
	var kept []string
	for _, line := range strings.FieldsFunc(stderr, func(r rune) bool { return r == '\n' || r == '\r' }) {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "Cloning into ") || strings.Contains(line, "% (") ||
			strings.HasSuffix(line, ", done.") || isRemoteProgress(line) {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

// remoteProgress are the prefixes of the server's progress lines that carry no percentage.
var remoteProgress = []string{
	"remote: Enumerating objects:", "remote: Counting objects:", "remote: Compressing objects:", "remote: Total ",
}

func isRemoteProgress(line string) bool {
	return slices.ContainsFunc(remoteProgress, func(p string) bool { return strings.HasPrefix(line, p) })
}

// removeDirJunk deletes, best-effort, the entries dirIsEmpty ignores. What it can't remove moveUp
// still tolerates.
func removeDirJunk(dir string) {
	for _, name := range finderJunk {
		_ = os.Remove(filepath.Join(dir, name))
	}
}

// Staging names carry their owner, `<host>-<pid>-` after the `.clone-` prefix, so a later clone can
// tell a crashed run's leftovers from a clone still running, here or on another machine sharing the
// volume. The host part is machineHost: an 8-hex hash of the machine's hardware id, read rather than
// stored, so it needs nothing written (--pretend stays read-only) and is unchanged by renaming the
// machine or a network that rewrites its hostname. It reports false when the machine has no id.
var machineHost = sync.OnceValues(func() (string, bool) {
	id, ok := machineID()
	if !ok {
		return "", false
	}
	return fnvHex(id), true
})

// fnvHex is s as 8 hex digits: its FNV-32a hash.
func fnvHex(s string) string {
	h := fnv.New32a()
	_, _ = h.Write([]byte(s))
	return fmt.Sprintf("%08x", h.Sum32())
}

// hostnameHash names staging when there is no machine id. Nothing is ever swept by it: an owned
// sweep needs a machine id.
func hostnameHash() string {
	name, err := os.Hostname()
	if err != nil {
		name = "unknown"
	}
	return fnvHex(name)
}

// stagingOwner is the owner part of this process's staging names.
func stagingOwner() string {
	host, ok := machineHost()
	if !ok {
		host = hostnameHash()
	}
	return host + "-" + strconv.Itoa(os.Getpid()) + "-"
}

// Lock-file errors createStagingLock reports.
var (
	errLockUnsupported = errors.New("staging locks are not supported here")
	errLockLost        = errors.New("a sweep took the staging lock")
)

// lockState is what probeStagingLock found a staging lock file to say about its clone.
type lockState int

const (
	lockHeld        lockState = iota // its clone, or a git it started, is running
	lockFree                         // nothing holds it: its clone is dead
	lockMissing                      // there is no lock file
	lockUnsupported                  // the platform or filesystem can't say
)

// staleStage is a dead clone's leftovers: its staging folder ("" when only an orphan lock file is
// left) and its lock file ("" when it has none), with that lock held by this process while the
// sweep removes them, so the dead run's name can't be reused under it.
type staleStage struct {
	dir, lock string
	held      *os.File
}

// paths are what the stale leftovers occupy.
func (st staleStage) paths() []string {
	var p []string
	for _, path := range []string{st.dir, st.lock} {
		if path != "" {
			p = append(p, path)
		}
	}
	return p
}

// name is how the sweep's progress line names the leftovers.
func (st staleStage) name() string {
	if st.dir != "" {
		return filepath.Base(st.dir)
	}
	return filepath.Base(st.lock)
}

// remove removes the staging folder, checking once more that it is still a real folder and not a
// symlink put in its place, then its lock file, and only then lets go of the lock.
func (st staleStage) remove() {
	if st.dir != "" {
		if info, err := os.Lstat(st.dir); err == nil && info.IsDir() {
			_ = os.RemoveAll(st.dir)
		}
	}
	if st.held != nil {
		_ = os.Remove(st.lock)
		_ = st.held.Close()
	}
}

// releaseAll lets go of the locks the sweep took, without removing anything.
func releaseAll(stale []staleStage) {
	for _, st := range stale {
		if st.held != nil {
			_ = st.held.Close()
		}
	}
}

// staleStagingFor lists what a dead clone into canon left: inside canon (only when it is a real
// folder) and beside it.
func staleStagingFor(canon, host string) (inside, beside []staleStage) {
	if info, err := os.Lstat(canon); err == nil && info.IsDir() {
		inside = staleStaging(canon, ".clone-", host)
	}
	return inside, staleStaging(filepath.Dir(canon), "."+filepath.Base(canon)+".clone-", host)
}

// staleStaging lists the entries of dir named prefix<host>-<pid>-… that are provably a dead clone's,
// made on this machine (host; "" when it has no machine id, which sweeps nothing). A real folder
// (never a symlink) is dead when its lock file is free, or, with no lock file to ask (staging from
// before the lock, or where locks aren't supported), when its pid is no longer running; a held lock
// keeps it whatever its pid, since git outlives a SIGKILLed CLI. A lock file whose folder is gone is
// dead once free. A name without an owner is never removed: nothing can speak for it.
func staleStaging(dir, prefix, host string) []staleStage {
	if host == "" {
		return nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var stale []staleStage
	for _, e := range entries {
		name := e.Name()
		stagingName, isLock := strings.CutSuffix(name, ".lock")
		rest, ok := strings.CutPrefix(stagingName, prefix)
		if !ok {
			continue
		}
		parts := strings.SplitN(rest, "-", 3)
		if len(parts) != 3 || parts[0] != host {
			continue
		}
		pid, err := strconv.Atoi(parts[1])
		if err != nil || pid <= 0 {
			continue
		}
		stage := filepath.Join(dir, stagingName)
		if isLock {
			if !e.Type().IsRegular() {
				continue
			}
			if _, err := os.Lstat(stage); !os.IsNotExist(err) {
				continue // judged with its folder
			}
			if held, state := probeStagingLock(stage + ".lock"); state == lockFree {
				stale = append(stale, staleStage{lock: stage + ".lock", held: held})
			}
			continue
		}
		if e.Type()&fs.ModeType != fs.ModeDir {
			continue
		}
		switch held, state := probeStagingLock(stage + ".lock"); state {
		case lockFree:
			stale = append(stale, staleStage{dir: stage, lock: stage + ".lock", held: held})
		case lockMissing, lockUnsupported:
			if !processAlive(pid) {
				stale = append(stale, staleStage{dir: stage})
			}
		}
	}
	return stale
}

// removeStale removes what dead clones left, saying so on progress first. A cancel stops it at
// once with ErrCancelled: a folder left half-removed is still a dead clone's, swept next time.
func removeStale(ctx context.Context, progress io.Writer, stale []staleStage) error {
	for i, st := range stale {
		if ctx.Err() != nil {
			releaseAll(stale[i:])
			return errs.ErrCancelled
		}
		_, _ = fmt.Fprintf(progress, "Removing staging a crashed clone left: %s\n", st.name())
		done := make(chan struct{})
		go func() {
			defer close(done)
			st.remove()
		}()
		select {
		case <-done:
		case <-ctx.Done():
			releaseAll(stale[i+1:])
			return errs.ErrCancelled
		}
	}
	return nil
}

// dirIsEmptyExcept is dirIsEmpty, also passing over the given paths (a dead clone's staging and lock
// file, which --pretend leaves in place).
func dirIsEmptyExcept(dir string, ignore []string) (bool, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false, err
	}
	for _, e := range entries {
		if slices.Contains(finderJunk, e.Name()) || slices.Contains(ignore, filepath.Join(dir, e.Name())) {
			continue
		}
		return false, nil
	}
	return true, nil
}

// stagingInTheWay names the staging-shaped entries (a .clone-* folder or .clone-*.lock file) that
// alone keep dir from being empty: a clone still running, another machine's, one without an owner
// in its name, or one the sweep couldn't remove. It is nil when anything else is there too, a
// .clone-notes file of the user's included.
func stagingInTheWay(dir string, ignore []string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var staging []string
	for _, e := range entries {
		name := e.Name()
		switch {
		case slices.Contains(finderJunk, name) || slices.Contains(ignore, filepath.Join(dir, name)):
		case strings.HasPrefix(name, ".clone-") && (e.Type()&fs.ModeType == fs.ModeDir ||
			e.Type().IsRegular() && strings.HasSuffix(name, ".lock")):
			staging = append(staging, name)
		default:
			return nil
		}
	}
	return staging
}
