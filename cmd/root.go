package cmd

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/ui"
	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

var (
	verbose    bool
	pretend    bool
	versionStr = "dev"
	// bakedChannel is the binary's compile-time channel identity: "" for the main `workroom`
	// binary (stable/pre selectable at runtime), or "nightly" for the `workroom-nightly` binary.
	bakedChannel = ""
)

func SetVersion(v string) {
	versionStr = v
}

// SetBakedChannel records the binary's compile-time channel identity (see bakedChannel).
func SetBakedChannel(c string) {
	bakedChannel = c
}

var rootCmd = &cobra.Command{
	Use:           "workroom",
	Short:         "Manage development workrooms",
	Long:          "Create and manage local development workrooms using JJ workspaces or Git worktrees.",
	SilenceUsage:  true,
	SilenceErrors: true, // we render errors ourselves (JSON envelope or "Error:" line) in Execute
}

func init() {
	rootCmd.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false, "Print detailed and verbose output")
	rootCmd.PersistentFlags().BoolVarP(&pretend, "pretend", "p", false, "Run through the command without making changes (dry run)")
	rootCmd.PersistentFlags().BoolVar(&jsonOutput, "json", false, "Emit machine-readable JSON (exactly one object on stdout)")
}

// Execute runs the CLI and returns the process exit code. In --json mode every
// outcome — including pre-flight and usage errors — is a single JSON envelope on
// stdout; otherwise errors print as "Error: <msg>" on stderr. Exit codes follow
// errs.ExitCode so non-interactive callers can distinguish failure classes.
func Execute() int {
	err := rootCmd.Execute()
	if err == nil {
		return 0
	}
	if jsonOutput {
		writeJSONError(os.Stdout, currentCommand, err)
	} else {
		fmt.Fprintln(os.Stderr, "Error:", err)
	}
	return errs.ExitCode(err)
}

// newService builds a Service for the current invocation. In --json mode it is
// fully non-interactive: output is discarded (the command writes the JSON itself),
// the editor prompt is suppressed, empty projects are pinned, and the interactive
// prompt/confirm hooks error rather than block.
func newService() (*workroom.Service, error) {
	cfg, err := config.New("")
	if err != nil {
		return nil, err
	}
	svc := &workroom.Service{
		Config:    cfg,
		Out:       os.Stdout,
		Verbose:   verbose,
		Pretend:   pretend,
		PromptFn:  ui.MultiSelect,
		ConfirmFn: ui.Confirm,
	}
	if jsonOutput {
		svc.Out = io.Discard
		svc.SuppressEditor = true
		svc.KeepEmptyProject = true
		svc.PromptFn = func(string, []string) ([]string, error) {
			return nil, errors.New("interactive prompt not available in --json mode")
		}
		svc.ConfirmFn = func(string) (bool, error) {
			return false, errors.New("interactive confirmation not available in --json mode")
		}
	}
	return svc, nil
}
