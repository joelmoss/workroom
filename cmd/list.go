package cmd

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/ui"
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
		l, err := svc.Listing(cwd)
		if err != nil {
			return err
		}
		printListing(os.Stdout, l)
		return nil
	},
}

// printListing renders the human list: the workroom cwd is in, the project it is the root of, or
// every project with workrooms.
func printListing(w io.Writer, l workroom.Listing) {
	switch {
	case l.InWorkroom:
		fmt.Fprintln(w, ui.Yellow("You are already in a workroom."))
		fmt.Fprintf(w, "Parent project is at %s\n", ui.DisplayPath(l.ParentPath))
	case l.AtProject && l.Count == 0:
		fmt.Fprintln(w, "No workrooms found for this project.")
	case l.AtProject:
		for p := range l.Projects {
			printWorkroomsTable(w, p)
		}
	case l.Count == 0:
		fmt.Fprintln(w, "No workrooms found.")
	default:
		for p := range l.Projects {
			fmt.Fprintf(w, "%s:\n", ui.DisplayPath(p.Path))
			printWorkroomsTable(w, p)
			fmt.Fprintln(w)
		}
	}
}

// printWorkroomsTable renders one project's workrooms, with their warnings, as a table.
func printWorkroomsTable(w io.Writer, pinfo workroom.ProjectInfo) {
	var rows [][]string
	for _, wi := range pinfo.Workrooms {
		row := []string{ui.Bold(wi.Name), ui.Dim(ui.DisplayPath(wi.Path))}
		if len(wi.Warnings) > 0 {
			messages := make([]string, len(wi.Warnings))
			for i, warning := range wi.Warnings {
				messages[i] = warning.Message
			}
			row = append(row, ui.Yellow(fmt.Sprintf("[%s]", strings.Join(messages, ", "))))
		}
		rows = append(rows, row)
	}
	ui.PrintTable(w, rows, 2)
}

func init() {
	listCmd.Flags().StringVar(&listProject, "project", "", "Limit JSON output to a single project directory")
	listCmd.Flags().StringVar(&listWarnings, "warnings", "fast", "Warning detail for --json: none, fast, or full")
	rootCmd.AddCommand(listCmd)
}
