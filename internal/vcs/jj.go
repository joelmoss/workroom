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

func (j *JJ) WorkroomExists(dir, name string) (bool, error) {
	workrooms, err := j.ListWorkrooms(dir)
	if err != nil {
		return false, err
	}
	vcsName := "workroom/" + name
	for _, w := range workrooms {
		if w == vcsName {
			return true, nil
		}
	}
	return false, nil
}

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

func parseJJWorkspaces(output string) []string {
	var result []string
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		name := strings.TrimSpace(parts[0])
		if name == "" || name == "default" {
			continue
		}
		result = append(result, name)
	}
	return result
}
