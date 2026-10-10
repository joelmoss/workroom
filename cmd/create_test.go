package cmd

import (
	"io"
	"path/filepath"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/workroom"
)

// editorFixture is a Service for a fresh repository whose next workroom is named foo, the
// repository, and where foo will be made. It fails any editor that opens unless a test replaces
// openEditor itself.
func editorFixture(t *testing.T) (*workroom.Service, string, string) {
	t.Helper()
	home := contractHomeDir(t)
	project := gitRepo(t, filepath.Join(home, "src", "app"))
	cfg, err := config.New("")
	if err != nil {
		t.Fatal(err)
	}
	saved := openEditor
	openEditor = func(string, string) error {
		t.Fatal("the editor was opened")
		return nil
	}
	t.Cleanup(func() { openEditor = saved })
	svc := &workroom.Service{Config: cfg, NameGenFunc: func() string { return "foo" }}
	return svc, project, filepath.Join(home, "workrooms", "foo")
}

func TestCreatePromptsToOpenEditorWhenSet(t *testing.T) {
	svc, project, _ := editorFixture(t)
	t.Setenv("EDITOR", "code")

	confirmCalled := false
	svc.ConfirmFn = func(msg string) (bool, error) {
		if strings.Contains(msg, "Open workroom in code?") {
			confirmCalled = true
		}
		return false, nil
	}

	if err := createWorkroom(svc, project, io.Discard, true); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !confirmCalled {
		t.Fatal("expected editor confirm prompt")
	}
}

func TestCreateDoesNotPromptEditorWhenUnset(t *testing.T) {
	svc, project, _ := editorFixture(t)
	t.Setenv("EDITOR", "")

	editorPrompted := false
	svc.ConfirmFn = func(msg string) (bool, error) {
		if strings.Contains(msg, "Open workroom in") {
			editorPrompted = true
		}
		return false, nil
	}

	if err := createWorkroom(svc, project, io.Discard, true); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if editorPrompted {
		t.Fatal("should not prompt for editor when EDITOR is unset")
	}
}

func TestCreateOpensEditorWhenConfirmed(t *testing.T) {
	svc, project, wrPath := editorFixture(t)
	t.Setenv("EDITOR", "myeditor")

	var openedEditor, openedPath string
	svc.ConfirmFn = func(msg string) (bool, error) { return true, nil }
	openEditor = func(editor, path string) error {
		openedEditor = editor
		openedPath = path
		return nil
	}

	if err := createWorkroom(svc, project, io.Discard, true); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if openedEditor != "myeditor" {
		t.Fatalf("expected editor 'myeditor', got %q", openedEditor)
	}
	if openedPath != wrPath {
		t.Fatalf("expected path %q, got %q", wrPath, openedPath)
	}
}

// --no-editor and --pretend each skip the prompt.
func TestCreateSkipsEditorPrompt(t *testing.T) {
	for _, mode := range []struct {
		name        string
		pretend     bool
		offerEditor bool
	}{{"pretend", true, true}, {"no editor", false, false}} {
		t.Run(mode.name, func(t *testing.T) {
			svc, project, _ := editorFixture(t)
			svc.Pretend = mode.pretend
			t.Setenv("EDITOR", "code")

			editorPrompted := false
			svc.ConfirmFn = func(msg string) (bool, error) {
				if strings.Contains(msg, "Open workroom in") {
					editorPrompted = true
				}
				return false, nil
			}

			if err := createWorkroom(svc, project, io.Discard, mode.offerEditor); err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if editorPrompted {
				t.Fatalf("should not prompt for editor (%s)", mode.name)
			}
		})
	}
}
