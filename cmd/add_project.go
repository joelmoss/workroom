package cmd

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

// addProjectCreate backs the --create flag: when set, add-project will create
// (and git-initialize) the directory if it does not already exist, instead of
// requiring an existing Git repo. Set per-invocation by the macOS app's
// "Create new directory…" mode (issue #103).
var addProjectCreate bool

// addProjectClone backs the --clone flag: the URL to clone into PATH before registering it, set by
// the macOS app's "Clone a repository…" mode (issue #620).
var addProjectClone string

// addProjectCmd is an internal, app-only command: it registers an empty project
// (one with no workrooms yet) so the macOS app's sidebar can show it. The human
// CLI never needs it — `create` auto-registers a project on first use, and the
// human `list` only shows projects that have workrooms — so it is hidden and
// available solely in --json mode, which is how the app invokes it.
//
// By default the PATH must already be a Git repo (repo-only). With --create,
// a missing directory is created and git-initialized so it is immediately usable
// as a project — see workroom.Service.AddProject. With --clone URL, URL is cloned
// into PATH first, streaming git's progress as "clone" log events on stderr — see
// workroom.Service.CloneProject.
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
		if addProjectClone != "" {
			if addProjectCreate {
				return fmt.Errorf("--clone and --create cannot be used together")
			}
			return runCloneProject(svc, addProjectClone, args[0], os.Stdout, os.Stderr)
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
	payload := addProjectPayload{Path: res.Path, VCS: res.VCS}
	if svc.Pretend {
		payload.WouldCreate = &res.WouldCreate
	}
	return writeJSONSuccess(out, "add-project", payload)
}

// runCloneProject clones url into path, registers it and prints its envelope, streaming git's
// output to logSink as NDJSON. SIGTERM (the app's Cancel), SIGINT or SIGHUP cancels the clone: git's
// process group is SIGTERMed (then SIGKILLed if it lingers), the destination is put back as it was
// found, and the run reports Cancelled. A clone that is in place but can't be registered is kept and
// reported as ConfigWriteFailed. The handler forwards and stops, never re-raising, as script.Run's
// does.
func runCloneProject(svc *workroom.Service, url, path string, out, logSink io.Writer) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer stop()
	logWriter := newJSONLogWriter(logSink, "clone")
	res, err := svc.CloneProject(ctx, url, path, &crSplitter{w: logWriter})
	logWriter.Flush()
	if err != nil {
		return err
	}
	payload := addProjectPayload{Path: res.Path, VCS: res.VCS}
	if svc.Pretend {
		payload.WouldClone = &res.WouldClone
	}
	return writeJSONSuccess(out, "add-project", payload)
}

func init() {
	addProjectCmd.Flags().BoolVar(&addProjectCreate, "create", false,
		"Create and git-initialize the directory if it does not already exist")
	addProjectCmd.Flags().StringVar(&addProjectClone, "clone", "",
		"Clone this repository URL into PATH, then register it")
	rootCmd.AddCommand(addProjectCmd)
}
