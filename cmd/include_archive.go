package cmd

import (
	"fmt"
	"os"

	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

var (
	includeArchiveProject string
	includeArchiveOutput  string
)

// includeArchiveCmd writes a root's included files (#367) to a tar the desktop app streams into a
// remote workroom's checkout on its host. The archive goes to --output, not stdout, so stdout stays
// one JSON envelope (ADR 0013): the archived paths, their count and size, and each file it couldn't
// read.
var includeArchiveCmd = &cobra.Command{
	Use:    "include-archive",
	Short:  "Write the project's included files to a tar (used by the desktop app)",
	Hidden: true,
	Args:   cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "include-archive"
		root, err := resolveProject(includeArchiveProject)
		if err != nil {
			return err
		}
		files, _, err := workroom.IncludedFiles(root)
		if err != nil {
			return err
		}
		out, err := os.OpenFile(includeArchiveOutput, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
		if err != nil {
			return err
		}
		res, err := workroom.ArchiveIncluded(root, files, out)
		if closeErr := out.Close(); err == nil {
			err = closeErr
		}
		if err != nil {
			return err
		}
		if jsonOutput {
			return writeJSONSuccess(os.Stdout, "include-archive", map[string]any{
				"paths": nonNil(res.Copied), "count": len(res.Copied), "bytes": res.Bytes,
				"warnings": nonNil(res.Failures),
			})
		}
		fmt.Printf("Archived %d files to %s\n", len(res.Copied), includeArchiveOutput)
		for _, f := range res.Failures {
			fmt.Fprintln(os.Stderr, f)
		}
		return nil
	},
}

// nonNil is s, or an empty slice for nil, so it encodes as [] rather than null.
func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func init() {
	includeArchiveCmd.Flags().StringVar(&includeArchiveProject, "project", "", "Project directory (defaults to the current directory)")
	includeArchiveCmd.Flags().StringVar(&includeArchiveOutput, "output", "", "The file to write the tar to")
	_ = includeArchiveCmd.MarkFlagRequired("output")
	rootCmd.AddCommand(includeArchiveCmd)
}
