package cmd

import (
	"os"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/spf13/cobra"
)

var (
	claimFrom        string
	claimProvisioner string
)

// claimCmd moves what one desktop build made out of the config other builds share and into this
// one ($WORKROOM_CONFIG): a Dev build keeps its own config, so its remote workrooms and bases must
// not stay where Release and Nightly read them (a base another build made blocks their creates).
var claimCmd = &cobra.Command{
	Use:    "claim-provisioned",
	Short:  "Move the remote entries a build made from another config into this one (used by the desktop app)",
	Hidden: true,
	Args:   cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "claim-provisioned"
		cfg, err := config.New("")
		if err != nil {
			return err
		}
		shared, err := config.New(claimFrom)
		if err != nil {
			return err
		}
		moved, err := cfg.ClaimProvisioned(shared, claimProvisioner)
		if err != nil {
			return err
		}
		if jsonOutput {
			return writeJSONSuccess(os.Stdout, "claim-provisioned", map[string]any{"moved": moved})
		}
		return nil
	},
}

func init() {
	claimCmd.Flags().StringVar(&claimFrom, "from", "", "The config to move entries out of")
	claimCmd.Flags().StringVar(&claimProvisioner, "provisioner", "", "The bundle ID of the build that made them")
	_ = claimCmd.MarkFlagRequired("from")
	_ = claimCmd.MarkFlagRequired("provisioner")
	rootCmd.AddCommand(claimCmd)
}
