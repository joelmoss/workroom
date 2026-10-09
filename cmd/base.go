package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/spf13/cobra"
)

var (
	baseProject string
	baseGlobal  bool
)

// baseCmd sets the branch new workrooms start from, for one project or, with --global, for every
// project that names none. Unset, they start from origin's freshly fetched default branch.
var baseCmd = &cobra.Command{
	Use:   "base",
	Short: "Set or clear the branch new workrooms start from",
	Long: "Set or clear the branch new workrooms start from. BRANCH is a branch on origin, such as " +
		"develop, or <remote>/<branch> for another remote, such as upstream/main. Workroom fetches " +
		"that remote and uses its copy of the branch, else the local branch. A project's own base " +
		"wins over the --global one. Unset, new workrooms start from origin's default branch.",
}

var baseSetCmd = &cobra.Command{
	Use:   "set BRANCH",
	Short: "Start new workrooms from BRANCH",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "base"
		// git's own rule for a branch name, so a typo is refused now, not at the next create.
		if out, err := exec.Command("git", "check-ref-format", "--branch", args[0]).CombinedOutput(); err != nil {
			return fmt.Errorf("invalid branch name %q: %s", args[0], out)
		}
		return setBase(args[0])
	},
}

var baseClearCmd = &cobra.Command{
	Use:   "clear",
	Short: "Start new workrooms from the global base, else origin's default branch",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "base"
		return setBase("")
	},
}

func setBase(branch string) error {
	cfg, err := config.New("")
	if err != nil {
		return err
	}
	if baseGlobal {
		if !pretend {
			if err := cfg.SetGlobalBaseBranch(branch); err != nil {
				return err
			}
		}
		if jsonOutput {
			return writeJSONSuccess(os.Stdout, "base", map[string]any{"global": true, "base_branch": branch})
		}
		return nil
	}
	dir, err := resolveProject(baseProject)
	if err != nil {
		return err
	}
	if err := refuseWorkroom(cfg, dir); err != nil {
		return err
	}
	// The CLI otherwise registers a project at its first create, which a base may have to come
	// before; `set` registers a repository as add-project does. `clear` only edits, so it still
	// works for a project whose folder has moved.
	if branch != "" {
		if _, err := vcs.Detect(dir); err != nil {
			return err
		}
	}
	if !pretend {
		if branch != "" {
			if err := cfg.AddProject(dir, string(vcs.TypeGit)); err != nil {
				return err
			}
		}
		if err := cfg.SetBaseBranch(dir, branch); err != nil {
			return err
		}
	}
	if jsonOutput {
		return writeJSONSuccess(os.Stdout, "base", map[string]any{"project": dir, "base_branch": branch})
	}
	return nil
}

// refuseWorkroom refuses dir when it is a workroom: a linked worktree or a registered workroom's
// path. A base belongs to the project's root checkout; run from a workroom terminal, `base set`
// would otherwise register that workroom as a project of its own.
func refuseWorkroom(cfg *config.Config, dir string) error {
	if linkedWorktree(dir) {
		return errs.ErrInWorkroom
	}
	projects, err := cfg.AllProjects()
	if err != nil {
		return err
	}
	for _, project := range projects {
		for _, wr := range project.Workrooms {
			if wr.Path == dir {
				return errs.ErrInWorkroom
			}
		}
	}
	return nil
}

// linkedWorktree reports whether dir is a linked worktree. A .git file alone doesn't say: a
// submodule or a `git init --separate-git-dir` repository has one at its root too. Only in a
// linked worktree does git's own directory differ from the common one.
func linkedWorktree(dir string) bool {
	if info, err := os.Stat(filepath.Join(dir, ".git")); err != nil || info.IsDir() {
		return false
	}
	out, err := (&vcs.RealExecutor{}).Run(dir, "git", "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir")
	if err != nil {
		return false
	}
	// One path per line; a path may hold spaces ("My Projects").
	dirs := strings.Split(out, "\n")
	return len(dirs) == 2 && dirs[0] != dirs[1]
}

func init() {
	for _, c := range []*cobra.Command{baseSetCmd, baseClearCmd} {
		c.Flags().StringVar(&baseProject, "project", "", "Project directory (defaults to the current directory)")
		c.Flags().BoolVar(&baseGlobal, "global", false, "The default for every project that names no base branch")
		baseCmd.AddCommand(c)
	}
	rootCmd.AddCommand(baseCmd)
}
