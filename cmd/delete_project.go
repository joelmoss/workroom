package cmd

import (
	"fmt"
	"io"
	"os"

	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

var (
	deleteProjectConfirm  string
	deleteProjectWithWR   bool
	deleteProjectFromDisk bool
)

// deleteProjectCmd is an internal, app-only command: it removes a project from the
// config so the macOS app's sidebar can drop it. The human CLI never needs it — a
// project disappears on its own once its last workroom is deleted — so it is hidden
// and available solely in --json mode, which is how the app invokes it.
//
// By default it is strictly config-only: the project entry is deleted and NOTHING on
// disk is touched (worktree directories, branches, and files all stay). With
// --with-workrooms it first tears down every registered workroom (the same per-
// workroom teardown the `delete` command runs: teardown script + VCS worktree/
// workspace removal + dir cleanup, streaming NDJSON logs), then removes the project.
// Branches/bookmarks are never deleted in either mode — the cascade reuses
// Service.Delete, whose VCS removal (`git worktree remove`)
// leaves refs intact.
//
// With --from-disk the CLI runs teardown scripts and drops the project from config,
// then returns the list of paths the macOS app should move to the Trash. The app
// handles the actual filesystem removal; the CLI never deletes directories itself in
// this mode.
var deleteProjectCmd = &cobra.Command{
	Use:    "delete-project [PATH]",
	Short:  "Remove a project (internal; used by the macOS app via --json)",
	Hidden: true,
	Args:   cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "delete-project"
		svc, err := newService()
		if err != nil {
			return err
		}
		return runDeleteProject(svc, jsonOutput, deleteProjectConfirm, deleteProjectWithWR, deleteProjectFromDisk, args, os.Stdout, os.Stderr)
	},
}

// runDeleteProject holds the command body, decoupled from cobra globals and os
// streams so it is unit-testable with an injected Service (temp config + mock VCS).
// stdout receives the single JSON success envelope; logSink receives NDJSON teardown
// log events during a cascade.
func runDeleteProject(svc *workroom.Service, jsonMode bool, confirm string, withWorkrooms bool, fromDisk bool, args []string, stdout, logSink io.Writer) error {
	if !jsonMode {
		return fmt.Errorf("delete-project is only available in --json mode")
	}
	if len(args) != 1 {
		return fmt.Errorf("a path argument is required")
	}

	logWriter := newJSONLogWriter(logSink, "teardown")
	svc.ScriptLogWriter = logWriter
	res, err := svc.DeleteProject(args[0], confirm, withWorkrooms, fromDisk)
	logWriter.Flush()
	if err != nil {
		return err
	}

	if fromDisk {
		return writeJSONSuccess(stdout, "delete-project", map[string]any{
			"path":        res.Path,
			"from_disk":   true,
			"trash_paths": res.TrashPaths,
		})
	}
	return writeJSONSuccess(stdout, "delete-project", map[string]any{
		"path": res.Path, "with_workrooms": withWorkrooms,
	})
}

func init() {
	deleteProjectCmd.Flags().StringVar(&deleteProjectConfirm, "confirm", "", "Required in --json mode; must match the project path")
	deleteProjectCmd.Flags().BoolVar(&deleteProjectWithWR, "with-workrooms", false, "Also tear down every workroom (worktree dirs + files; branches kept)")
	deleteProjectCmd.Flags().BoolVar(&deleteProjectFromDisk, "from-disk", false, "App-only: runs teardowns, drops config, returns trash_paths; the caller (macOS app) moves those dirs to the Trash")
	rootCmd.AddCommand(deleteProjectCmd)
}
