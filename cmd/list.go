package cmd

import (
	"github.com/spf13/cobra"
)

var listCmd = &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls", "l"},
	Short:   "List all workrooms for the current project",
	Args:    cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		svc, err := newService()
		if err != nil {
			return err
		}
		cwd, err := getCwd()
		if err != nil {
			return err
		}
		return svc.List(cwd)
	},
}

func init() {
	rootCmd.AddCommand(listCmd)
}
