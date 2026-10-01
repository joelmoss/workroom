package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/spf13/cobra"
)

var (
	hostProject  string
	hostWorkroom string
)

// hostCmd records the host descriptors the desktop app owns (#249, #252): which machine a remote
// workroom lives on, and a project's base machine. The descriptor is stored verbatim; the CLI
// interprets only whether a workroom has one and its "state".
var hostCmd = &cobra.Command{
	Use:    "host",
	Short:  "Set or clear a project's or workroom's host descriptor (used by the desktop app)",
	Hidden: true,
}

var hostSetCmd = &cobra.Command{
	Use:   "set DESCRIPTOR",
	Short: "Store DESCRIPTOR, a JSON object, as the host descriptor",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "host"
		var host map[string]any
		// A JSON null decodes to a nil map, which would clear the descriptor, so it is refused
		// with every other non-object.
		if err := json.Unmarshal([]byte(args[0]), &host); err != nil || host == nil {
			return fmt.Errorf("%w: %s", errs.ErrInvalidHost, args[0])
		}
		return setHost(host)
	},
}

var hostClearCmd = &cobra.Command{
	Use:   "clear",
	Short: "Remove the host descriptor",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "host"
		return setHost(nil)
	},
}

func setHost(host map[string]any) error {
	cfg, err := config.New("")
	if err != nil {
		return err
	}
	dir, err := resolveProject(hostProject)
	if err != nil {
		return err
	}
	if err := cfg.SetHost(dir, hostWorkroom, host); err != nil {
		return err
	}
	if jsonOutput {
		return writeJSONSuccess(os.Stdout, "host", map[string]any{"project": dir, "workroom": hostWorkroom})
	}
	return nil
}

func init() {
	for _, c := range []*cobra.Command{hostSetCmd, hostClearCmd} {
		c.Flags().StringVar(&hostProject, "project", "", "Project directory (defaults to the current directory)")
		c.Flags().StringVar(&hostWorkroom, "workroom", "", "The project's workroom; omitted, the project's own descriptor")
		hostCmd.AddCommand(c)
	}
	rootCmd.AddCommand(hostCmd)
}
