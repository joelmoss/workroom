package cmd

import (
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/joelmoss/workroom/internal/ui"
	"github.com/joelmoss/workroom/internal/workroom"
	"github.com/mattn/go-isatty"
	"github.com/spf13/cobra"
)

// askConfirm asks a person a yes/no question. Tests replace it.
var askConfirm = ui.Confirm

// stdinIsTerminal reports whether a person can answer on stdin. Tests replace it.
var stdinIsTerminal = func() bool { return isatty.IsTerminal(os.Stdin.Fd()) }

var (
	trustProjectDir string
	trustStdin      string
)

// trustCmd approves a project's setup and teardown scripts by their exact bytes (#363).
var trustCmd = &cobra.Command{
	Use:   "trust",
	Short: "Approve a project's setup and teardown scripts so Workroom runs them",
	Long: "Approve the setup and teardown scripts a create or delete would run next, by their exact contents. " +
		"In a terminal each one is shown first and you are asked. A changed script needs approving again. " +
		"A script git ignores in the project's root needs no approval.",
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "trust"
		svc, dir, scripts, err := judgedScripts()
		if err != nil {
			return err
		}
		var lines []string
		for i, sc := range scripts {
			switch {
			case sc.Exempt:
				lines = append(lines, fmt.Sprintf("scripts/%s is ignored by git, so it needs no approval.", sc.Name))
				continue
			case sc.Trusted:
				lines = append(lines, fmt.Sprintf("scripts/%s is already approved.", sc.Name))
				continue
			}
			// The bytes came on stdin from a caller that has shown them, or no one is here to ask.
			if trustStdin == "" && !jsonOutput && stdinIsTerminal() {
				ok, err := approveScript(os.Stdout, sc)
				if err != nil {
					return err
				}
				if !ok {
					lines = append(lines, fmt.Sprintf("scripts/%s was left unapproved.", sc.Name))
					continue
				}
			}
			record := svc.Trust
			if trustStdin != "" {
				// The app hands over bytes for a project it has registered; one gone meanwhile is
				// refused rather than registered again.
				record = func(dir string, sc workroom.Script) error {
					return svc.Config.SetTrustedScript(dir, sc.Name, sc.SHA256)
				}
			}
			if err := record(dir, sc); err != nil {
				return err
			}
			scripts[i].Trusted = true
			lines = append(lines, ui.Green(fmt.Sprintf("Approved scripts/%s %s.", sc.Name, sc.OriginLabel())))
		}
		if jsonOutput {
			return writeJSONSuccess(os.Stdout, "trust", map[string]any{"scripts": scriptsJSON(scripts)})
		}
		lines = append(lines, absentScripts(scripts)...)
		fmt.Println(strings.Join(lines, "\n"))
		return nil
	},
}

var trustStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Say whether a project's setup and teardown scripts are approved",
	Long: "Say whether the setup and teardown scripts a create or delete would run next are approved. " +
		"Exits 0 when every script there is approved or ignored by git, 1 when one is not, and 2 when it cannot tell.",
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "trust status"
		_, _, scripts, err := judgedScripts()
		if err != nil {
			return exitStatus{code: 2, err: err}
		}
		trusted := true
		for _, sc := range scripts {
			trusted = trusted && sc.Trusted
		}
		if jsonOutput {
			if err := writeJSONSuccess(os.Stdout, "trust status", map[string]any{"trusted": trusted, "scripts": scriptsJSON(scripts)}); err != nil {
				return err
			}
		} else {
			for _, sc := range scripts {
				state := ui.Red("not approved")
				switch {
				case sc.Exempt:
					state = ui.Green("ignored by git, needs no approval")
				case sc.Trusted:
					state = ui.Green("approved")
				}
				fmt.Printf("scripts/%s %s: %s\n", sc.Name, sc.OriginLabel(), state)
			}
			for _, line := range absentScripts(scripts) {
				fmt.Println(line)
			}
		}
		if !trusted {
			return exitStatus{code: 1}
		}
		return nil
	},
}

var untrustCmd = &cobra.Command{
	Use:   "untrust",
	Short: "Forget the approval of a project's setup and teardown scripts",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		currentCommand = "untrust"
		svc, err := newService()
		if err != nil {
			return err
		}
		dir, err := trustedProject(svc)
		if err != nil {
			return err
		}
		if err := svc.Untrust(dir); err != nil {
			return err
		}
		if jsonOutput {
			return writeJSONSuccess(os.Stdout, "untrust", map[string]any{"project": dir})
		}
		fmt.Println("Forgot the approval of this project's scripts.")
		return nil
	},
}

// judgedScripts is the project the trust commands name, judged: the one script read from stdin
// with --stdin, else the scripts it would run next.
func judgedScripts() (*workroom.Service, string, []workroom.Script, error) {
	svc, err := newService()
	if err != nil {
		return nil, "", nil, err
	}
	dir, err := trustedProject(svc)
	if err != nil {
		return nil, "", nil, err
	}
	if trustStdin == "" {
		scripts, err := svc.ProjectScripts(dir)
		return svc, dir, scripts, err
	}
	if trustStdin != workroom.SetupScript && trustStdin != workroom.TeardownScript {
		return nil, "", nil, fmt.Errorf("--stdin takes %s or %s, not %q", workroom.SetupScript, workroom.TeardownScript, trustStdin)
	}
	text, err := io.ReadAll(os.Stdin)
	if err != nil {
		return nil, "", nil, err
	}
	sc, err := svc.JudgeScript(dir, trustStdin, workroom.OriginStdin, "", text)
	return svc, dir, []workroom.Script{sc}, err
}

// trustedProject is the project the trust commands act on: --project or the current directory,
// or, inside one of its workrooms (where every terminal pane opens), that workroom's project.
// Approvals are the project's, so a workroom's path must never take them.
func trustedProject(svc *workroom.Service) (string, error) {
	dir, err := resolveProject(trustProjectDir)
	if err != nil {
		return "", err
	}
	if project, _, found := svc.Config.FindCurrentProject(dir); found {
		return project, nil
	}
	return dir, nil
}

// absentScripts says which of the project's scripts it has none of, unless --stdin named one.
func absentScripts(scripts []workroom.Script) []string {
	if trustStdin != "" {
		return nil
	}
	var lines []string
	for _, name := range []string{workroom.SetupScript, workroom.TeardownScript} {
		if !slices.ContainsFunc(scripts, func(sc workroom.Script) bool { return sc.Name == name }) {
			lines = append(lines, fmt.Sprintf("No scripts/%s.", name))
		}
	}
	return lines
}

func scriptsJSON(scripts []workroom.Script) []map[string]any {
	out := make([]map[string]any, 0, len(scripts))
	for _, sc := range scripts {
		out = append(out, scriptJSON(sc))
	}
	return out
}

func init() {
	for _, c := range []*cobra.Command{trustCmd, trustStatusCmd, untrustCmd} {
		c.Flags().StringVar(&trustProjectDir, "project", "", "Project directory (defaults to the current directory)")
	}
	for _, c := range []*cobra.Command{trustCmd, trustStatusCmd} {
		c.Flags().StringVar(&trustStdin, "stdin", "", "Judge this script's contents, read from stdin, in place of the project's file (used by the desktop app)")
		_ = c.Flags().MarkHidden("stdin")
	}
	trustCmd.AddCommand(trustStatusCmd)
	rootCmd.AddCommand(trustCmd, untrustCmd)
}

// approveScript shows sc, a script this Mac has not approved, on out, and asks whether to approve
// and run it.
func approveScript(out io.Writer, sc workroom.Script) (bool, error) {
	fmt.Fprintln(out, ui.Yellow(fmt.Sprintf("scripts/%s %s has not been approved on this Mac.", sc.Name, sc.OriginLabel())))
	panel := ui.NewLogPanel(out, "scripts/"+sc.Name)
	_, _ = io.WriteString(panel, visibleText(sc.Text))
	panel.Close(true)
	return askConfirm(fmt.Sprintf("Approve scripts/%s and run it?", sc.Name))
}

// visibleText is text as a person must read it before approving it: every character the terminal
// would act on or hide (escape sequences, a carriage return that overwrites a line, bidi overrides,
// zero-width characters, bytes that are not UTF-8) is written out as an escape, so the script
// cannot show one thing and run another. Newlines and tabs stay.
func visibleText(text []byte) string {
	var b strings.Builder
	for len(text) > 0 {
		r, size := utf8.DecodeRune(text)
		switch {
		case r == utf8.RuneError && size <= 1:
			fmt.Fprintf(&b, `\x%02x`, text[0])
		case r == '\n' || r == '\t':
			b.WriteRune(r)
		case unicode.IsControl(r) || unicode.Is(unicode.Cf, r):
			fmt.Fprintf(&b, `\u{%04x}`, r)
		default:
			b.WriteRune(r)
		}
		text = text[size:]
	}
	return b.String()
}
