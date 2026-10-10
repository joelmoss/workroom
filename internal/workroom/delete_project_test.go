package workroom

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
)

// TestUnsafeProjectDeletePath is a table-driven test of the guard function itself.
func TestUnsafeProjectDeletePath(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	homeCanon, _ := config.CanonicalPath(home)

	// A standalone leaf temp dir that will be registered as the only project.
	leaf := t.TempDir()
	leafCanon, _ := config.CanonicalPath(leaf)

	// An ancestor dir (parent of leaf).
	ancestor := filepath.Dir(leaf)

	// Another project that will be registered.
	other := t.TempDir()
	otherCanon, _ := config.CanonicalPath(other)

	// Build a config with the leaf and other registered.
	cfgDir := t.TempDir()
	cfg, err := config.New(filepath.Join(cfgDir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(leafCanon, "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(otherCanon, "git"); err != nil {
		t.Fatal(err)
	}

	workroomsDir, _ := cfg.WorkroomsDir()
	workroomsDirCanon, _ := config.CanonicalPath(workroomsDir)
	workroomsDirParent := filepath.Dir(workroomsDirCanon)

	tests := []struct {
		name   string
		canon  string
		refuse bool
	}{
		{"root slash", "/", true},
		{"home dir", homeCanon, true},
		{"empty string", "", true},
		{"relative path", "relative/path", true},
		{"equals workrooms_dir", workroomsDirCanon, true},
		{"ancestor of workrooms_dir", workroomsDirParent, true},
		{"ancestor of another project", ancestor, true},
		{"standalone leaf project", leafCanon, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := unsafeProjectDeletePath(tt.canon, cfg)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.refuse {
				t.Fatalf("unsafeProjectDeletePath(%q) = %v, want %v", tt.canon, got, tt.refuse)
			}
		})
	}
}

// TestUnsafeProjectDeletePathIgnoresScalarSettings: run from inside the project, a global
// base_branch key resolved as a path lies under it and wrongly refused the delete.
func TestUnsafeProjectDeletePathIgnoresScalarSettings(t *testing.T) {
	leaf, _ := config.CanonicalPath(t.TempDir())
	cfg, err := config.New(filepath.Join(t.TempDir(), "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.AddProject(leaf, "git"); err != nil {
		t.Fatal(err)
	}
	if err := cfg.SetGlobalBaseBranch("develop"); err != nil {
		t.Fatal(err)
	}
	t.Chdir(leaf)
	got, err := unsafeProjectDeletePath(leaf, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if got {
		t.Fatal("a global base_branch refused deleting the project it was run from")
	}
}
