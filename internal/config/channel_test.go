package config

import "testing"

func TestChannelDefault(t *testing.T) {
	c := newTestConfig(t)
	if got := c.Channel(); got != DefaultChannel {
		t.Fatalf("Channel() = %q, want default %q", got, DefaultChannel)
	}
}

func TestSetAndGetChannel(t *testing.T) {
	c := newTestConfig(t)
	if err := c.SetChannel("nightly"); err != nil {
		t.Fatal(err)
	}
	if got := c.Channel(); got != "nightly" {
		t.Fatalf("Channel() = %q, want nightly", got)
	}
	// Overwriting works.
	if err := c.SetChannel("pre"); err != nil {
		t.Fatal(err)
	}
	if got := c.Channel(); got != "pre" {
		t.Fatalf("Channel() after overwrite = %q, want pre", got)
	}
}

// TestChannelReservedNotAProject verifies the channel key behaves like the other
// reserved scalar: it is never returned as a project and never deletable through
// RemoveProject, even alongside a real project.
func TestChannelReservedNotAProject(t *testing.T) {
	c := newTestConfig(t)
	if err := c.SetChannel("pre"); err != nil {
		t.Fatal(err)
	}
	if err := c.AddProject("/repo/alpha", "git"); err != nil {
		t.Fatal(err)
	}

	projects, err := c.AllProjects()
	if err != nil {
		t.Fatal(err)
	}
	if _, isProject := projects["channel"]; isProject {
		t.Fatal("AllProjects returned the reserved 'channel' key as a project")
	}
	if _, ok := projects["/repo/alpha"]; !ok {
		t.Fatal("AllProjects dropped the real project")
	}

	if err := c.RemoveProject("channel"); err != nil {
		t.Fatalf("RemoveProject of reserved 'channel' should be a nil no-op, got %v", err)
	}
	if got := c.Channel(); got != "pre" {
		t.Fatalf("RemoveProject deleted the reserved channel key (now %q)", got)
	}
}
