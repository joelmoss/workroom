package cmd

import (
	"os"

	"github.com/joelmoss/workroom/internal/updater"
	"github.com/spf13/cobra"
)

var checkOnly bool

var updateCmd = &cobra.Command{
	Use:     "update",
	Aliases: []string{"u"},
	Short:   "Update workroom to the latest version",
	Long:    "Check for and install the latest version of workroom from GitHub Releases.",
	Args:    cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		if checkOnly {
			return updater.CheckOnly(versionStr, os.Stdout)
		}
		return updater.Update(versionStr, verbose, pretend, os.Stdout)
	},
}

func init() {
	updateCmd.Flags().BoolVarP(&checkOnly, "check", "c", false, "Only check if an update is available")
	rootCmd.AddCommand(updateCmd)
}
