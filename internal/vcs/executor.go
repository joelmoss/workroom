package vcs

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

// CommandExecutor abstracts shell command execution for testability.
type CommandExecutor interface {
	Run(dir string, name string, args ...string) (string, error)
}

// RealExecutor runs actual shell commands.
type RealExecutor struct{}

func (r *RealExecutor) Run(dir string, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = childEnvironment(dir)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// gitRedirects are inherited variables that point git at another repository. A `workroom` run
// from a git hook or alias inherits them, and they outrank both the cwd and the ceiling.
var gitRedirects = []string{
	"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
	"GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES",
}

// childEnvironment is this process's environment without gitRedirects, plus a ceiling so
// repository discovery stops at dir (see ceilingDirectories), and GIT_TERMINAL_PROMPT=0 so the
// create's fetch fails rather than asks for https credentials mid-command. ssh passphrase and
// host-key prompts are ssh's own and not covered.
func childEnvironment(dir string) []string {
	env := make([]string, 0, len(os.Environ())+2)
	for _, kv := range os.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		if !slices.Contains(gitRedirects, key) && key != "GIT_TERMINAL_PROMPT" {
			env = append(env, kv)
		}
	}
	env = append(env, "GIT_TERMINAL_PROMPT=0")
	if ceiling := ceilingDirectories(dir); ceiling != "" {
		env = append(env, "GIT_CEILING_DIRECTORIES="+ceiling)
	}
	return env
}

// ceilingDirectories is GIT_CEILING_DIRECTORIES for a git run in dir: the parent of its RESOLVED
// path, so discovery stops at dir. Every git here runs at a repository root, and a folder there
// that is not a repository (a workspace Jujutsu left before #266, or a broken empty .git) would
// otherwise make git act on an ANCESTOR repository. Resolved because a trailing slash or a symlink
// would name the wrong folder. "" (no ceiling) when dir is empty, unresolvable or "/", and when the
// parent contains ':', which git splits the variable on; Detect's strict check is the backstop.
func ceilingDirectories(dir string) string {
	if dir == "" {
		return ""
	}
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return ""
	}
	real, err = filepath.Abs(real)
	if err != nil {
		return ""
	}
	parent := filepath.Dir(real)
	if parent == real || strings.Contains(parent, ":") {
		return ""
	}
	return parent
}
