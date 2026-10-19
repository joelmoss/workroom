package config

import (
	"os"
	"testing"
)

// An approval is one digest per script; a value of the wrong type approves nothing, and setting
// one replaces it; "" forgets it, and the key goes once none is left.
func TestTrustedScripts(t *testing.T) {
	c := newTestConfig(t)
	if err := c.SetTrustedScript("/proj", "workroom_setup", "abc"); err == nil {
		t.Fatal("an approval registered a project")
	}
	if err := os.WriteFile(c.Path(), []byte(`{"/proj":{"vcs":"git","trusted_scripts":{"workroom_setup":7,"workroom_teardown":"def"},"x":1}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	projects, err := c.AllProjects()
	if err != nil {
		t.Fatal(err)
	}
	if got := projects["/proj"].TrustedScripts; len(got) != 1 || got["workroom_teardown"] != "def" {
		t.Fatalf("decoded %v", got)
	}

	if err := c.SetTrustedScript("/proj", "workroom_setup", "abc"); err != nil {
		t.Fatal(err)
	}
	projects, _ = c.AllProjects()
	if got := projects["/proj"].TrustedScripts; got["workroom_setup"] != "abc" || got["workroom_teardown"] != "def" {
		t.Fatalf("after set %v", got)
	}

	for _, name := range []string{"workroom_setup", "workroom_teardown"} {
		if err := c.SetTrustedScript("/proj", name, ""); err != nil {
			t.Fatal(err)
		}
	}
	data, _ := c.Read()
	proj := data["/proj"].(map[string]any)
	if _, ok := proj["trusted_scripts"]; ok || proj["x"] == nil {
		t.Fatalf("after forgetting both: %v", proj)
	}
}
