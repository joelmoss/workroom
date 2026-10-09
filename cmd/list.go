package cmd

import (
	"fmt"
	"os"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

var (
	listProject  string
	listWarnings string
)

var listCmd = &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls", "l"},
	Short:   "List all workrooms for the current project",
	Args:    cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "list"
		svc, err := newService()
		if err != nil {
			return err
		}

		if jsonOutput {
			level := workroom.WarningsLevel(listWarnings)
			switch level {
			case workroom.WarningsNone, workroom.WarningsFast, workroom.WarningsFull:
			default:
				return fmt.Errorf("invalid --warnings value %q (want none, fast, or full)", listWarnings)
			}

			res, err := svc.ListData(level)
			if err != nil {
				return err
			}

			projects := res.Projects
			if listProject != "" {
				canon, err := config.CanonicalPath(listProject)
				if err != nil {
					return err
				}
				filtered := make([]workroom.ProjectInfo, 0, 1)
				for _, p := range projects {
					if p.Path == canon || p.Path == listProject {
						filtered = append(filtered, p)
					}
				}
				projects = filtered
			}

			payload := map[string]any{
				"projects":      projects,
				"workrooms_dir": res.WorkroomsDir,
				"config_path":   res.ConfigPath,
			}
			if res.BaseBranch != "" {
				payload["base_branch"] = res.BaseBranch
			}
			return writeJSONSuccess(os.Stdout, "list", payload)
		}

		cwd, err := getCwd()
		if err != nil {
			return err
		}
		return svc.List(cwd)
	},
}

func init() {
	listCmd.Flags().StringVar(&listProject, "project", "", "Limit JSON output to a single project directory")
	listCmd.Flags().StringVar(&listWarnings, "warnings", "fast", "Warning detail for --json: none, fast, or full")
	rootCmd.AddCommand(listCmd)
}
