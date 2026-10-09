package vcs

import (
	"fmt"
	"path/filepath"
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
// the main checkout has out; or from base, when the project names one. `--no-track`: a
// workroom's branch has no upstream until published. The returned string is a warning for the
// user, non-empty when the fetch failed and the start point may be out of date.
func (g *Git) Create(dir, vcsName, path, base string) (string, error) {
	start, warning, err := g.startPoint(dir, base)
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

// startPoint resolves where a new workroom's branch starts: origin/<base> then the local <base>
// when the project names a base, else origin's default branch. It fetches first so the ref is
// current, and prunes so a branch deleted on origin is not used from its stale copy; a failed
// fetch (offline, no credentials) keeps the last-fetched ref and returns a warning. A named base that resolves nowhere is an error. With no base and no origin/HEAD it
// returns "", so the caller passes no start point: git then uses HEAD, or makes an orphan
// branch in a repository with no commits, where an explicit HEAD is refused.
// `set-head --auto` because fetch never moves origin/HEAD after a default-branch rename.
func (g *Git) startPoint(dir, base string) (start, warning string, err error) {
	_, noOrigin := g.Executor.Run(dir, "git", "remote", "get-url", "origin")
	fetched := false
	if noOrigin == nil {
		if _, err := g.Executor.Run(dir, "git", "fetch", "--quiet", "--prune", "origin"); err == nil {
			fetched = true
			if base == "" {
				_, _ = g.Executor.Run(dir, "git", "remote", "set-head", "origin", "--auto")
			}
		}
	}
	// Fully qualified: a tag or branch named like the short form would make it ambiguous.
	var candidates []string
	if noOrigin == nil {
		if base == "" {
			candidates = append(candidates, "refs/remotes/origin/HEAD")
		} else {
			candidates = append(candidates, "refs/remotes/origin/"+base)
		}
	}
	if base != "" {
		candidates = append(candidates, "refs/heads/"+base)
	}
	for _, ref := range candidates {
		if _, err := g.Executor.Run(dir, "git", "rev-parse", "--verify", "--quiet", ref+"^{commit}"); err == nil {
			start = ref
			break
		}
	}
	if start == "" && base != "" {
		return "", "", fmt.Errorf("%w: '%s'", errs.ErrBaseBranchNotFound, base)
	}
	if noOrigin == nil && !fetched {
		warning = fmt.Sprintf("Could not fetch origin. The workroom starts from %s, which may be out of date.", g.refName(dir, start))
	}
	return start, warning, nil
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
