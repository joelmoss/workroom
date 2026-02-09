package cmd

import (
	"os"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/ui"
	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

var (
	verbose    bool
	pretend    bool
	versionStr = "dev"
)

func SetVersion(v string) {
	versionStr = v
}

var rootCmd = &cobra.Command{
	Use:          "workroom",
	Short:        "Manage development workrooms",
	Long:         "Create and manage local development workrooms using JJ workspaces or Git worktrees.",
	SilenceUsage: true,
}

func init() {
	rootCmd.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false, "Print detailed and verbose output")
	rootCmd.PersistentFlags().BoolVarP(&pretend, "pretend", "p", false, "Run through the command without making changes (dry run)")
}

func Execute() error {
	return rootCmd.Execute()
}

func newService() *workroom.Service {
	return &workroom.Service{
		Config:    config.New(""),
		Out:       os.Stdout,
		Verbose:   verbose,
		Pretend:   pretend,
		PromptFn:  ui.MultiSelect,
		ConfirmFn: ui.Confirm,
	}
}
