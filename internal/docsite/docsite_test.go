// Package docsite checks the documentation under docs-site/ against the format contract in
// docs-site/README.md: the nav, front matter, Markdown rules, links and heading anchors. Codaset
// renders the pages; this test makes a broken page fail here, before it can merge.
package docsite

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"unicode"

	"go.yaml.in/yaml/v3"
)

const root = "../../docs-site"

type navGroup struct {
	Title string    `yaml:"title"`
	Pages []navPage `yaml:"pages"`
}

type navPage struct {
	Title string `yaml:"title"`
	Page  string `yaml:"page"`
}

type frontMatter struct {
	Title       string `yaml:"title"`
	Description string `yaml:"description"`
	Nightly     bool   `yaml:"nightly"`
}

type link struct {
	image  bool
	text   string
	target string
}

type page struct {
	name    string // path under pages/ without .md
	anchors map[string]bool
	links   []link
}

var (
	namePattern    = regexp.MustCompile(`^[a-z0-9-]+$`)
	headingPattern = regexp.MustCompile(`^(#{1,6})\s+(.*?)\s*#*\s*$`)
	fencePattern   = regexp.MustCompile("^\\s{0,3}(```|~~~)")
	codeSpan       = regexp.MustCompile("`+[^`]*`+")
	linkPattern    = regexp.MustCompile(`(!?)\[([^\]]*)\]\(([^)\s]*)(?:\s+"[^"]*")?\)`)
	refLinkPattern = regexp.MustCompile(`\]\[[^\]]*\]`)
	htmlTag        = regexp.MustCompile(`</?([A-Za-z][A-Za-z0-9-]*)[^>]*>`)
	// CommonMark's autolinks: <scheme:…> or <name@host>, with no spaces. Anything else in angle
	// brackets is raw HTML, `<img src="https://…">` included.
	autolinkTag   = regexp.MustCompile(`^<(?:[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*|[^\s<>@]+@[^\s<>@]+)>$`)
	setextPattern = regexp.MustCompile(`^\s{0,3}(=+|-{2,})\s*$`)
	imageTypes    = map[string]bool{".png": true, ".jpg": true, ".jpeg": true, ".gif": true, ".webp": true}
)

// TestDocsSite checks every page and the nav, reporting every problem rather than the first.
func TestDocsSite(t *testing.T) {
	for _, problem := range check(t, root) {
		t.Error(problem)
	}
}

// check returns every way the docs under dir break the contract.
func check(t *testing.T, dir string) []string {
	t.Helper()
	var problems []string
	report := func(format string, args ...any) { problems = append(problems, fmt.Sprintf(format, args...)) }

	pages := map[string]*page{}
	pagesDir := filepath.Join(dir, "pages")
	err := filepath.WalkDir(pagesDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(pagesDir, p)
		rel = filepath.ToSlash(rel)
		if rel != "." && strings.HasPrefix(d.Name(), ".") { // .DS_Store, editor and tool folders: never pages
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			if rel != "." && !namePattern.MatchString(d.Name()) {
				report("pages/%s: folder names use lowercase letters, digits and hyphens only", rel)
			}
			return nil
		}
		if !strings.HasSuffix(rel, ".md") {
			report("pages/%s: only Markdown pages belong in pages/; images go in images/", rel)
			return nil
		}
		name := strings.TrimSuffix(rel, ".md")
		if !namePattern.MatchString(path.Base(name)) {
			report("pages/%s: file names use lowercase letters, digits and hyphens only", rel)
		}
		if depth := strings.Count(name, "/"); (name == "index" && depth != 0) || (name != "index" && depth != 1) {
			report("pages/%s: every page except index.md sits exactly one folder deep", rel)
		}
		src, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		pg := parsePage(name, src, func(format string, args ...any) {
			report("pages/%s: %s", rel, fmt.Sprintf(format, args...))
		})
		pages[name] = pg
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", pagesDir, err)
	}
	if _, ok := pages["index"]; !ok {
		report("pages/index.md is missing; it is the docs home")
	}

	// The nav: every entry names a real page, and every page but the home appears exactly once.
	navSrc, err := os.ReadFile(filepath.Join(dir, "nav.yml"))
	if err != nil {
		t.Fatalf("reading nav.yml: %v", err)
	}
	var groups []navGroup
	dec := yaml.NewDecoder(bytes.NewReader(navSrc))
	dec.KnownFields(true)
	if err := dec.Decode(&groups); err != nil {
		report("nav.yml: %v", err)
	}
	seen := map[string]int{}
	for _, g := range groups {
		if strings.TrimSpace(g.Title) == "" {
			report("nav.yml: a group has no title")
		}
		if len(g.Pages) == 0 {
			report("nav.yml: group %q has no pages", g.Title)
		}
		for _, e := range g.Pages {
			if strings.TrimSpace(e.Title) == "" {
				report("nav.yml: %q has no title", e.Page)
			}
			seen[e.Page]++
			if _, ok := pages[e.Page]; !ok {
				report("nav.yml: %q has no page at pages/%s.md", e.Page, e.Page)
			}
		}
	}
	names := make([]string, 0, len(pages))
	for name := range pages {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		switch {
		case name == "index" && seen[name] > 0:
			report("nav.yml: index is the docs home and is not listed in the nav")
		case name != "index" && seen[name] == 0:
			report("pages/%s.md: not listed in nav.yml", name)
		case seen[name] > 1:
			report("nav.yml: %q is listed %d times", name, seen[name])
		}
	}

	// Links and images resolve, anchors included.
	for _, name := range names {
		pg := pages[name]
		pageDir := path.Dir(path.Join("pages", name+".md"))
		for _, l := range pg.links {
			where := fmt.Sprintf("pages/%s.md: link %q", name, l.target)
			if l.image && strings.TrimSpace(l.text) == "" {
				report("%s: an image needs alt text", where)
			}
			if strings.HasPrefix(l.target, "https://") || strings.HasPrefix(l.target, "http://") ||
				strings.HasPrefix(l.target, "mailto:") {
				continue
			}
			file, anchor, _ := strings.Cut(l.target, "#")
			if file == "" {
				if !pg.anchors[anchor] {
					report("%s: no heading on this page has the anchor #%s", where, anchor)
				}
				continue
			}
			resolved := path.Join(pageDir, file)
			if l.image {
				// Codaset serves only these types, and never a symlink (WorkroomDocs::Site).
				if !strings.HasPrefix(resolved, "images/") {
					report("%s: images live in images/", where)
				} else if !imageTypes[strings.ToLower(path.Ext(resolved))] {
					report("%s: images are .png, .jpg, .jpeg, .gif or .webp", where)
				} else if info, err := os.Lstat(filepath.Join(dir, filepath.FromSlash(resolved))); err != nil {
					report("%s: no such image", where)
				} else if info.Mode()&os.ModeSymlink != 0 {
					report("%s: an image can't be a symlink", where)
				}
				continue
			}
			if !strings.HasPrefix(resolved, "pages/") || !strings.HasSuffix(resolved, ".md") {
				report("%s: link to another page by its relative .md path", where)
				continue
			}
			target, ok := pages[strings.TrimSuffix(strings.TrimPrefix(resolved, "pages/"), ".md")]
			if !ok {
				report("%s: no such page", where)
				continue
			}
			if anchor != "" && !target.anchors[anchor] {
				report("%s: %s has no heading with the anchor #%s", where, resolved, anchor)
			}
		}
	}
	return problems
}

// parsePage reads one page's front matter, headings and links, reporting what breaks the contract.
func parsePage(name string, src []byte, report func(string, ...any)) *page {
	pg := &page{name: name, anchors: map[string]bool{}}
	text := strings.ReplaceAll(string(src), "\r\n", "\n")

	rest, ok := strings.CutPrefix(text, "---\n")
	fmSrc, body, closed := strings.Cut(rest, "\n---\n")
	first := strings.Count(fmSrc, "\n") + 4 // the file line the body starts on, for messages
	if !ok || !closed {
		first = 1
		report("starts with YAML front matter between --- lines")
		body = text
	} else {
		var fm frontMatter
		dec := yaml.NewDecoder(strings.NewReader(fmSrc))
		dec.KnownFields(true)
		if err := dec.Decode(&fm); err != nil {
			report("front matter: %v", err)
		}
		if strings.TrimSpace(fm.Title) == "" {
			report("front matter needs a title")
		}
		if strings.TrimSpace(fm.Description) == "" {
			report("front matter needs a description")
		}
	}

	var fence string
	prevBlank := true
	for i, line := range strings.Split(body, "\n") {
		if m := fencePattern.FindStringSubmatch(line); m != nil {
			switch fence {
			case "":
				fence = m[1]
				if strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(line), m[1][:1])) == "" {
					report("line %d: name the code block's language, for example ```sh or ```text", i+first)
				}
			case m[1]:
				fence = ""
			}
			prevBlank = false
			continue
		}
		if fence != "" {
			continue
		}
		if !prevBlank && setextPattern.MatchString(line) && !strings.HasPrefix(strings.TrimSpace(line), "---") {
			report("line %d: use ## headings, not underlined (setext) ones", i+first)
		}
		prevBlank = strings.TrimSpace(line) == ""

		outside := codeSpan.ReplaceAllString(line, "")
		if refLinkPattern.MatchString(outside) {
			report("line %d: use inline links, not reference-style [text][ref] links", i+first)
		}
		for _, m := range htmlTag.FindAllStringSubmatch(outside, -1) {
			if !autolinkTag.MatchString(m[0]) && !strings.EqualFold(m[1], "kbd") {
				report("line %d: <%s> is not allowed; <kbd> is the only raw HTML", i+first, m[1])
			}
		}
		if strings.Contains(outside, "</kbd><kbd>") {
			report("line %d: write a key combination as one <kbd>, such as <kbd>⌘D</kbd>", i+first)
		}
		for _, m := range linkPattern.FindAllStringSubmatch(outside, -1) {
			pg.links = append(pg.links, link{image: m[1] == "!", text: m[2], target: m[3]})
		}

		h := headingPattern.FindStringSubmatch(line)
		if strings.Contains(outside, "{nightly}") && (h == nil || !strings.HasSuffix(h[2], " {nightly}")) {
			report("line %d: {nightly} goes only at the end of a heading; write \"Nightly only.\" in prose", i+first)
		}
		if h == nil {
			continue
		}
		if level := len(h[1]); level < 2 || level > 4 {
			report("line %d: headings are ## to ####; the title comes from front matter", i+first)
		}
		if strings.ContainsAny(codeSpan.ReplaceAllString(h[2], ""), "*_") {
			report("line %d: no emphasis in headings; put identifiers in `code`", i+first)
		}
		id := anchor(h[2])
		for n := 1; pg.anchors[id]; n++ {
			id = fmt.Sprintf("%s-%d", anchor(h[2]), n)
		}
		pg.anchors[id] = true
	}
	if fence != "" {
		report("a code block is never closed")
	}
	return pg
}

// anchor derives a heading's id as docs-site/README.md "Heading anchors" pins it (commonmarker's
// header_ids): plain text, lowercased, disallowed characters removed, spaces to hyphens.
func anchor(heading string) string {
	heading = strings.TrimSuffix(heading, " {nightly}")
	heading = htmlTag.ReplaceAllString(heading, "")
	heading = linkPattern.ReplaceAllString(heading, "$2")
	heading = strings.ReplaceAll(heading, "`", "")
	var b strings.Builder
	for _, r := range strings.ToLower(heading) {
		switch {
		case r == ' ':
			b.WriteRune('-')
		case r == '-' || unicode.IsLetter(r) || unicode.Is(unicode.M, r) || unicode.IsNumber(r) ||
			unicode.Is(unicode.Pc, r):
			b.WriteRune(r)
		}
	}
	return b.String()
}

func TestAnchor(t *testing.T) {
	for heading, want := range map[string]string{
		"Open a pull request":               "open-a-pull-request",
		"The `workrooms_dir` key":           "the-workrooms_dir-key",
		"Run <kbd>⌘</kbd><kbd>R</kbd>":      "run-r",
		"See [the CLI](../cli/workroom.md)": "see-the-cli",
		"Approve scripts {nightly}":         "approve-scripts",
		"Ports & forwarding: 3000/tcp":      "ports--forwarding-3000tcp",
		"Café über":                         "café-über",
	} {
		if got := anchor(heading); got != want {
			t.Errorf("anchor(%q) = %q, want %q", heading, got, want)
		}
	}
}

// TestCheckFindsBreakage proves the check can fail: a small site with one of each mistake must
// report every one of them.
func TestCheckFindsBreakage(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) {
		p := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("nav.yml", "- title: Guides\n  pages:\n    - title: A\n      page: guides/a\n    - title: Gone\n      page: guides/gone\n")
	write("pages/index.md", "---\ntitle: Home\ndescription: The home.\n---\n\nSee [A](guides/a.md#missing).\n")
	write("pages/guides/a.md", "---\ntitle: A\n---\n\n# Title again\n\n## Same\n\n## Same\n\n"+
		"[ok](#same-1) [bad](#nope) [page](b.md) ![](../../images/x.png) <div>\n\n```\ncode\n```\n\n"+
		"Press <kbd>⌘</kbd><kbd>D</kbd>.\n\n<img src=\"https://x.example/a.png\"> <https://ok.example/> <me@ok.example>\n\n"+
		"![icon](../../images/icon.svg) ![shot](../../images/link.png)\n")
	write("images/real.png", "x")
	if err := os.Symlink("real.png", filepath.Join(dir, "images", "link.png")); err != nil {
		t.Fatal(err)
	}
	write("pages/guides/b.md", "---\ntitle: B\ndescription: B.\nweight: 3\n---\n\nText. {nightly}\n\n## Fine {nightly}\n")
	write("pages/guides/Bad_Name.md", "---\ntitle: X\ndescription: X.\n---\n")

	got := strings.Join(check(t, dir), "\n")
	for _, want := range []string{
		`pages/index.md: link "guides/a.md#missing": pages/guides/a.md has no heading with the anchor #missing`,
		"pages/guides/a.md: front matter needs a description",
		"pages/guides/a.md: line 5: headings are ## to ####",
		`pages/guides/a.md: link "#nope": no heading on this page has the anchor #nope`,
		`pages/guides/a.md: link "../../images/x.png": an image needs alt text`,
		`pages/guides/a.md: link "../../images/x.png": no such image`,
		"pages/guides/a.md: line 11: <div> is not allowed",
		"pages/guides/a.md: line 13: name the code block's language",
		"pages/guides/a.md: line 17: write a key combination as one <kbd>",
		"pages/guides/a.md: line 19: <img> is not allowed",
		`pages/guides/a.md: link "../../images/icon.svg": images are .png, .jpg, .jpeg, .gif or .webp`,
		`pages/guides/a.md: link "../../images/link.png": an image can't be a symlink`,
		"pages/guides/b.md: front matter: yaml: unmarshal errors",
		"pages/guides/b.md: not listed in nav.yml",
		"pages/guides/b.md: line 7: {nightly} goes only at the end of a heading",
		"pages/guides/Bad_Name.md: file names use lowercase letters",
		`nav.yml: "guides/gone" has no page at pages/guides/gone.md`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing problem %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "line 19: <https>") || strings.Contains(got, "line 19: <me@") {
		t.Errorf("an autolink was reported as raw HTML:\n%s", got)
	}
	if strings.Contains(got, "#same-1") {
		t.Errorf("a duplicate heading's -1 anchor was reported missing:\n%s", got)
	}
}
