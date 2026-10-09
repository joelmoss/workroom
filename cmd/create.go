package cmd

import (
	"fmt"
	"os"

	"github.com/joelmoss/workroom/internal/errs"

	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

var (
	createProject  string
	createNoEditor bool
	// The desktop app's remote workrooms (#253): the descriptor and the checkout's path on the host.
	createHost     string
	createHostPath string
)

var createCmd = &cobra.Command{
	Use:     "create",
	Aliases: []string{"c"},
	Short:   "Create a new workroom",
	Long:    "Create a new workroom at the same level as your main project directory, using a git worktree. A random friendly name is auto-generated.",
	Args:    cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "create"
		svc, err := newService()
		if err != nil {
			return err
		}
		dir, err := resolveProject(createProject)
		if err != nil {
			return err
		}
		if createNoEditor {
			svc.SuppressEditor = true
		}

		if cmd.Flags().Changed("host") {
			return createRemote(svc, dir)
		}

		if jsonOutput {
			// Stream setup output as NDJSON log events on stderr; the result envelope
			// stays on stdout. The macOS app reads these live.
			logWriter := newJSONLogWriter(os.Stderr, "setup")
			svc.ScriptLogWriter = logWriter
			// Emit an early "created" event (before setup runs) so the GUI can mount
			// the workroom and dock the streaming setup log under its terminal.
			svc.OnReady = func(r workroom.CreateResult) {
				writeJSONEvent(os.Stderr, map[string]any{
					"type": "created", "name": r.Name, "path": r.Path, "vcs": r.VCS, "project": r.Project,
					"setup": r.HasSetup, "warning": r.Warning,
				})
			}
			res, err := svc.CreateNamed(dir, nil)
			logWriter.Flush()
			if err != nil {
				// Create is not transactional: on setup failure the workroom already
				// exists, so report it so the GUI can offer to delete it.
				if res.Name != "" {
					created := map[string]any{"name": res.Name, "path": res.Path, "vcs": res.VCS, "project": res.Project}
					if res.Warning != "" {
						created["warning"] = res.Warning
					}
					jsonErrorExtra = map[string]any{"created": created}
				}
				return err
			}
			payload := map[string]any{"name": res.Name, "path": res.Path, "vcs": res.VCS, "project": res.Project}
			if res.Warning != "" {
				payload["warning"] = res.Warning
			}
			return writeJSONSuccess(os.Stdout, "create", payload)
		}

		return svc.Create(dir)
	},
}

// createRemote records a remote workroom the app is about to make (#253), and prints its name.
func createRemote(svc *workroom.Service, dir string) error {
	host, err := decodeHost(createHost)
	if err != nil {
		return err
	}
	if createHostPath == "" {
		return fmt.Errorf("%w: --host-path is required with --host", errs.ErrInvalidHost)
	}
	res, err := svc.CreateRemote(dir, createHostPath, host)
	if err != nil {
		return err
	}
	if jsonOutput {
		return writeJSONSuccess(os.Stdout, "create", map[string]any{
			"name": res.Name, "path": res.Path, "vcs": res.VCS, "project": res.Project,
		})
	}
	fmt.Println(res.Name)
	return nil
}

func init() {
	createCmd.Flags().StringVar(&createHost, "host", "", "Record a remote workroom with this host descriptor, a JSON object (used by the desktop app)")
	createCmd.Flags().StringVar(&createHostPath, "host-path", "", "The remote workroom's path on its host (with --host)")
	_ = createCmd.Flags().MarkHidden("host")
	_ = createCmd.Flags().MarkHidden("host-path")
	createCmd.Flags().StringVar(&createProject, "project", "", "Project directory to create the workroom in (defaults to the current directory)")
	createCmd.Flags().BoolVar(&createNoEditor, "no-editor", false, "Do not offer to open the new workroom in $EDITOR")
	rootCmd.AddCommand(createCmd)
}
