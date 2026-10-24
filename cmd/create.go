package cmd

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strings"

	"github.com/joelmoss/workroom/internal/errs"
	"github.com/joelmoss/workroom/internal/ui"
	"github.com/joelmoss/workroom/internal/vcs"
	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/spf13/cobra"
)

var (
	createProject  string
	createNoEditor bool
	// Create without the setup script (the app's Continue Without Script), approving nothing.
	createSkipSetup bool
	// Where to start when the main checkout has work origin lacks; "" asks at a terminal.
	createStart string
	// The start point a create question was asked about: the app's answer passes back the refusal's
	// start_commit, so it fetches nothing and starts there (ADR 0059).
	createStartCommit string
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
		svc.SkipSetup = createSkipSetup
		if createStart != "" && !slices.Contains(workroom.Starts, workroom.Start(createStart)) {
			names := make([]string, len(workroom.Starts))
			for i, s := range workroom.Starts {
				names[i] = string(s)
			}
			return fmt.Errorf("--start must be one of %s, not %q", strings.Join(names, ", "), createStart)
		}
		svc.Start = workroom.Start(createStart)
		// A commit hash only: it goes to git as an argument, never as an option or a revision expression.
		if createStartCommit != "" && !commitHash.MatchString(createStartCommit) {
			return fmt.Errorf("--start-commit must be a commit hash, not %q", createStartCommit)
		}
		svc.StartCommit = createStartCommit
		dir, err := resolveProject(createProject)
		if err != nil {
			return err
		}
		if cmd.Flags().Changed("host") {
			return createRemote(svc, dir)
		}

		if jsonOutput {
			// Stream setup output as NDJSON log events on stderr; the result envelope
			// stays on stdout. The macOS app reads these live.
			logWriter := newJSONLogWriter(os.Stderr, "setup")
			svc.ScriptLogWriter = logWriter
			// Step events drive the app's creation checklist; log events carry the running step.
			svc.OnStep = func(id, state, detail string) {
				if state == "running" {
					logWriter.Flush()
					logWriter.step = id
				}
				event := map[string]any{"type": "step", "id": id, "state": state}
				if detail != "" {
					event["detail"] = detail
				}
				writeJSONEvent(os.Stderr, event)
			}
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

		return createWorkroom(svc, dir, os.Stdout, !createNoEditor)
	},
}

// createWorkroom is the human create: the setup script's output streams into a log panel, then
// the success line, then, with offerEditor, the offer to open the workroom in $EDITOR.
func createWorkroom(svc *workroom.Service, dir string, out io.Writer, offerEditor bool) error {
	// The setup script's output streams live into this panel as it runs. The panel
	// renders lazily on first output, so a script with no output draws nothing.
	panel := ui.NewLogPanel(out, "Setup")
	res, err := svc.CreateNamed(dir, panel)
	panel.Close(err == nil)
	// Before a setup error too: offline, the fetch and a networked setup script fail together.
	if res.Warning != "" {
		fmt.Fprintln(out, ui.Yellow(res.Warning))
	}
	for _, f := range res.IncludeSkipped {
		fmt.Fprintln(out, ui.Yellow(workroom.SkippedSymlink(f)))
	}
	if res.IncludeWarning != "" {
		fmt.Fprintln(out, ui.Yellow(res.IncludeWarning))
	}
	if res.ChangesWarning != "" {
		fmt.Fprintln(out, ui.Yellow(res.ChangesWarning))
	}
	if err != nil {
		return err
	}

	if panel.Shown() {
		fmt.Fprintln(out)
	}
	fmt.Fprintln(out, ui.Green(fmt.Sprintf("Workroom '%s' created successfully at %s.", res.Name, ui.DisplayPath(res.Path))))

	// Offer to open the workroom in the user's editor
	editor := os.Getenv("EDITOR")
	if editor != "" && !svc.Pretend && offerEditor {
		open, err := svc.ConfirmFn(fmt.Sprintf("Open workroom in %s?", editor))
		if err != nil {
			return err
		}
		if open {
			if err := openEditor(editor, res.Path); err != nil {
				return fmt.Errorf("failed to open editor: %w", err)
			}
		}
	}

	return nil
}

// commitHash is what --start-commit takes: a full SHA-1 or SHA-256 commit hash, as git prints one.
var commitHash = regexp.MustCompile(`^(?:[0-9a-f]{40}|[0-9a-f]{64})$`)

// askSelect asks a person to pick one of options, returning its index. Tests replace it.
var askSelect = ui.Select

// chooseStart asks a person at a terminal what a create that would leave work out includes: the
// commits and changes, the commits only, or neither. Only the choices that apply are offered.
func chooseStart(work vcs.LocalWork) (workroom.Start, error) {
	var starts []workroom.Start
	var options []string
	switch {
	case work.Uncommitted && work.Ahead > 0:
		starts = append(starts, workroom.StartLocalWithChanges, workroom.StartLocal)
		options = append(options, "Include my commits and changes", "Include my commits only")
	case work.Uncommitted:
		starts = append(starts, workroom.StartLocalWithChanges)
		options = append(options, "Include my changes")
	default:
		starts = append(starts, workroom.StartLocal)
		options = append(options, "Include my commits")
	}
	starts = append(starts, workroom.StartOrigin)
	options = append(options, "Leave it out")
	question := "New workrooms start from what you've pushed. Include this work in the new one?"
	if note := work.BehindNote(); note != "" {
		question = note + " " + question
	}
	i, err := askSelect(work.Summary()+".", question, options)
	if err != nil {
		return "", err
	}
	return starts[i], nil
}

// openEditor opens path with editor, a command line such as $EDITOR, attached to this terminal.
// Tests replace it.
var openEditor = func(editor, path string) error {
	parts := strings.Fields(editor)
	args := append(parts[1:], path)
	cmd := exec.Command(parts[0], args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
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
	createCmd.Flags().StringVar(&createStartCommit, "start-commit", "", "Start from this commit, the start_commit a refused create reported, without fetching (used by the desktop app)")
	_ = createCmd.Flags().MarkHidden("start-commit")
	createCmd.Flags().StringVar(&createProject, "project", "", "Project directory to create the workroom in (defaults to the current directory)")
	createCmd.Flags().BoolVar(&createNoEditor, "no-editor", false, "Do not offer to open the new workroom in $EDITOR")
	createCmd.Flags().BoolVar(&createSkipSetup, "skip-setup", false, "Create without running the setup script, and without asking to approve it")
	createCmd.Flags().StringVar(&createStart, "start", "", "What to include when you have commits you haven't pushed, or changes you haven't committed: local-with-changes (both), local (your commits), origin (neither), or ask (stop with exit 3 and say what there is). A terminal asks when unset")
	rootCmd.AddCommand(createCmd)
}
