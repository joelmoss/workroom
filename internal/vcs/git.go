package vcs

import (
	"path/filepath"
	"strings"
)

// Git implements VCS for Git worktrees.
type Git struct {
	Executor CommandExecutor
}

func (g *Git) Type() Type    { return TypeGit }
func (g *Git) Label() string { return "Git worktree" }

func (g *Git) Create(dir, vcsName, path string) (string, error) {
	return g.Executor.Run(dir, "git", "worktree", "add", "-b", vcsName, path)
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
