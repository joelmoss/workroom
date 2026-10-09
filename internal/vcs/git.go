package vcs

import (
	"fmt"
	"path/filepath"
	"slices"
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
// the main checkout has out; or from base, when the project names one. fallback marks base as the
// app-wide default, which gives way to origin's default branch where it doesn't fit (see
// startPoint). `--no-track`: a workroom's branch has no upstream until published. The returned
// string is a warning for the user, non-empty when the start point may not be what they expect.
func (g *Git) Create(dir, vcsName, path, base string, fallback bool) (string, error) {
	start, warning, err := g.startPoint(dir, base, fallback)
	if err != nil {
		return "", err
	}
	args := []string{"worktree", "add", "-b", vcsName, path}
	if start != "" {
		args = []string{"worktree", "add", "--no-track", "-b", vcsName, path, start}
	}
	if _, err := g.Executor.Run(dir, "git", args...); err != nil {
		return "", err
	}
	return warning, nil
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
func (g *Git) startPoint(dir, base string, fallback bool) (start, warning string, err error) {
	out, _ := g.Executor.Run(dir, "git", "remote")
	remotes := strings.Fields(out)
	remote, branch := SplitBase(base, remotes)
	hasRemote := slices.Contains(remotes, remote)
	fetched := hasRemote && g.fetch(dir, remote, branch == "")
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
		return g.originDefault(dir, base, remotes, remote == "origin" && fetched)
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
func (g *Git) originDefault(dir, base string, remotes []string, originFetched bool) (start, warning string, err error) {
	if slices.Contains(remotes, "origin") {
		if originFetched {
			_, _ = g.Executor.Run(dir, "git", "remote", "set-head", "origin", "--auto")
		} else {
			originFetched = g.fetch(dir, "origin", true)
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
func (g *Git) fetch(dir, remote string, setHead bool) bool {
	if _, err := g.Executor.Run(dir, "git", "fetch", "--quiet", "--prune", remote); err != nil {
		return false
	}
	if setHead {
		_, _ = g.Executor.Run(dir, "git", "remote", "set-head", remote, "--auto")
	}
	return true
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
