package cmd

import (
	"github.com/spf13/cobra"
)

var createCmd = &cobra.Command{
	Use:     "create",
	Aliases: []string{"c"},
	Short:   "Create a new workroom",
	Long:    "Create a new workroom at the same level as your main project directory, using JJ workspaces if available, otherwise falling back to git worktrees. A random friendly name is auto-generated.",
	Args:    cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		svc := newService()
		cwd, err := getCwd()
		if err != nil {
			return err
		}
		return svc.Create(cwd)
	},
}

func init() {
	rootCmd.AddCommand(createCmd)
}
