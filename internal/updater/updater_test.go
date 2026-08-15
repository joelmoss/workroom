package updater

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/joelmoss/workroom/internal/channel"
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
		{"both v prefix", "v1.0.0", "v1.0.1", true},
		{"both v prefix same", "v1.0.0", "v1.0.0", false},
		{"invalid current", "dev", "1.0.0", false},
		{"invalid latest", "1.0.0", "bad", false},
		// Prerelease-aware precedence (SemVer 2.0).
		{"prerelease < release", "1.0.0-rc.1", "1.0.0", true},
		{"release > prerelease", "1.0.0", "1.0.0-rc.1", false},
		{"beta < rc", "1.0.0-beta.2", "1.0.0-rc.1", true},
		{"beta.1 < beta.2", "2.0.0-beta.1", "2.0.0-beta.2", true},
		{"nightly numeric identifier", "2.0.0-nightly.10", "2.0.0-nightly.11", true},
		{"higher base beats prerelease", "2.0.0-beta.1", "2.0.1", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IsNewer(tt.current, tt.latest); got != tt.expected {
				t.Errorf("IsNewer(%q, %q) = %v, want %v", tt.current, tt.latest, got, tt.expected)
			}
		})
	}
}

func TestIsNewerInChannel(t *testing.T) {
	tests := []struct {
		name      string
		ch        channel.Channel
		current   string
		candidate string
		want      bool
	}{
		// stable/pre delegate to semver.
		{"stable newer", channel.Stable, "1.0.0", "1.0.1", true},
		{"pre rc over beta", channel.Pre, "2.0.0-beta.2", "2.0.0-rc.1", true},
		// nightly by commit-count, robust even if the base differs.
		{"nightly higher count", channel.Nightly, "2.0.0-nightly.900", "2.0.0-nightly.901", true},
		{"nightly same count", channel.Nightly, "2.0.0-nightly.900", "2.0.0-nightly.900", false},
		{"nightly lower base but higher count wins", channel.Nightly, "2.1.0-nightly.900", "2.0.0-nightly.901", true},
		{"nightly onto non-nightly current", channel.Nightly, "1.3.0", "2.0.0-nightly.5", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isNewerInChannel(tt.ch, tt.current, tt.candidate); got != tt.want {
				t.Errorf("isNewerInChannel(%q, %q, %q) = %v, want %v", tt.ch, tt.current, tt.candidate, got, tt.want)
			}
		})
	}
}

func TestNightlyBuild(t *testing.T) {
	tests := []struct {
		in string
		n  int
		ok bool
	}{
		{"2.0.0-nightly.941", 941, true},
		{"v2.0.0-nightly.1", 1, true},
		{"2.0.0-beta.1", 0, false},
		{"1.3.0", 0, false},
		{"2.0.0-nightly.x", 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.in, func(t *testing.T) {
			n, ok := nightlyBuild(tt.in)
			if n != tt.n || ok != tt.ok {
				t.Errorf("nightlyBuild(%q) = (%d, %v), want (%d, %v)", tt.in, n, ok, tt.n, tt.ok)
			}
		})
	}
}

func TestInAppBundle(t *testing.T) {
	tests := []struct {
		path string
		want bool
	}{
		{"/Applications/Workroom.app/Contents/Resources/workroom", true},
		{"/usr/local/bin/workroom", false},
		{"/Users/x/go/bin/workroom", false},
	}
	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			if got := inAppBundle(tt.path); got != tt.want {
				t.Errorf("inAppBundle(%q) = %v, want %v", tt.path, got, tt.want)
			}
		})
	}
}

// asset builds an archive asset name for the current platform.
func platformAsset(version string) githubAsset {
	ext := "tar.gz"
	if runtime.GOOS == "windows" {
		ext = "zip"
	}
	name := fmt.Sprintf("workroom_%s_%s_%s.%s", version, runtime.GOOS, runtime.GOARCH, ext)
	return githubAsset{Name: name, BrowserDownloadURL: "https://example.test/download/" + name}
}

func nightlyAsset() githubAsset {
	ext := "tar.gz"
	if runtime.GOOS == "windows" {
		ext = "zip"
	}
	name := fmt.Sprintf("workroom_nightly_%s_%s.%s", runtime.GOOS, runtime.GOARCH, ext)
	return githubAsset{Name: name, BrowserDownloadURL: "https://example.test/download/nightly/" + name}
}

func checksums() githubAsset {
	return githubAsset{Name: checksumsAsset, BrowserDownloadURL: "https://example.test/checksums.txt"}
}

func withGetJSON(t *testing.T, fn func(url string, v any) error) {
	t.Helper()
	orig := getJSON
	getJSON = fn
	t.Cleanup(func() { getJSON = orig })
}

// TestLatestForChannelStable is a REGRESSION guard: the stable channel must keep
// using GET /releases/latest (GitHub's own "Latest" selection), not a list sort,
// and must return the archive whose name matches the historical
// workroom_<ver>_<os>_<arch> convention.
func TestLatestForChannelStable(t *testing.T) {
	var hitLatest bool
	stable := githubRelease{TagName: "v1.3.0", Assets: []githubAsset{platformAsset("1.3.0"), checksums()}}
	withGetJSON(t, func(url string, v any) error {
		if !strings.HasSuffix(url, "/releases/latest") {
			t.Fatalf("stable channel must query /releases/latest, got %q", url)
		}
		hitLatest = true
		*(v.(*githubRelease)) = stable
		return nil
	})

	rel, err := LatestForChannel(channel.Stable)
	if err != nil {
		t.Fatal(err)
	}
	if !hitLatest {
		t.Fatal("did not hit /releases/latest")
	}
	if rel.Tag != "v1.3.0" || rel.Version != "v1.3.0" {
		t.Errorf("tag/version = %q/%q, want v1.3.0", rel.Tag, rel.Version)
	}
	wantName := platformAsset("1.3.0").Name
	if rel.AssetName != wantName {
		t.Errorf("asset name = %q, want %q (archive-naming regression)", rel.AssetName, wantName)
	}
	if rel.ChecksumURL == "" {
		t.Error("checksum URL not resolved")
	}
}

func TestLatestForChannelPreFloor(t *testing.T) {
	// pre must pick the newest stable-OR-prerelease, excluding appcast + nightly.
	list := []githubRelease{
		{TagName: "nightly", Name: "2.1.0-nightly.99", Assets: []githubAsset{nightlyAsset()}},
		{TagName: "appcast", Assets: nil},
		{TagName: "v2.0.0-beta.21", Prerelease: true, Assets: []githubAsset{platformAsset("2.0.0-beta.21"), checksums()}},
		{TagName: "v1.3.0", Assets: []githubAsset{platformAsset("1.3.0"), checksums()}},
		{TagName: "v2.0.0-beta.5", Prerelease: true, Assets: []githubAsset{platformAsset("2.0.0-beta.5")}},
		{TagName: "v2.0.0-draft", Draft: true, Assets: []githubAsset{platformAsset("2.0.0-draft")}},
	}
	withGetJSON(t, func(url string, v any) error {
		if !strings.Contains(url, "?per_page") {
			t.Fatalf("pre channel must list releases, got %q", url)
		}
		*(v.(*[]githubRelease)) = list
		return nil
	})

	rel, err := LatestForChannel(channel.Pre)
	if err != nil {
		t.Fatal(err)
	}
	if rel.Tag != "v2.0.0-beta.21" {
		t.Errorf("pre picked %q, want v2.0.0-beta.21 (newest prerelease, nightly/appcast/draft excluded)", rel.Tag)
	}
}

func TestLatestForChannelNightly(t *testing.T) {
	nightly := githubRelease{
		TagName: "nightly",
		Name:    "2.0.0-nightly.941",
		Assets:  []githubAsset{nightlyAsset(), checksums()},
	}
	withGetJSON(t, func(url string, v any) error {
		if !strings.Contains(url, "/tags/nightly") {
			t.Fatalf("nightly channel must query /tags/nightly, got %q", url)
		}
		*(v.(*githubRelease)) = nightly
		return nil
	})

	rel, err := LatestForChannel(channel.Nightly)
	if err != nil {
		t.Fatal(err)
	}
	if rel.Tag != "nightly" {
		t.Errorf("tag = %q, want nightly", rel.Tag)
	}
	if rel.Version != "2.0.0-nightly.941" {
		t.Errorf("version = %q, want 2.0.0-nightly.941 (resolved from release name)", rel.Version)
	}
}

func TestSha256File(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a.bin")
	data := []byte("hello workroom")
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	want := hex.EncodeToString(sum[:])
	got, err := sha256File(p)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("sha256File = %q, want %q", got, want)
	}
}

func TestVerifyChecksum(t *testing.T) {
	dir := t.TempDir()
	archive := filepath.Join(dir, "workroom_1.0.0_x.tar.gz")
	data := []byte("archive bytes")
	if err := os.WriteFile(archive, data, 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	good := hex.EncodeToString(sum[:])

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%s  workroom_1.0.0_x.tar.gz\n", good)
		fmt.Fprint(w, "deadbeef  other_file.tar.gz\n")
	}))
	defer srv.Close()

	t.Run("match", func(t *testing.T) {
		rel := Release{Tag: "v1.0.0", AssetName: "workroom_1.0.0_x.tar.gz", ChecksumURL: srv.URL}
		if err := verifyChecksum(archive, rel, false, os.Stderr); err != nil {
			t.Errorf("verifyChecksum unexpected error: %v", err)
		}
	})

	t.Run("mismatch aborts", func(t *testing.T) {
		bad := filepath.Join(dir, "workroom_1.0.0_x.tar.gz.bad")
		if err := os.WriteFile(bad, []byte("tampered"), 0o644); err != nil {
			t.Fatal(err)
		}
		rel := Release{Tag: "v1.0.0", AssetName: "workroom_1.0.0_x.tar.gz", ChecksumURL: srv.URL}
		if err := verifyChecksum(bad, rel, false, os.Stderr); err == nil {
			t.Error("verifyChecksum accepted a tampered archive")
		}
	})

	t.Run("missing checksums skipped", func(t *testing.T) {
		rel := Release{Tag: "nightly", AssetName: "x", ChecksumURL: ""}
		if err := verifyChecksum(archive, rel, false, os.Stderr); err != nil {
			t.Errorf("expected skip (no error) when no checksums asset, got %v", err)
		}
	})
}
