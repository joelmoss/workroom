package docsite

import (
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// stableMarker marks docs that describe stable behaviour although they were added since the latest
// stable release (a fix to how a shipped feature is described). On a line of its own it covers the
// next heading's section, or the whole page when no heading comes before it; in a table row it
// covers that row.
const stableMarker = "<!-- stable -->"

var (
	tableRow       = regexp.MustCompile(`^\s{0,3}\|`)
	tableSeparator = regexp.MustCompile(`^\s{0,3}\|[\s:|-]+$`)
	nightlyNote    = regexp.MustCompile(`\(?Nightly only\.?\)?`)
)

// TestDocsSiteNightlyMarkers fails when a page, heading or table row added since the latest stable
// release has no Nightly marker. Everything on master after a stable tag ships only in Nightly
// until the next stable release, so docs for it are Nightly only until then (docs-site/README.md,
// "Nightly"). When the release is cut its tag becomes the new baseline and the rule relaxes on its
// own.
func TestDocsSiteNightlyMarkers(t *testing.T) {
	tag, err := gitOutput("describe", "--tags", "--match", "v*", "--exclude", "*-*", "--abbrev=0", "HEAD")
	if err != nil {
		if os.Getenv("CI") != "" {
			t.Fatalf("no stable release tag to compare the docs with (%v); check out with tags (fetch-depth: 0)", err)
		}
		t.Skipf("no stable release tag to compare the docs with: %v", err)
	}
	tag = strings.TrimSpace(tag)
	pagesDir := filepath.Join(root, "pages")
	err = filepath.WalkDir(pagesDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".md") {
			return err
		}
		cur, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(pagesDir, p)
		rel = filepath.ToSlash(rel)
		old, gitErr := gitOutput("show", tag+":docs-site/pages/"+rel)
		var oldPage *string
		if gitErr == nil {
			oldPage = &old
		}
		for _, problem := range unmarkedSince(tag, oldPage, string(cur)) {
			t.Errorf("pages/%s: %s", rel, problem)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func gitOutput(args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", root}, args...)...).Output()
	if exitErr, ok := err.(*exec.ExitError); ok {
		return "", fmt.Errorf("git %s: %v: %s", args[0], err, strings.TrimSpace(string(exitErr.Stderr)))
	}
	return string(out), err
}

// docKeys are what make a heading or table row the same one across releases: its anchor, and a
// row's first cell, ignoring any Nightly note, so rewording or dropping a badge isn't "new".
type docKeys struct{ headings, rows map[string]bool }

func rowKey(line string) string {
	cells := strings.Split(strings.TrimSpace(line), "|")
	if len(cells) < 2 {
		return ""
	}
	return anchor(strings.TrimSpace(nightlyNote.ReplaceAllString(cells[1], "")))
}

// bodyLines yields the page body's lines outside code blocks, with their file line numbers.
func bodyLines(src string, each func(n int, line string)) {
	text := strings.ReplaceAll(src, "\r\n", "\n")
	first := 1
	if rest, ok := strings.CutPrefix(text, "---\n"); ok {
		if fm, body, closed := strings.Cut(rest, "\n---\n"); closed {
			text, first = body, strings.Count(fm, "\n")+4
		}
	}
	var fence string
	for i, line := range strings.Split(text, "\n") {
		if m := fencePattern.FindStringSubmatch(line); m != nil {
			switch fence {
			case "":
				fence = m[1]
			case m[1]:
				fence = ""
			}
			continue
		}
		if fence == "" {
			each(i+first, line)
		}
	}
}

func keysOf(src string) docKeys {
	keys := docKeys{headings: map[string]bool{}, rows: map[string]bool{}}
	bodyLines(src, func(_ int, line string) {
		if h := headingPattern.FindStringSubmatch(line); h != nil {
			keys.headings[anchor(h[2])] = true
		} else if tableRow.MatchString(line) && !tableSeparator.MatchString(line) {
			keys.rows[rowKey(line)] = true
		}
	})
	return keys
}

func nightlyPage(src string) bool {
	rest, ok := strings.CutPrefix(strings.ReplaceAll(src, "\r\n", "\n"), "---\n")
	fm, _, closed := strings.Cut(rest, "\n---\n")
	return ok && closed && regexp.MustCompile(`(?m)^nightly:\s*true\s*$`).MatchString(fm)
}

// unmarkedSince lists the headings and table rows of cur that are not in old (the page at the
// stable tag, nil when the page is new) and carry neither a Nightly marker nor stableMarker.
func unmarkedSince(tag string, old *string, cur string) []string {
	if nightlyPage(cur) {
		return nil
	}
	var problems []string
	var known docKeys
	if old != nil {
		known = keysOf(*old)
	}
	type section struct {
		level   int
		covered bool
	}
	var stack []section
	pending, pageCovered, sawHeading := false, false, false
	bodyLines(cur, func(n int, line string) {
		trimmed := strings.TrimSpace(line)
		if trimmed == stableMarker {
			if sawHeading {
				pending = true
			} else {
				pageCovered = true
			}
			return
		}
		covered := pageCovered
		for _, s := range stack {
			covered = covered || s.covered
		}
		if h := headingPattern.FindStringSubmatch(line); h != nil {
			sawHeading = true
			level := len(h[1])
			for len(stack) > 0 && stack[len(stack)-1].level >= level {
				stack = stack[:len(stack)-1]
			}
			covered = pageCovered
			for _, s := range stack {
				covered = covered || s.covered
			}
			marked := strings.HasSuffix(h[2], " {nightly}") || pending
			pending = false
			stack = append(stack, section{level, marked})
			if old != nil && !covered && !marked && !known.headings[anchor(h[2])] {
				problems = append(problems, fmt.Sprintf(
					"line %d: heading %q is new since %s, the latest stable release, so it ships only in Nightly: "+
						"end it with {nightly}, or put %s on the line above if it describes stable behaviour",
					n, strings.TrimSpace(h[2]), tag, stableMarker))
			}
			return
		}
		if trimmed != "" {
			pending = false
		}
		if old == nil || covered || !tableRow.MatchString(line) || tableSeparator.MatchString(line) {
			return
		}
		if nightlyNote.MatchString(line) || strings.Contains(line, stableMarker) || known.rows[rowKey(line)] {
			return
		}
		problems = append(problems, fmt.Sprintf(
			"line %d: table row %q is new since %s, the latest stable release, so it ships only in Nightly: "+
				"start its description with \"Nightly only.\", or add %s to the row if it describes stable behaviour",
			n, strings.TrimSpace(strings.Split(strings.TrimSpace(line), "|")[1]), tag, stableMarker))
	})
	if old == nil && !pageCovered {
		problems = append(problems, fmt.Sprintf(
			"the page is new since %s, the latest stable release, so it ships only in Nightly: "+
				"set nightly: true in its front matter, or put %s before its first heading if it describes stable behaviour",
			tag, stableMarker))
	}
	return problems
}

func TestUnmarkedSinceFindsNewDocs(t *testing.T) {
	const front = "---\ntitle: T\ndescription: D.\n---\n\n"
	old := front + "## Kept\n\n| Name | What |\n| --- | --- |\n| Old (Nightly only) | Was Nightly. |\n"
	cases := []struct {
		name string
		old  *string
		cur  string
		want []string // a substring of each problem, in order
	}{
		{"unchanged", &old, old, nil},
		{"a badge dropped at release", &old, strings.Replace(old, "Old (Nightly only)", "Old", 1), nil},
		{"new heading", &old, old + "\n## Fresh\n", []string{`line 12: heading "Fresh"`}},
		{"new nightly heading", &old, old + "\n## Fresh {nightly}\n", nil},
		{"stable escape on a heading", &old, old + "\n<!-- stable -->\n## Fresh\n", nil},
		{"escape kept for the next heading only", &old,
			old + "\n<!-- stable -->\n\n## Fresh\n\nText.\n\n## Later\n", []string{`heading "Later"`}},
		{"subsection of a nightly section", &old, old + "\n## Fresh {nightly}\n\n### Detail\n\n| New | x |\n", nil},
		{"the next sibling is not covered", &old, old + "\n### Fresh {nightly}\n\n## Next\n", []string{`heading "Next"`}},
		{"new row", &old, old + "| New | Thing. |\n", []string{`line 11: table row "New"`}},
		{"new nightly row", &old, old + "| New | Nightly only. Thing. |\n", nil},
		{"new stable row", &old, old + "| New | Thing. <!-- stable --> |\n", nil},
		{"code blocks are ignored", &old, old + "\n```md\n## Not a heading\n| no | row |\n```\n", nil},
		{"new page", nil, front + "## A\n", []string{"the page is new"}},
		{"new nightly page", nil, "---\ntitle: T\ndescription: D.\nnightly: true\n---\n\n## A\n", nil},
		{"new stable page", nil, front + "<!-- stable -->\n\n## A\n", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := unmarkedSince("v9.9.9", c.old, c.cur)
			if len(got) != len(c.want) {
				t.Fatalf("got %d problems, want %d: %q", len(got), len(c.want), got)
			}
			for i, want := range c.want {
				if !strings.Contains(got[i], want) {
					t.Errorf("problem %d = %q, want it to contain %q", i, got[i], want)
				}
			}
		})
	}
}
