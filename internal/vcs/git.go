package vcs

import (
	"fmt"
	"io"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/joelmoss/workroom/internal/errs"
)

// Git implements VCS for Git worktrees.
type Git struct {
	Executor CommandExecutor
}

func (g *Git) Type() Type    { return TypeGit }
func (g *Git) Label() string { return "Git worktree" }

// Create branches from origin's default branch, as a remote workroom does, not from whatever
// the main checkout has out; or from base, when the project names one. BeforeWorktree is told
// the local work that start leaves out, and may switch to the local branch (the user's choice,
// workroom.Start). fallback marks base as the app-wide default, which gives way to origin's
// default branch where it doesn't fit (see startPoint). `--no-track`: a workroom's branch has no
// upstream until published. The returned string is a warning for the user, non-empty when the
// start point may not be what they expect.
func (g *Git) Create(dir, vcsName, path, base string, fallback bool, progress Progress) (string, error) {
	fs := &fetchStep{progress: progress}
	start, warning, err := g.startPoint(dir, base, fallback, fs)
	if err != nil {
		fs.finish(warning, err)
		return "", err
	}
	if progress.BeforeWorktree != nil {
		// A start that already warns (a failed fetch, a fallback) is compared all the same, so a
		// start the user chose still holds, but marked stale: nobody is asked against it.
		work := g.LocalWork(dir, start)
		work.Stale = warning != ""
		remoteStart := start
		if start, err = progress.BeforeWorktree(start, work); err != nil {
			fs.finish(warning, nil)
			return "", err
		}
		// The warning was about the remote's copy; a start switched to the local branch says what
		// it really is instead.
		if warning != "" && start != remoteStart {
			warning = localStartWarning(base, remoteStart, work, fs.failed)
		}
	}
	// The fetch step carries the start-point warning, so it ends only once the start is settled:
	// its row and the create's notice then say the same.
	fs.finish(warning, nil)
	progress.step("worktree", "running", "")
	args := []string{"worktree", "add", "-b", vcsName, path}
	if start != "" {
		args = []string{"worktree", "add", "--no-track", "-b", vcsName, path, start}
	}
	if _, err := g.run(progress.Log, dir, args...); err != nil {
		progress.step("worktree", "failed", err.Error())
		return "", err
	}
	progress.step("worktree", "done", "")
	return warning, nil
}

// localStartWarning is the warning for a start switched to the local branch against a remote copy
// that came with one: why the default base wasn't used, if it wasn't, that the workroom starts from
// the local branch, and, when the fetch failed, that it couldn't be checked against the remote.
func localStartWarning(base, remoteStart string, work LocalWork, fetchFailed bool) string {
	var parts []string
	// originDefault's fallback: the app-wide default base gave way to origin's default branch.
	if base != "" && remoteStart == "refs/remotes/origin/HEAD" {
		parts = append(parts, fmt.Sprintf("The default base branch %s doesn't exist in this project.", base))
	}
	parts = append(parts, fmt.Sprintf("The workroom starts from your local %s, as you chose.", work.Branch))
	if fetchFailed {
		parts = append(parts, fmt.Sprintf("It couldn't be checked against %s, so it may differ from what's there.", work.Remote))
	}
	return strings.Join(parts, " ")
}

// StartPoint is startPoint with its fetch reported as the create's fetch step.
func (g *Git) StartPoint(dir, base string, fallback bool, progress Progress) (string, string, error) {
	fs := &fetchStep{progress: progress}
	start, warning, err := g.startPoint(dir, base, fallback, fs)
	fs.finish(warning, err)
	return start, warning, err
}

// run is git in dir; with a log it writes "$ git <args>" and then the combined output there.
func (g *Git) run(log io.Writer, dir string, args ...string) (string, error) {
	if log != nil {
		fmt.Fprintf(log, "$ git %s\n", strings.Join(args, " "))
	}
	out, err := g.Executor.Run(dir, "git", args...)
	if log != nil && out != "" {
		fmt.Fprintln(log, out)
	}
	return out, err
}

// fetchStep reports the create's fetch step. The step stays unannounced until a fetch is
// attempted, so a project with no remote goes straight to skipped.
type fetchStep struct {
	progress          Progress
	attempted, failed bool
}

// finish closes the step once startPoint is done, which is after any fetch in originDefault. The
// step owns startPoint's outcome: a base found nowhere fails it, and any start-point warning ends it.
func (f *fetchStep) finish(warning string, err error) {
	switch {
	case err != nil:
		if f.progress.Log != nil {
			fmt.Fprintln(f.progress.Log, err.Error())
		}
		f.progress.step("fetch", "failed", err.Error())
	case warning != "":
		f.progress.step("fetch", "warning", warning)
	case !f.attempted:
		f.progress.step("fetch", "skipped", "No remote to fetch from")
	default:
		f.progress.step("fetch", "done", "")
	}
}

// SplitBase reads a base branch setting: "<remote>/<branch>" when the part before the first "/"
// is one of remotes, else a branch on origin. So `upstream/main` is upstream's main, `origin/main`
// is plain `main`, and `release/1.0` stays an origin branch unless a remote is named "release".
// The macOS app applies the same rule (RemoteWorkrooms.splitBase).
func SplitBase(base string, remotes []string) (remote, branch string) {
	if r, rest, ok := strings.Cut(base, "/"); ok && rest != "" && slices.Contains(remotes, r) {
		return r, rest
	}
	return "origin", base
}

// startPoint resolves where a new workroom's branch starts: <remote>/<branch> then the local
// <branch> when there is a base (see SplitBase), else origin's default branch. It fetches that
// remote first so the ref is current, and prunes so a branch deleted there is not used from its
// stale copy; a failed fetch (offline, no credentials) keeps the last-fetched ref and returns a
// warning. A base that resolves nowhere is an error, and so is one that couldn't be looked for
// because the fetch failed. With fallback (the app-wide default), a base the fetched remote and
// the local branches both lack gives way to origin's default branch, with a warning. With no
// base and no origin/HEAD it returns "", so the caller passes no start point: git then uses HEAD,
// or makes an orphan branch in a repository with no commits, where an explicit HEAD is refused.
func (g *Git) startPoint(dir, base string, fallback bool, fs *fetchStep) (start, warning string, err error) {
	out, _ := g.Executor.Run(dir, "git", "remote")
	remotes := strings.Fields(out)
	remote, branch := SplitBase(base, remotes)
	hasRemote := slices.Contains(remotes, remote)
	fetched := hasRemote && g.fetch(dir, remote, branch == "", fs)
	// Fully qualified: a tag or branch named like the short form would make it ambiguous.
	var candidates []string
	if hasRemote {
		if branch == "" {
			candidates = append(candidates, "refs/remotes/"+remote+"/HEAD")
		} else {
			candidates = append(candidates, "refs/remotes/"+remote+"/"+branch)
		}
	}
	if branch != "" {
		candidates = append(candidates, "refs/heads/"+branch)
	}
	start = g.firstRef(dir, candidates)
	if start == "" && branch != "" {
		switch {
		case hasRemote && !fetched:
			return "", "", fmt.Errorf("%w: '%s' (could not fetch %s to look there)", errs.ErrBaseBranchNotFound, base, remote)
		case !fallback:
			return "", "", fmt.Errorf("%w: '%s'", errs.ErrBaseBranchNotFound, base)
		}
		return g.originDefault(dir, base, remotes, remote == "origin" && fetched, fs)
	}
	switch {
	case hasRemote && !fetched:
		warning = fmt.Sprintf("Could not fetch %s. The workroom starts from %s, which may be out of date.", remote, g.refName(dir, start))
	case hasRemote && strings.HasPrefix(start, "refs/heads/"):
		// The remote answered without the base: deleted there after a merge, or never pushed. The
		// local copy can be far behind, so say which one this is.
		warning = fmt.Sprintf("%s has no %s, so the workroom starts from your local %s, which may be out of date.", remote, branch, branch)
	}
	return start, warning, nil
}

// originDefault is origin's default branch for an app-wide default base that doesn't exist in
// this project. Origin is fetched only if the base named another remote; otherwise its fetch for
// the base already happened (originFetched), so a create never fetches the same remote twice.
func (g *Git) originDefault(dir, base string, remotes []string, originFetched bool, fs *fetchStep) (start, warning string, err error) {
	if slices.Contains(remotes, "origin") {
		if originFetched {
			_, _ = g.Executor.Run(dir, "git", "remote", "set-head", "origin", "--auto")
		} else {
			originFetched = g.fetch(dir, "origin", true, fs)
		}
		start = g.firstRef(dir, []string{"refs/remotes/origin/HEAD"})
	}
	warning = fmt.Sprintf("The default base branch %s doesn't exist in this project, so the workroom starts from %s.", base, g.refName(dir, start))
	if slices.Contains(remotes, "origin") && !originFetched {
		warning += " Could not fetch origin, so it may be out of date."
	}
	return start, warning, nil
}

// fetch fetches remote, pruned, and with setHead refreshes its HEAD, which fetch never moves after
// a default-branch rename. It reports whether the fetch worked.
func (g *Git) fetch(dir, remote string, setHead bool, fs *fetchStep) bool {
	if !fs.attempted {
		fs.progress.step("fetch", "running", "")
	}
	fs.attempted = true
	if _, err := g.run(fs.progress.Log, dir, "fetch", "--prune", remote); err != nil {
		fs.failed = true
		return false
	}
	if setHead {
		_, _ = g.Executor.Run(dir, "git", "remote", "set-head", remote, "--auto")
	}
	return true
}

// LocalWork compares start, a remote's branch such as refs/remotes/origin/HEAD, with the local
// branch of the same name and with the main checkout at dir.
func (g *Git) LocalWork(dir, start string) LocalWork {
	rest, ok := strings.CutPrefix(start, "refs/remotes/")
	if !ok {
		return LocalWork{}
	}
	// origin/HEAD stands for the branch it points to.
	if strings.HasSuffix(rest, "/HEAD") {
		target, err := g.Executor.Run(dir, "git", "symbolic-ref", "--quiet", start)
		if err != nil {
			return LocalWork{}
		}
		rest = strings.TrimPrefix(target, "refs/remotes/")
	}
	remote, branch, ok := strings.Cut(rest, "/")
	if !ok || g.firstRef(dir, []string{"refs/heads/" + branch}) == "" {
		return LocalWork{}
	}
	work := LocalWork{Branch: branch, Remote: remote}
	// "<behind>\t<ahead>": the start's commits the local branch lacks, then the local branch's.
	if out, err := g.Executor.Run(dir, "git", "rev-list", "--left-right", "--count", start+"...refs/heads/"+branch); err == nil {
		if behind, ahead, ok := strings.Cut(out, "\t"); ok {
			work.Behind, _ = strconv.Atoi(behind)
			work.Ahead, _ = strconv.Atoi(ahead)
		}
	}
	if head, err := g.Executor.Run(dir, "git", "symbolic-ref", "--quiet", "--short", "HEAD"); err == nil && head == branch {
		status, err := g.Executor.Run(dir, "git", "status", "--porcelain")
		work.Uncommitted = err == nil && status != ""
	}
	return work
}

// firstRef is the first of refs that names a commit, or "".
func (g *Git) firstRef(dir string, refs []string) string {
	for _, ref := range refs {
		if _, err := g.Executor.Run(dir, "git", "rev-parse", "--verify", "--quiet", ref+"^{commit}"); err == nil {
			return ref
		}
	}
	return ""
}

// refName is ref as a user knows it: origin/HEAD as the branch it points to, such as origin/main.
func (g *Git) refName(dir, ref string) string {
	if ref == "" {
		return "HEAD"
	}
	if out, err := g.Executor.Run(dir, "git", "rev-parse", "--abbrev-ref", ref); err == nil && out != "" {
		return out
	}
	return ref
}

func (g *Git) Delete(dir, _, path string) (string, error) {
	return g.Executor.Run(dir, "git", "worktree", "remove", path, "--force")
}

// Init runs `git init` in dir, creating a new empty Git repository.
func (g *Git) Init(dir string) (string, error) {
	return g.Executor.Run(dir, "git", "init")
}

// InitialCommit creates an empty initial commit so a freshly-init'd repo has a
// HEAD (workroom creation branches from it; on git < 2.42 `git worktree add`
// otherwise fails on a zero-commit repo). Identity and signing are pinned via
// `-c` overrides and hooks skipped with `--no-verify` so the commit succeeds on
// a brand-new machine with no global git config (no user.name/email,
// commit.gpgsign=true, or template hooks) — the exact first-run case.
func (g *Git) InitialCommit(dir string) (string, error) {
	return g.Executor.Run(dir, "git",
		"-c", "user.name=Workroom",
		"-c", "user.email=workroom@localhost",
		"-c", "commit.gpgsign=false",
		"commit", "--allow-empty", "--no-verify", "-m", "Initial commit")
}

func (g *Git) ListWorkrooms(dir string) ([]string, error) {
	paths, err := g.listWorktreePaths(dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, p := range paths {
		names = append(names, filepath.Base(p))
	}
	return names, nil
}

func (g *Git) listWorktreePaths(dir string) ([]string, error) {
	out, err := g.Executor.Run(dir, "git", "worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	return parseGitWorktrees(out, dir), nil
}

func parseGitWorktrees(output, cwd string) []string {
	var result []string
	var directory string
	for _, line := range strings.Split(output, "\n") {
		if strings.HasPrefix(line, "worktree ") {
			directory = strings.TrimPrefix(line, "worktree ")
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if fields[0] == "HEAD" && directory != cwd {
			result = append(result, directory)
		}
	}
	return result
}
