package vcs

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// Value: protects=FileAt returns a committed file as a checkout writes it (line-ending filters applied), reports a missing file or a repository with no commit as absent, and Ignored is true only for an untracked ignored path; fails_when=FileAt reads raw blobs, errors on an empty repository, or Ignored reports a tracked file as ignored; why_new=the trust tests reach these only through the CLI and never with a filter or an empty repository; seam=none; no_claim=other filters (only text eol=crlf is exercised)
func TestFileAtAndIgnored(t *testing.T) {
	dir := t.TempDir()
	git(t, dir, "init", "-q", "-b", "main")
	if text, ok, err := FileAt(dir, "", "scripts/s"); err != nil || ok || text != nil {
		t.Fatalf("empty repository: %q %v %v", text, ok, err)
	}

	write := func(rel, body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, rel)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, rel), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(".gitattributes", "scripts/s text eol=crlf\n")
	write("scripts/s", "a\nb\n")
	write(".gitignore", "ignored.txt\nscripts/s\n")
	write("ignored.txt", "x")
	git(t, dir, "add", "-f", ".gitattributes", ".gitignore", "scripts/s")
	git(t, dir, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "one")

	text, ok, err := FileAt(dir, "", "scripts/s")
	if err != nil || !ok || string(text) != "a\r\nb\r\n" {
		t.Fatalf("FileAt = %q %v %v, want CRLF bytes", text, ok, err)
	}
	if _, ok, err := FileAt(dir, "HEAD", "scripts/none"); err != nil || ok {
		t.Fatalf("missing file: %v %v", ok, err)
	}
	if _, ok, err := FileAt(dir, "nowhere", "scripts/s"); err != nil || ok {
		t.Fatalf("unknown rev: %v %v", ok, err)
	}

	if !Ignored(dir, "ignored.txt") {
		t.Fatal("an untracked ignored file was not ignored")
	}
	if Ignored(dir, "scripts/s") {
		t.Fatal("a tracked file counted as ignored")
	}
}

// Value: protects=FileAt converts with the commit's own .gitattributes, as a checkout of it does,
// not the root checkout's; fails_when=a branch that changed its line endings is judged by the
// root's rules and its approval never matches the file that runs; why_new=found by Codex on PR
// #510; seam=none; no_claim=a git older than 2.40 (falls back to the root's attributes)
func TestFileAtUsesTheCommitsOwnAttributes(t *testing.T) {
	dir := t.TempDir()
	git(t, dir, "init", "-q", "-b", "main")
	write := func(rel, body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, rel)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, rel), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(".gitattributes", "scripts/s text eol=lf\n")
	write("scripts/s", "a\nb\n")
	git(t, dir, "add", ".")
	git(t, dir, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "lf")
	// The root's checkout has moved on to other rules than the commit judged.
	write(".gitattributes", "scripts/s text eol=crlf\n")

	text, ok, err := FileAt(dir, "", "scripts/s")
	if err != nil || !ok || string(text) != "a\nb\n" {
		t.Fatalf("FileAt = %q %v %v, want the commit's LF bytes", text, ok, err)
	}
}

// Value: protects=a committed symlinked script is read as the file it points to, as running the
// checkout's copy reads it, and one pointing outside the repository is ErrLinkOutside; fails_when=
// FileAt returns the link's own text (an approval that never matches the file that runs);
// why_new=found by /ship's QA probe of a symlinked setup script; seam=none; no_claim=chains of
// more than one link
func TestFileAtFollowsASymlinkWithinTheCommit(t *testing.T) {
	dir := t.TempDir()
	git(t, dir, "init", "-q", "-b", "main")
	if err := os.MkdirAll(filepath.Join(dir, "scripts"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "scripts", "real.sh"), []byte("#!/bin/sh\necho real\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	for link, target := range map[string]string{"workroom_setup": "real.sh", "outside": "../../elsewhere.sh"} {
		if err := os.Symlink(target, filepath.Join(dir, "scripts", link)); err != nil {
			t.Fatal(err)
		}
	}
	git(t, dir, "add", ".")
	git(t, dir, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "links")

	text, ok, err := FileAt(dir, "", "scripts/workroom_setup")
	if err != nil || !ok || string(text) != "#!/bin/sh\necho real\n" {
		t.Fatalf("FileAt = %q %v %v, want the target's bytes", text, ok, err)
	}
	if _, _, err := FileAt(dir, "", "scripts/outside"); !errors.Is(err, ErrLinkOutside) {
		t.Fatalf("a link out of the repository: %v, want ErrLinkOutside", err)
	}
	// A linked directory along the path is followed too, and a directory is no file.
	if err := os.Symlink("scripts", filepath.Join(dir, "bin")); err != nil {
		t.Fatal(err)
	}
	git(t, dir, "add", "bin")
	git(t, dir, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "dir link")
	if text, ok, err := FileAt(dir, "", "bin/workroom_setup"); err != nil || !ok || string(text) != "#!/bin/sh\necho real\n" {
		t.Fatalf("through a linked directory: %q %v %v", text, ok, err)
	}
	if _, ok, err := FileAt(dir, "", "scripts"); err != nil || ok {
		t.Fatalf("a directory: %v %v, want no file", ok, err)
	}
}
