package cmd

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/spf13/cobra"
)

var baseProject string

// baseCmd sets the branch a project's new workrooms start from. Unset, they start from origin's
// freshly fetched default branch.
var baseCmd = &cobra.Command{
	Use:   "base",
	Short: "Set or clear the branch new workrooms start from",
	Long:  "Set or clear the branch a project's new workrooms start from. Workroom fetches origin and uses origin's copy of the branch, else the local branch. Unset, new workrooms start from origin's default branch.",
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
	Short: "Start new workrooms from origin's default branch",
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
	dir, err := resolveProject(baseProject)
	if err != nil {
		return err
	}
	if !pretend {
		if err := cfg.SetBaseBranch(dir, branch); err != nil {
			return err
		}
	}
	if jsonOutput {
		return writeJSONSuccess(os.Stdout, "base", map[string]any{"project": dir, "base_branch": branch})
	}
	return nil
}

func init() {
	for _, c := range []*cobra.Command{baseSetCmd, baseClearCmd} {
		c.Flags().StringVar(&baseProject, "project", "", "Project directory (defaults to the current directory)")
		baseCmd.AddCommand(c)
	}
	rootCmd.AddCommand(baseCmd)
}
