package updater

import (
	"runtime"
	"testing"
)

func TestIsNewer(t *testing.T) {
	tests := []struct {
		name     string
		current  string
		latest   string
		expected bool
	}{
		{"newer patch", "1.0.0", "1.0.1", true},
		{"newer minor", "1.0.0", "1.1.0", true},
		{"newer major", "1.0.0", "2.0.0", true},
		{"same version", "1.2.3", "1.2.3", false},
		{"older version", "2.0.0", "1.0.0", false},
		{"with v prefix current", "v1.0.0", "1.0.1", true},
		{"with v prefix latest", "1.0.0", "v1.0.1", true},
		{"both v prefix", "v1.0.0", "v1.0.1", true},
		{"both v prefix same", "v1.0.0", "v1.0.0", false},
		{"invalid current", "dev", "1.0.0", false},
		{"invalid latest", "1.0.0", "bad", false},
		{"both invalid", "dev", "bad", false},
		{"major jump", "v1.2.3", "v2.0.0", true},
		{"minor higher patch lower", "v1.2.5", "v1.3.0", true},
		{"patch only", "v0.9.9", "v0.9.10", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := IsNewer(tt.current, tt.latest)
			if got != tt.expected {
				t.Errorf("IsNewer(%q, %q) = %v, want %v", tt.current, tt.latest, got, tt.expected)
			}
		})
	}
}

func TestParseVersion(t *testing.T) {
	tests := []struct {
		input    string
		expected []int
	}{
		{"1.2.3", []int{1, 2, 3}},
		{"v1.2.3", []int{1, 2, 3}},
		{"0.0.0", []int{0, 0, 0}},
		{"dev", nil},
		{"1.2", nil},
		{"1.2.three", nil},
		{"", nil},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := parseVersion(tt.input)
			if tt.expected == nil {
				if got != nil {
					t.Errorf("parseVersion(%q) = %v, want nil", tt.input, got)
				}
				return
			}
			if got == nil {
				t.Fatalf("parseVersion(%q) = nil, want %v", tt.input, tt.expected)
			}
			for i := range 3 {
				if got[i] != tt.expected[i] {
					t.Errorf("parseVersion(%q)[%d] = %d, want %d", tt.input, i, got[i], tt.expected[i])
				}
			}
		})
	}
}

func TestBuildArchiveURL(t *testing.T) {
	tests := []struct {
		name     string
		version  string
		goos     string
		goarch   string
		expected string
	}{
		{
			"darwin amd64",
			"v1.3.0", "darwin", "amd64",
			"https://github.com/joelmoss/workroom/releases/download/v1.3.0/workroom_1.3.0_darwin_amd64.tar.gz",
		},
		{
			"darwin arm64",
			"v1.3.0", "darwin", "arm64",
			"https://github.com/joelmoss/workroom/releases/download/v1.3.0/workroom_1.3.0_darwin_arm64.tar.gz",
		},
		{
			"linux amd64",
			"v2.0.0", "linux", "amd64",
			"https://github.com/joelmoss/workroom/releases/download/v2.0.0/workroom_2.0.0_linux_amd64.tar.gz",
		},
		{
			"windows amd64",
			"v1.0.0", "windows", "amd64",
			"https://github.com/joelmoss/workroom/releases/download/v1.0.0/workroom_1.0.0_windows_amd64.zip",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := BuildArchiveURL(tt.version, tt.goos, tt.goarch)
			if got != tt.expected {
				t.Errorf("BuildArchiveURL(%q, %q, %q) =\n  %s\nwant:\n  %s", tt.version, tt.goos, tt.goarch, got, tt.expected)
			}
		})
	}
}

func TestBuildArchiveURLCurrentPlatform(t *testing.T) {
	url := BuildArchiveURL("v1.0.0", runtime.GOOS, runtime.GOARCH)
	if url == "" {
		t.Error("BuildArchiveURL returned empty string for current platform")
	}
	// Verify it contains the current OS and arch
	if !contains(url, runtime.GOOS) {
		t.Errorf("URL %q does not contain GOOS %q", url, runtime.GOOS)
	}
	if !contains(url, runtime.GOARCH) {
		t.Errorf("URL %q does not contain GOARCH %q", url, runtime.GOARCH)
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchString(s, substr)
}

func searchString(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
