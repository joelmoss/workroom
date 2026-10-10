package cmd

import (
	"fmt"
	"io"
	"os"

	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

var (
	confirmFlag   string
	deleteProject string
)

var deleteCmd = &cobra.Command{
	Use:     "delete [NAME]",
	Aliases: []string{"d"},
	Short:   "Delete an existing workroom",
	Long:    "Delete an existing workroom. When run without a name, shows an interactive multi-select menu.",
	Args:    cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "delete"
		svc, err := newService()
		if err != nil {
			return err
		}
		dir, err := resolveProject(deleteProject)
		if err != nil {
			return err
		}

		if jsonOutput {
			if len(args) == 0 {
				return fmt.Errorf("%w: a workroom name is required in --json mode (interactive delete is unavailable)", errs.ErrInvalidName)
			}
			name := args[0]
			if confirmFlag == "" {
				return fmt.Errorf("%w: --confirm <name> is required in --json mode", errs.ErrConfirmMismatch)
			}
			// Stream teardown output as NDJSON log events on stderr; the result
			// envelope stays on stdout. The macOS app reads these live.
			logWriter := newJSONLogWriter(os.Stderr, "teardown")
			svc.ScriptLogWriter = logWriter
			err = svc.Delete(dir, name, confirmFlag)
			logWriter.Flush()
			if err != nil {
				return err
			}
			return writeJSONSuccess(os.Stdout, "delete", map[string]any{"name": name})
		}

		return runDeleteHuman(svc, dir, args, confirmFlag, os.Stdout)
	},
}

// runDeleteHuman is the human delete, writing to out: of the workroom named in args, or, with
// none, of those the user picks.
func runDeleteHuman(svc *workroom.Service, dir string, args []string, confirm string, out io.Writer) error {
	svc.Out = out
	if len(args) == 0 {
		return svc.InteractiveDelete(dir)
	}
	return svc.Delete(dir, args[0], confirm)
}

func init() {
	deleteCmd.Flags().StringVar(&confirmFlag, "confirm", "", "Skip confirmation if value matches the workroom name (required in --json mode)")
	deleteCmd.Flags().StringVar(&deleteProject, "project", "", "Project directory the workroom belongs to (defaults to the current directory)")
	rootCmd.AddCommand(deleteCmd)
}
