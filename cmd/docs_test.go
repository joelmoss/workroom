package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/cobra/doc"
)

// cliDocsDir holds the CLI reference pages of the docs site, generated from the commands below. A
// change to a command or flag regenerates them (`make docs-cli`):
//
//	go test ./cmd -run TestCLIDocs -update
const cliDocsDir = "../docs-site/pages/cli"

// TestCLIDocs fails when docs-site/pages/cli no longer matches the commands, so the reference can't
// drift from the CLI.
func TestCLIDocs(t *testing.T) {
	want := cliDocs(t)

	if *updateContracts {
		old, _ := filepath.Glob(filepath.Join(cliDocsDir, "*.md"))
		for _, p := range old {
			if err := os.Remove(p); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.MkdirAll(cliDocsDir, 0o755); err != nil {
			t.Fatal(err)
		}
		for name, content := range want {
			if err := os.WriteFile(filepath.Join(cliDocsDir, name), []byte(content), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		return
	}

	got := map[string]string{}
	files, _ := filepath.Glob(filepath.Join(cliDocsDir, "*.md"))
	for _, p := range files {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		got[filepath.Base(p)] = string(b)
	}
	names := make([]string, 0, len(want)+len(got))
	for name := range want {
		names = append(names, name)
	}
	for name := range got {
		if _, ok := want[name]; !ok {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		g, inGot := got[name]
		w, inWant := want[name]
		if inGot != inWant || g != w {
			t.Errorf("docs-site/pages/cli/%s is stale; run `make docs-cli`", name)
		}
	}
}

// cliDocs renders one docs page per public command, keyed by file name. Hidden commands and flags
// (the app's own) are left out, as cobra leaves them out of --help.
func cliDocs(t *testing.T) map[string]string {
	t.Helper()
	rootCmd.InitDefaultCompletionCmd()
	rootCmd.DisableAutoGenTag = true // the tag carries today's date, so the pages would never be current

	pages := map[string]string{}
	var walk func(c *cobra.Command)
	walk = func(c *cobra.Command) {
		if !c.IsAvailableCommand() && c != rootCmd {
			return
		}
		for _, child := range c.Commands() {
			walk(child)
		}
		var body bytes.Buffer
		if err := doc.GenMarkdownCustom(c, &body, cliDocsLink); err != nil {
			t.Fatal(err)
		}
		pages[cliDocsName(c.CommandPath())] = cliDocsPage(c, body.String())
	}
	walk(rootCmd)
	return pages
}

// cliDocsPage adds front matter and fits cobra's Markdown to docs-site/README.md: the title comes
// from front matter, so cobra's own "## workroom create" heading goes, every code block names its
// language, and prose can't be read as raw HTML.
func cliDocsPage(c *cobra.Command, body string) string {
	_, body, _ = strings.Cut(body, "\n\n")
	var out strings.Builder
	out.WriteString("---\n")
	out.WriteString("title: " + c.CommandPath() + "\n")
	out.WriteString("description: " + strings.TrimSuffix(c.Short, ".") + ".\n")
	out.WriteString("---\n\n")
	out.WriteString("<!-- Generated from the CLI by `make docs-cli`. Don't edit by hand. -->\n\n")
	open := false
	for _, line := range strings.SplitAfter(body, "\n") {
		if line == "```\n" && !open {
			line = "```text\n"
		}
		if strings.HasPrefix(line, "```") {
			open = !open
		} else if !open {
			line = strings.ReplaceAll(line, "<", "&lt;") // help text like <remote>/<branch> isn't HTML
		}
		out.WriteString(line)
	}
	return strings.TrimRight(out.String(), "\n") + "\n"
}

// cliDocsLink turns cobra's link to another command's page (workroom_create.md) into the docs site's
// file name for it.
func cliDocsLink(link string) string { return cliDocsName(strings.TrimSuffix(link, ".md")) }

func cliDocsName(commandPath string) string {
	return strings.NewReplacer(" ", "-", "_", "-").Replace(commandPath) + ".md"
}
