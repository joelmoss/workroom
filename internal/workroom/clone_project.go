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
//	stat(path)
//	 ├── a file ─────────────────────► ErrNotDirectory
//	 ├── a folder with files in it ──► ErrDestinationNotEmpty
//	 ├── an empty folder ──► git clone --progress -- url path/.clone-*   (the staging folder)
//	 │                        └── ok ─► move each entry up into path ─┐
//	 │                                   └── a name taken meanwhile ──► ErrDestinationNotEmpty
//	 └── missing ──► make missing parents; git clone --progress -- url <parent>/.<name>.clone-* (0755 less umask)
//	                  └── ok ─► rename staging to path ─────────────┐
//	                             └── path created meanwhile ──► ErrDestinationNotEmpty
//	  either clone ├── ctx cancelled ──► ErrCancelled                │
//	               └── git fails ──────► ErrCloneFailed, with git's own error lines
//	                                                                 ▼
//	                                      register ── fails ──► ErrConfigWrite; the clone is kept
//
// The clone happens in a staging folder of its own and is moved into place, so a failure or a
// cancel before then only ever removes that staging folder and what it moved, plus any parent folder
// this run made that is still empty. An existing folder is cloned into, never replaced, so it keeps
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
	host, hostOK := s.stagingHost()
	if !hostOK {
		host = "" // without a machine id no owned staging can be told apart from another machine's
	}
	staleInside, staleBeside := staleStagingFor(canon, host)
	if !s.Pretend {
		for _, dir := range append(staleInside, staleBeside...) {
			removeStaleStaging(dir)
		}
		staleInside = nil
	}
	existed, err := cloneDestination(canon, staleInside)
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
	stage, err := makeStaging(canon, existed, s.stagingOwner())
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
		removeEmptyDirs(made)
	}()

	if err := runClone(ctx, url, stage, progress); err != nil {
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

// makeStaging makes the folder the clone runs in: inside canon (.clone-*) when canon already
// exists, else beside it (.<name>.clone-*), made 0755 less the umask since it becomes canon itself.
func makeStaging(canon string, existed bool, owner string) (string, error) {
	if existed {
		stage, err := os.MkdirTemp(canon, ".clone-"+owner)
		if err != nil {
			return "", fmt.Errorf("%w: create staging folder in %s: %v", errs.ErrConfigWrite, canon, err)
		}
		return stage, nil
	}
	// os.Mkdir rather than MkdirTemp (always 0700, then chmodded): the new project folder takes the
	// user's umask like any folder they make, so a private umask keeps a private repo private.
	parent, prefix := filepath.Dir(canon), "."+filepath.Base(canon)+".clone-"+owner
	for range 100 {
		stage := filepath.Join(parent, prefix+strconv.FormatUint(uint64(rand.Uint32()), 36))
		err := os.Mkdir(stage, 0o755)
		if err == nil {
			return stage, nil
		}
		if !errors.Is(err, fs.ErrExist) {
			return "", fmt.Errorf("%w: create staging folder for %s: %v", errs.ErrConfigWrite, canon, err)
		}
	}
	return "", fmt.Errorf("%w: create staging folder for %s: no free name", errs.ErrConfigWrite, canon)
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
// entry it moves. It refuses if anything but Finder junk has appeared in canon, or if a clone entry
// would land on a name that is taken.
func moveUp(stage, canon string, placed *[]string) error {
	// Junk the clone might also hold (a tracked .DS_Store) would otherwise clash with Finder's.
	removeDirJunk(canon)
	others, err := os.ReadDir(canon)
	if err != nil {
		return err
	}
	for _, e := range others {
		if e.Name() != filepath.Base(stage) && !slices.Contains(finderJunk, e.Name()) {
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
				return false, fmt.Errorf("%w: %s (a clone's staging folder is in the way: %s; remove it if no clone is running)",
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

// runClone runs git clone, streaming its stderr to progress and keeping its tail for the error.
func runClone(ctx context.Context, url, dest string, progress io.Writer) error {
	var stderr tailBuffer
	cmd := exec.Command("git", "clone", "--progress", "--", url, dest)
	cmd.Env = cloneEnvironment(os.Environ())
	cmd.Stdout = io.Discard
	cmd.Stderr = io.MultiWriter(progress, &stderr)
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
// volume. The host part is a machine id: 8 random hex digits made once and kept beside the config
// file (so per machine and user, and unchanged by renaming the Mac or a network that rewrites its
// hostname). stagingHost reports false when the id can't be read or made.
func (s *Service) stagingHost() (string, bool) {
	if s.Config == nil {
		return "", false
	}
	path := filepath.Join(filepath.Dir(s.Config.Path()), "machine-id")
	if id, ok := readMachineID(path); ok {
		return id, true
	}
	id := fmt.Sprintf("%08x", rand.Uint32())
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		// Another run may have just made it.
		return readMachineID(path)
	}
	_, werr := f.WriteString(id + "\n")
	if cerr := f.Close(); werr != nil || cerr != nil {
		_ = os.Remove(path)
		return "", false
	}
	return id, true
}

// readMachineID reads a machine-id file, accepting only the 8 hex digits stagingHost writes.
func readMachineID(path string) (string, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	id := strings.TrimSpace(string(b))
	if len(id) != 8 || strings.Trim(id, "0123456789abcdef") != "" {
		return "", false
	}
	return id, true
}

// hostnameHash names staging when there is no machine id. Nothing is ever swept by it: an owned
// sweep needs a machine id.
func hostnameHash() string {
	name, err := os.Hostname()
	if err != nil {
		name = "unknown"
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(name))
	return fmt.Sprintf("%08x", h.Sum32())
}

// stagingOwner is the owner part of this process's staging names.
func (s *Service) stagingOwner() string {
	host, ok := s.stagingHost()
	if !ok {
		host = hostnameHash()
	}
	return host + "-" + strconv.Itoa(os.Getpid()) + "-"
}

// staleStagingFor lists the staging folders a dead clone into canon left: inside canon (only when it
// is a real folder) and beside it.
func staleStagingFor(canon, host string) (inside, beside []string) {
	if info, err := os.Lstat(canon); err == nil && info.IsDir() {
		inside = staleStaging(canon, ".clone-", host)
	}
	return inside, staleStaging(filepath.Dir(canon), "."+filepath.Base(canon)+".clone-", host)
}

// staleStaging lists the entries of dir named prefix<host>-<pid>-… that are provably a dead clone's:
// a real folder (never a symlink), made on this machine (host; "" when it has no machine id, which
// sweeps no owned name), by a process that is no longer running.
// Anything else stays (a live clone's, another machine's), except that a name without an owner, from
// before staging names carried one, is taken as abandoned once it has been idle staleUnownedAfter.
func staleStaging(dir, prefix, host string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var stale []string
	for _, e := range entries {
		rest, ok := strings.CutPrefix(e.Name(), prefix)
		if !ok || e.Type()&fs.ModeType != fs.ModeDir {
			continue
		}
		path := filepath.Join(dir, e.Name())
		parts := strings.SplitN(rest, "-", 3)
		if len(parts) != 3 {
			// No owner: named by a build before staging names carried one (#636). Only its age can
			// speak for it, so it goes once nothing in it has changed for staleUnownedAfter.
			if isUnownedStagingSuffix(rest, prefix == ".clone-") && looksUnfinished(path) &&
				time.Since(lastStagingActivity(path)) > staleUnownedAfter {
				stale = append(stale, path)
			}
			continue
		}
		if host == "" || parts[0] != host {
			continue
		}
		pid, err := strconv.Atoi(parts[1])
		if err != nil || pid <= 0 || processAlive(pid) {
			continue
		}
		stale = append(stale, path)
	}
	return stale
}

// removeStaleStaging removes a dead clone's staging folder, checking once more that it is still a
// real folder and not a symlink put in its place.
func removeStaleStaging(dir string) {
	if info, err := os.Lstat(dir); err == nil && info.IsDir() {
		_ = os.RemoveAll(dir)
	}
}

// dirIsEmptyExcept is dirIsEmpty, also passing over the given paths (a dead clone's staging, which
// --pretend leaves in place).
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

// staleUnownedAfter is how long an unowned staging folder must sit idle before it counts as a dead
// clone's. Idle means nothing that a running clone keeps touching has changed: see
// lastStagingActivity.
const staleUnownedAfter = time.Hour

// isUnownedStagingSuffix reports whether rest is the random tail an unowned staging name had: the
// decimal digits os.MkdirTemp appends (inside, and beside before #636's final build), or the base-36
// uint32 the #636 build's beside staging used (at most seven characters).
func isUnownedStagingSuffix(rest string, inside bool) bool {
	if n := len(rest); n == 0 || n > 10 {
		return false
	}
	digits := true
	for _, r := range rest {
		switch {
		case '0' <= r && r <= '9':
		case 'a' <= r && r <= 'z' && !inside:
			digits = false
		default:
			return false
		}
	}
	return digits || len(rest) <= 7
}

// looksUnfinished reports whether a folder is what a clone killed partway leaves: empty, or a .git
// with no index yet (git writes the index at checkout, its last step). A finished repository always
// has an index, so a folder of the user's that merely matches the name is never taken for staging.
func looksUnfinished(dir string) bool {
	if entries, err := os.ReadDir(dir); err == nil && len(entries) == 0 {
		return true
	}
	if info, err := os.Lstat(filepath.Join(dir, ".git")); err != nil || !info.IsDir() {
		return false
	}
	_, err := os.Lstat(filepath.Join(dir, ".git", "index"))
	return os.IsNotExist(err)
}

// lastStagingActivity is when a clone last visibly worked in its staging folder: the newest change
// to the folder itself, its .git, .git/index (written at checkout) and .git/objects/pack and the
// files in it, where a fetch's pack grows the whole time it downloads. A long clone that is still
// running therefore never looks idle, without walking a large checkout.
func lastStagingActivity(stage string) time.Time {
	var newest time.Time
	note := func(path string) {
		if info, err := os.Lstat(path); err == nil && info.ModTime().After(newest) {
			newest = info.ModTime()
		}
	}
	pack := filepath.Join(stage, ".git", "objects", "pack")
	for _, path := range []string{stage, filepath.Join(stage, ".git"), filepath.Join(stage, ".git", "index"), pack} {
		note(path)
	}
	if entries, err := os.ReadDir(pack); err == nil {
		for _, e := range entries {
			note(filepath.Join(pack, e.Name()))
		}
	}
	return newest
}

// stagingInTheWay names the .clone-* entries that alone keep dir from being empty (a clone still
// running, another machine's, or one the sweep couldn't prove dead or remove), or nil when anything
// else is there too.
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
		case strings.HasPrefix(name, ".clone-"):
			staging = append(staging, name)
		default:
			return nil
		}
	}
	return staging
}
