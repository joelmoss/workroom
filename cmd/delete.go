package cmd

import (
	"github.com/spf13/cobra"
)

var confirmFlag string

var deleteCmd = &cobra.Command{
	Use:     "delete [NAME]",
	Aliases: []string{"d"},
	Short:   "Delete an existing workroom",
	Long:    "Delete an existing workroom. When run without a name, shows an interactive multi-select menu.",
	Args:    cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		svc := newService()
		cwd, err := getCwd()
		if err != nil {
			return err
		}

		if len(args) == 0 {
			return svc.InteractiveDelete(cwd)
		}
		return svc.Delete(cwd, args[0], confirmFlag)
	},
}

func init() {
	deleteCmd.Flags().StringVar(&confirmFlag, "confirm", "", "Skip confirmation if value matches the workroom name")
	rootCmd.AddCommand(deleteCmd)
}
