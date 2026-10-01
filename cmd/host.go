package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

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
		host, err := decodeHost(args[0])
		if err != nil {
			return err
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

// decodeHost reads a descriptor as written: UseNumber, as Config.Read does, so an integer above
// 2^53 is not rewritten through float64. A JSON null decodes to a nil map, which would clear the
// descriptor, so it is refused with every other non-object, and so is trailing data.
func decodeHost(text string) (map[string]any, error) {
	var host map[string]any
	dec := json.NewDecoder(strings.NewReader(text))
	dec.UseNumber()
	if err := dec.Decode(&host); err != nil || host == nil || dec.Decode(new(any)) != io.EOF {
		return nil, fmt.Errorf("%w: %s", errs.ErrInvalidHost, text)
	}
	return host, nil
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
	// --pretend checks the descriptor and that its entry exists, and writes nothing.
	if pretend {
		if err := hostEntryExists(cfg, dir, hostWorkroom); err != nil {
			return err
		}
	} else if err := cfg.SetHost(dir, hostWorkroom, host); err != nil {
		return err
	}
	if jsonOutput {
		return writeJSONSuccess(os.Stdout, "host", map[string]any{"project": dir, "workroom": hostWorkroom})
	}
	return nil
}

// hostEntryExists refuses an entry SetHost would refuse, for --pretend.
func hostEntryExists(cfg *config.Config, dir, workroom string) error {
	projects, err := cfg.AllProjects()
	if err != nil {
		return err
	}
	project, ok := projects[dir]
	if !ok {
		return fmt.Errorf("%w: %s", errs.ErrProjectNotFound, dir)
	}
	if _, ok := project.Workrooms[workroom]; workroom != "" && !ok {
		return fmt.Errorf("%w: '%s' in %s", errs.ErrWorkroomNotFound, workroom, dir)
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
