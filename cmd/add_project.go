package cmd

import (
	"fmt"
	"io"
	"os"

	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

// addProjectCreate backs the --create flag: when set, add-project will create
// (and git-initialize) the directory if it does not already exist, instead of
// requiring an existing Git repo. Set per-invocation by the macOS app's
// "Create new directory…" mode (issue #103).
var addProjectCreate bool

// addProjectCmd is an internal, app-only command: it registers an empty project
// (one with no workrooms yet) so the macOS app's sidebar can show it. The human
// CLI never needs it — `create` auto-registers a project on first use, and the
// human `list` only shows projects that have workrooms — so it is hidden and
// available solely in --json mode, which is how the app invokes it.
//
// By default the PATH must already be a Git repo (repo-only). With --create,
// a missing directory is created and git-initialized so it is immediately usable
// as a project — see workroom.Service.AddProject.
var addProjectCmd = &cobra.Command{
	Use:    "add-project [PATH]",
	Short:  "Register a project (internal; used by the macOS app via --json)",
	Hidden: true,
	Args:   cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "add-project"
		if !jsonOutput {
			return fmt.Errorf("add-project is only available in --json mode")
		}
		svc, err := newService()
		if err != nil {
			return err
		}
		if len(args) != 1 {
			return fmt.Errorf("a path argument is required")
		}
		return runAddProject(svc, args[0], addProjectCreate, os.Stdout)
	},
}

// runAddProject registers the project at path and prints its envelope, with what would happen
// under --pretend.
func runAddProject(svc *workroom.Service, path string, create bool, out io.Writer) error {
	res, err := svc.AddProject(path, create)
	if err != nil {
		return err
	}
	payload := map[string]any{"path": res.Path, "vcs": res.VCS}
	if svc.Pretend {
		payload["would_create"] = res.WouldCreate
	}
	return writeJSONSuccess(out, "add-project", payload)
}

func init() {
	addProjectCmd.Flags().BoolVar(&addProjectCreate, "create", false,
		"Create and git-initialize the directory if it does not already exist")
	rootCmd.AddCommand(addProjectCmd)
}
