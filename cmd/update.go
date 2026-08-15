package cmd

import (
	"fmt"
	"os"

	"github.com/joelmoss/workroom/internal/channel"
	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/updater"
	"github.com/spf13/cobra"
)

var (
	checkOnly   bool
	channelFlag string
)

// errNightlySeparateInstall explains that nightly is not a channel you switch the main binary to,
// but a separate side-by-side install (a distinct `workroom-nightly` binary).
var errNightlySeparateInstall = fmt.Errorf(
	"nightly is a separate install, not a channel switch — install it alongside this binary with:\n" +
		"  WORKROOM_CHANNEL=nightly curl -fsSL " +
		"https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh\n" +
		"that installs a `workroom-nightly` binary next to `workroom`")

var updateCmd = &cobra.Command{
	Use:     "update",
	Aliases: []string{"u"},
	Short:   "Update workroom to the latest version",
	Long: "Check for and install the latest version of workroom from GitHub Releases.\n\n" +
		"Use --channel to choose a release channel for this (main) binary:\n" +
		"  stable   GA releases only (default)\n" +
		"  pre      betas / release candidates, plus stable\n\n" +
		"Passing --channel switches you to that channel (installing its latest build even if that\n" +
		"means a downgrade) and remembers it. Nightly is not a channel switch — it's a separate\n" +
		"side-by-side install (a `workroom-nightly` binary); see the install script's WORKROOM_CHANNEL.",
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "update"

		cfg, err := config.New("")
		if err != nil {
			return err
		}

		ch, explicit, err := resolveUpdateChannel(
			bakedChannel, cmd.Flags().Changed("channel"), channelFlag, cfg.Channel())
		if err != nil {
			return err
		}

		// --check never installs and never mutates config.
		if checkOnly {
			return updater.CheckOnly(versionStr, ch, os.Stdout)
		}

		// An explicit channel switch may install a lower version (a downgrade).
		if err := updater.Update(versionStr, ch, explicit, verbose, pretend, os.Stdout); err != nil {
			return err
		}

		// Persist the channel only after a successful (non-dry-run) explicit switch, and only when
		// it changed — so config never drifts to a channel the binary didn't actually move onto.
		if explicit && !pretend && string(ch) != cfg.Channel() {
			if err := cfg.SetChannel(string(ch)); err != nil {
				return err
			}
		}
		return nil
	},
}

// resolveUpdateChannel decides which channel `workroom update` acts on, per the binary's identity:
//
//   - The nightly-baked binary (`workroom-nightly`) always tracks nightly; passing --channel errors.
//   - The main binary accepts --channel stable|pre (nightly → errNightlySeparateInstall); with no
//     flag it uses the persisted config channel, coercing anything invalid — including a legacy
//     "nightly" written by an older CLI — down to stable so a plain `workroom update` never breaks.
//
// explicit is true only when the user passed --channel (→ the caller persists + allows a downgrade).
func resolveUpdateChannel(baked string, flagSet bool, flagVal, configVal string) (channel.Channel, bool, error) {
	if baked == string(channel.Nightly) {
		if flagSet {
			return "", false, fmt.Errorf(
				"workroom-nightly always tracks the nightly channel; --channel does not apply")
		}
		return channel.Nightly, false, nil
	}

	if flagSet {
		if flagVal == string(channel.Nightly) {
			return "", false, errNightlySeparateInstall
		}
		ch, ok := channel.Parse(flagVal)
		if !ok || ch == channel.Nightly {
			return "", false, fmt.Errorf("invalid channel %q (want stable or pre)", flagVal)
		}
		return ch, true, nil
	}

	ch, ok := channel.Parse(configVal)
	if !ok || ch == channel.Nightly {
		ch = channel.Stable
	}
	return ch, false, nil
}

func init() {
	updateCmd.Flags().BoolVarP(&checkOnly, "check", "c", false, "Only check if an update is available")
	updateCmd.Flags().StringVar(&channelFlag, "channel", "", "Release channel: stable or pre (remembered for next time)")
	rootCmd.AddCommand(updateCmd)
}
