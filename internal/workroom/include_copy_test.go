package workroom

import (
	"os"
	"path/filepath"
	"slices"
	"syscall"
	"testing"
)

// Value: protects=an included file arrives with its contents and exact mode whatever the umask,
// under parents the copy makes; fails_when=the mode is left to OpenFile, which the umask filters,
// or parents aren't made; no_claim=the remote path (tar on the host)
func TestCopyIncludedKeepsContentsAndModes(t *testing.T) {
	old := syscall.Umask(0o077)
	t.Cleanup(func() { syscall.Umask(old) })
	root, dest := t.TempDir(), t.TempDir()
	for path, mode := range map[string]os.FileMode{".env": 0o664, "config/master.key": 0o600, "bin/tool": 0o755} {
		full := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(path), mode); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(full, mode); err != nil {
			t.Fatal(err)
		}
	}
	got := CopyIncluded(root, dest, []string{".env", "bin/tool", "config/master.key"})
	if !slices.Equal(got.Copied, []string{".env", "bin/tool", "config/master.key"}) || len(got.Failures) != 0 {
		t.Fatalf("CopyIncluded = %+v", got)
	}
	if want := int64(len(".env") + len("bin/tool") + len("config/master.key")); got.Bytes != want {
		t.Fatalf("Bytes = %d, want %d", got.Bytes, want)
	}
	for path, mode := range map[string]os.FileMode{".env": 0o664, "config/master.key": 0o600, "bin/tool": 0o755} {
		info, err := os.Stat(filepath.Join(dest, path))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != mode {
			t.Errorf("%s mode = %o, want %o", path, info.Mode().Perm(), mode)
		}
		if body, _ := os.ReadFile(filepath.Join(dest, path)); string(body) != path {
			t.Errorf("%s = %q, want %q", path, body, path)
		}
	}
}

// Value: protects=a file the new workroom already has is never overwritten; fails_when=the copy
// truncates or replaces it; no_claim=none beyond protects
func TestCopyIncludedLeavesAnExistingFile(t *testing.T) {
	root, dest := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".env"), []byte("root"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, ".env"), []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := CopyIncluded(root, dest, []string{".env"})
	if len(got.Copied) != 0 || len(got.Failures) != 0 {
		t.Fatalf("CopyIncluded = %+v, want nothing copied and no failure", got)
	}
	if body, _ := os.ReadFile(filepath.Join(dest, ".env")); string(body) != "mine" {
		t.Fatalf(".env = %q, want it untouched", body)
	}
}

// Value: protects=one unreadable file is reported and the rest still copy; fails_when=the first
// failure stops the copy, or goes unreported; no_claim=the step's warning text (see cmd tests)
func TestCopyIncludedReportsAnUnreadableFileAndCopiesTheRest(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-000 file")
	}
	root, dest := t.TempDir(), t.TempDir()
	for _, name := range []string{"a.key", "b.key"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(name), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(filepath.Join(root, "a.key"), 0); err != nil {
		t.Fatal(err)
	}
	got := CopyIncluded(root, dest, []string{"a.key", "b.key"})
	if !slices.Equal(got.Copied, []string{"b.key"}) || len(got.Failures) != 1 {
		t.Fatalf("CopyIncluded = %+v, want b.key copied and a.key failed", got)
	}
	if _, err := os.Lstat(filepath.Join(dest, "a.key")); err == nil {
		t.Fatal("a.key left a file behind in the workroom")
	}
}
