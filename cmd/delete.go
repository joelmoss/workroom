package cmd

import (
	"fmt"
	"io"
	"os"

	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/ui"
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
			_, err = svc.Delete(dir, name, confirmFlag)
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
// none, of those the user picks. Each teardown script's output streams into a log panel.
func runDeleteHuman(svc *workroom.Service, dir string, args []string, confirm string, out io.Writer) error {
	svc.ScriptOutput = func(title string) (io.Writer, func(bool)) {
		panel := ui.NewLogPanel(out, title)
		return panel, func(ok bool) {
			panel.Close(ok)
			if ok && panel.Shown() {
				fmt.Fprintln(out)
			}
		}
	}

	if len(args) == 0 {
		outcome, err := svc.InteractiveDelete(dir, func(res workroom.DeleteResult) { printDeleteResult(out, res) })
		if err != nil {
			return err
		}
		switch outcome {
		case workroom.NoWorkroomsToPick:
			fmt.Fprintln(out, "No workrooms found for this project.")
		case workroom.NothingPicked:
			fmt.Fprintln(out, ui.Yellow("Aborting. No workrooms were selected."))
		case workroom.PicksDeclined:
			fmt.Fprintln(out, ui.Yellow("Aborting. No workrooms were deleted."))
		}
		return nil
	}

	res, err := svc.Delete(dir, args[0], confirm)
	if err != nil {
		return err
	}
	printDeleteResult(out, res)
	return nil
}

// printDeleteResult tells the user what a delete did with one workroom.
func printDeleteResult(w io.Writer, res workroom.DeleteResult) {
	switch res.Outcome {
	case workroom.Deleted:
		fmt.Fprintln(w, ui.Green(fmt.Sprintf("Workroom '%s' deleted successfully.", res.Name)))
		fmt.Fprintln(w)
		fmt.Fprintf(w, "Note: Git branch '%s' was not deleted.\n", res.Branch)
		fmt.Fprintf(w, "      Delete manually with `git branch -D %s` if needed.\n", res.Branch)
	case workroom.ForgotDestroyedRemote:
		fmt.Fprintln(w, ui.Green(fmt.Sprintf("Workroom '%s' deleted successfully.", res.Name)))
	case workroom.ForgotNonGit:
		fmt.Fprintln(w, ui.Green(fmt.Sprintf("Workroom '%s' removed from Workroom. It is not a git worktree, so no git or teardown ran.", res.Name)))
		fmt.Fprintf(w, "Note: its folder was left at %s. Delete it manually if needed.\n", ui.DisplayPath(res.Path))
	case workroom.Declined:
		fmt.Fprintln(w, ui.Yellow(fmt.Sprintf("Aborting. Workroom '%s' was not deleted.", res.Name)))
	}
}

func init() {
	deleteCmd.Flags().StringVar(&confirmFlag, "confirm", "", "Skip confirmation if value matches the workroom name (required in --json mode)")
	deleteCmd.Flags().StringVar(&deleteProject, "project", "", "Project directory the workroom belongs to (defaults to the current directory)")
	rootCmd.AddCommand(deleteCmd)
}
