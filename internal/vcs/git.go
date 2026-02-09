package vcs

import (
	"path/filepath"
	"strings"
)

// Git implements VCS for Git worktrees.
type Git struct {
	Executor CommandExecutor
}

func (g *Git) Type() Type  { return TypeGit }
func (g *Git) Label() string { return "Git worktree" }

func (g *Git) WorkroomExists(dir, name string) (bool, error) {
	worktrees, err := g.listWorktreePaths(dir)
	if err != nil {
		return false, err
	}
	for _, path := range worktrees {
		if filepath.Base(path) == name {
			return true, nil
		}
	}
	return false, nil
}

func (g *Git) Create(dir, vcsName, path string) (string, error) {
	return g.Executor.Run(dir, "git", "worktree", "add", "-b", vcsName, path)
}

func (g *Git) Delete(dir, _, path string) (string, error) {
	return g.Executor.Run(dir, "git", "worktree", "remove", path, "--force")
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
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if fields[0] == "worktree" {
			directory = fields[1]
		}
		if fields[0] == "HEAD" && directory != cwd {
			result = append(result, directory)
		}
	}
	return result
}
