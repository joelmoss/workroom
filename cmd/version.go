package cmd

import (
	"fmt"
	"os"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/spf13/cobra"
)

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print the version",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "version"
		if jsonOutput {
			// The active release channel is surfaced in --json only; plain output
			// stays the bare version string so scripts can parse it unchanged. A
			// nightly-baked binary reports its fixed identity; the main binary reports
			// its configured (stable/pre) channel.
			cfg, err := config.New("")
			if err != nil {
				return err
			}
			ch := cfg.Channel()
			if bakedChannel != "" {
				ch = bakedChannel
			}
			return writeJSONSuccess(os.Stdout, "version", map[string]any{
				"version":               versionStr,
				"channel":               ch,
				"config_schema_version": 2,
			})
		}
		fmt.Println(versionStr)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}
