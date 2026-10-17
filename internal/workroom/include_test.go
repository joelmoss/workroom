package workroom

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
)

// includeRoot is a git repository with gitignore and the include file, both given line by line,
// and a home of its own so the developer's global excludes stay out of it.
func includeRoot(t *testing.T, gitignore, include []string, files ...string) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	t.Setenv("HOME", t.TempDir())
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	root := t.TempDir()
	write := func(name, body string) {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(".gitignore", lines(gitignore))
	if include != nil {
		write(IncludeFile, lines(include))
	}
	for _, f := range files {
		write(f, f)
	}
	for _, args := range [][]string{
		{"init", "-q"},
		{"add", ".gitignore"},
		{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "first"},
	} {
		if out, err := exec.Command("git", append([]string{"-C", root}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	return root
}

func lines(l []string) string {
	out := ""
	for _, s := range l {
		out += s + "\n"
	}
	return out
}

// Value: protects=only files that match the include file AND are gitignored are included, matched
// as git matches; fails_when=the gitignore filter is dropped, or a hand matcher replaces git's;
// no_claim=copying (see the create tests)
func TestIncludedFilesMatchesAsGitDoes(t *testing.T) {
	for _, tc := range []struct {
		name               string
		gitignore, include []string
		files              []string
		want               []string
	}{
		{
			name:      "an ignored file listed by name",
			gitignore: []string{".env"}, include: []string{".env"},
			files: []string{".env"}, want: []string{".env"},
		},
		{
			name:      "an untracked file that is not ignored is left out",
			gitignore: []string{".env"}, include: []string{".env", "notes.txt"},
			files: []string{".env", "notes.txt"}, want: []string{".env"},
		},
		{
			name:      "**/ reaches nested files",
			gitignore: []string{".env"}, include: []string{"**/.env"},
			files: []string{".env", "app/.env", "app/deep/.env"},
			want:  []string{".env", "app/.env", "app/deep/.env"},
		},
		{
			name:      "a directory pattern takes the files under it",
			gitignore: []string{"secrets/"}, include: []string{"secrets/"},
			files: []string{"secrets/a.json", "secrets/deep/b.json"},
			want:  []string{"secrets/a.json", "secrets/deep/b.json"},
		},
		{
			name:      "negation drops a file the include file named before",
			gitignore: []string{"*.key"}, include: []string{"*.key", "!old.key"},
			files: []string{"master.key", "old.key"}, want: []string{"master.key"},
		},
		{
			name:      "negation can't re-include under an included directory, as in git",
			gitignore: []string{"secrets/"}, include: []string{"secrets/**", "!secrets/deep/skip.json"},
			files: []string{"secrets/deep/c.json", "secrets/deep/skip.json"},
			want:  []string{"secrets/deep/c.json", "secrets/deep/skip.json"},
		},
		{
			name:      "an include file that matches nothing",
			gitignore: []string{".env"}, include: []string{"config/master.key"},
			files: []string{".env"}, want: nil,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := includeRoot(t, tc.gitignore, tc.include, tc.files...)
			got, ok, err := IncludedFiles(root)
			if err != nil || !ok {
				t.Fatalf("IncludedFiles = %v, %v, %v", got, ok, err)
			}
			if !slices.Equal(got.Files, tc.want) {
				t.Fatalf("IncludedFiles = %q, want %q", got.Files, tc.want)
			}
		})
	}
}

// Value: protects=a root without an include file has no include step at all; fails_when=a missing
// file reads as an empty one; no_claim=none beyond protects
func TestIncludedFilesWithoutAnIncludeFile(t *testing.T) {
	root := includeRoot(t, []string{".env"}, nil, ".env")
	if got, ok, err := IncludedFiles(root); ok || err != nil || got.Files != nil || got.Symlinks != nil {
		t.Fatalf("IncludedFiles = %q, %v, %v, want nothing and not ok", got, ok, err)
	}
}

// Value: protects=a symlink in the root is never followed or copied, and is reported as skipped so
// a symlinked .env doesn't vanish without a word; fails_when=the regular-file check goes and a link
// to a secret outside the root is copied, or the skip goes unreported; no_claim=none beyond protects
func TestIncludedFilesSkipsSymlinksAndSaysSo(t *testing.T) {
	root := includeRoot(t, []string{".env*"}, []string{".env*"}, ".env")
	if err := os.Symlink(filepath.Join(root, ".env"), filepath.Join(root, ".env.link")); err != nil {
		t.Fatal(err)
	}
	got, _, err := IncludedFiles(root)
	if err != nil || !slices.Equal(got.Files, []string{".env"}) || !slices.Equal(got.Symlinks, []string{".env.link"}) {
		t.Fatalf("IncludedFiles = %q, %v, want files [.env] and symlinks [.env.link]", got, err)
	}
}
