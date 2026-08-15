package vcs

import (
	"strings"
)

// JJ implements VCS for Jujutsu workspaces.
type JJ struct {
	Executor CommandExecutor
}

func (j *JJ) Type() Type    { return TypeJJ }
func (j *JJ) Label() string { return "JJ workspace" }

func (j *JJ) Create(dir, vcsName, path string) (string, error) {
	return j.Executor.Run(dir, "jj", "workspace", "add", path, "--name", vcsName)
}

func (j *JJ) Delete(dir, vcsName, _ string) (string, error) {
	return j.Executor.Run(dir, "jj", "workspace", "forget", vcsName)
}

func (j *JJ) ListWorkrooms(dir string) ([]string, error) {
	out, err := j.Executor.Run(dir, "jj", "workspace", "list", "--color", "never")
	if err != nil {
		return nil, err
	}
	return parseJJWorkspaces(out), nil
}

// parseJJWorkspaces returns the bare workroom name for each listed jj workspace, stripping the
// "workroom/" prefix this program itself applies at creation time (Create). This CLI is the sole
// creator of that prefix, so stripping it here — rather than leaving it on — makes JJ agree with
// Git.ListWorkrooms, which already returns bare worktree-directory basenames. A hand-made jj
// workspace with no such prefix (e.g. "scratch") still lists as-is.
func parseJJWorkspaces(output string) []string {
	var result []string
	for line := range strings.SplitSeq(output, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		name := strings.TrimSpace(parts[0])
		if name == "" || name == "default" {
			continue
		}
		result = append(result, strings.TrimPrefix(name, "workroom/"))
	}
	return result
}
