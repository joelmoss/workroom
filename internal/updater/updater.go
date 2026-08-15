package updater

import (
	"archive/tar"
	"archive/zip"
	"bufio"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/joelmoss/workroom/internal/channel"
	"golang.org/x/mod/semver"
)

const releasesAPI = "https://api.github.com/repos/joelmoss/workroom/releases"

type githubAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

type githubRelease struct {
	TagName string `json:"tag_name"`
	Name    string `json:"name"` // for the nightly release, the resolved "X.Y.Z-nightly.<count>"
	// Prerelease is decoded but deliberately unread: channel.Classify(TagName) is the sole
	// channel-membership signal, not GitHub's own prerelease flag. Unlike Draft (which does
	// gate selection below), this field participates in nothing — don't mistake that for an
	// oversight.
	Prerelease bool          `json:"prerelease"`
	Draft      bool          `json:"draft"`
	Assets     []githubAsset `json:"assets"`
}

// getJSON fetches url and decodes the JSON body into v. It is a package var so
// tests can inject fixture responses without hitting the network.
var getJSON = func(url string, v any) error {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github.v3+json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to check for updates: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GitHub API returned status %d", resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(v); err != nil {
		return fmt.Errorf("failed to parse release info: %w", err)
	}
	return nil
}

// checksumsAsset is the name of the goreleaser checksums file uploaded with
// every release (see .goreleaser.yml `checksum.name_template`).
const checksumsAsset = "checksums.txt"

// Release is a resolved channel release: which build to install and how to
// verify it.
type Release struct {
	Tag         string // GitHub release tag ("v2.0.0", "v2.0.0-beta.1", "nightly")
	Version     string // resolved version ("v2.0.0"; nightly: "2.0.0-nightly.<count>")
	AssetName   string // archive filename, used to find its checksum line
	AssetURL    string // direct download URL of the archive for this os/arch
	ChecksumURL string // download URL of checksums.txt ("" if the release has none)
}

// LatestForChannel resolves the newest release available on ch for the running
// os/arch.
//
//   - stable:  GET /releases/latest — byte-identical to the historical behavior
//     (GitHub's own "Latest" selection), so stable users see no change.
//   - pre:     GET /releases and pick the newest stable-OR-prerelease (the floor
//     for pre), by SemVer 2.0 precedence.
//   - nightly: GET /releases/tags/nightly directly — the fixed rolling release,
//     whose resolved version (with the monotonic commit-count) lives in its name.
func LatestForChannel(ch channel.Channel) (Release, error) {
	goos, goarch := runtime.GOOS, runtime.GOARCH
	switch ch {
	case channel.Stable:
		var r githubRelease
		if err := getJSON(releasesAPI+"/latest", &r); err != nil {
			return Release{}, err
		}
		return releaseArchive(r, goos, goarch)

	case channel.Pre:
		var rs []githubRelease
		if err := getJSON(releasesAPI+"?per_page=100", &rs); err != nil {
			return Release{}, err
		}
		return selectForFloor(channel.Pre, rs, goos, goarch)

	case channel.Nightly:
		var r githubRelease
		if err := getJSON(releasesAPI+"/tags/"+channel.NightlyTag, &r); err != nil {
			return Release{}, err
		}
		return releaseArchive(r, goos, goarch)

	default:
		return Release{}, fmt.Errorf("unknown release channel %q", ch)
	}
}

// selectForFloor picks the newest release accepted by user's floor set from a
// list, by SemVer precedence, then returns its archive for goos/goarch.
func selectForFloor(user channel.Channel, releases []githubRelease, goos, goarch string) (Release, error) {
	var best *githubRelease
	for i := range releases {
		r := &releases[i]
		if r.Draft {
			continue
		}
		tagCh, ok := channel.Classify(r.TagName)
		if !ok || !channel.Accepts(user, tagCh) {
			continue
		}
		if best == nil || IsNewer(best.TagName, r.TagName) {
			best = r
		}
	}
	if best == nil {
		return Release{}, fmt.Errorf("no release found for channel %q", user)
	}
	return releaseArchive(*best, goos, goarch)
}

// releaseArchive builds a Release from a github release for goos/goarch. The
// resolved version is the release name when set (the nightly release carries
// "X.Y.Z-nightly.<count>" there); otherwise it falls back to the tag.
func releaseArchive(r githubRelease, goos, goarch string) (Release, error) {
	name, url, ok := assetFor(r.Assets, goos, goarch)
	if !ok {
		return Release{}, fmt.Errorf("no %s/%s asset in release %q", goos, goarch, r.TagName)
	}
	version := r.Name
	if version == "" {
		version = r.TagName
	}
	rel := Release{Tag: r.TagName, Version: version, AssetName: name, AssetURL: url}
	for _, a := range r.Assets {
		if a.Name == checksumsAsset {
			rel.ChecksumURL = a.BrowserDownloadURL
			break
		}
	}
	return rel, nil
}

// assetFor returns the name and download URL of the archive asset matching
// goos/goarch. It keys on the "_<goos>_<goarch>." fragment shared by both the
// tagged (workroom_<ver>_<os>_<arch>) and nightly (workroom_nightly_<os>_<arch>)
// names.
func assetFor(assets []githubAsset, goos, goarch string) (name, url string, ok bool) {
	frag := "_" + goos + "_" + goarch + "."
	for _, a := range assets {
		if strings.Contains(a.Name, frag) {
			return a.Name, a.BrowserDownloadURL, true
		}
	}
	return "", "", false
}

// IsNewer reports whether latest has higher precedence than current using
// SemVer 2.0 rules (prerelease-aware: 1.0.0-rc < 1.0.0, 1.0.0-beta.2 <
// 1.0.0-rc.1). Both may omit the "v" prefix. Unparseable input returns false.
func IsNewer(current, latest string) bool {
	c, l := ensureV(current), ensureV(latest)
	if !semver.IsValid(c) || !semver.IsValid(l) {
		return false
	}
	return semver.Compare(c, l) < 0
}

// isNewerInChannel reports whether candidate is a newer build than current for
// ch. stable/pre use SemVer precedence; nightly compares the monotonic
// commit-count embedded in "X.Y.Z-nightly.<count>", which stays correct even if
// the nightly's version base shifts between builds. If current is not itself a
// nightly build (e.g. the user just switched onto the channel) any resolvable
// nightly candidate counts as newer.
func isNewerInChannel(ch channel.Channel, current, candidate string) bool {
	if ch == channel.Nightly {
		cur, curOK := nightlyBuild(current)
		cand, candOK := nightlyBuild(candidate)
		if curOK && candOK {
			return cand > cur
		}
		return candOK
	}
	return IsNewer(current, candidate)
}

// nightlyBuild extracts the commit-count from a nightly version string of the
// form "X.Y.Z-nightly.<count>". ok is false if v is not a nightly build version.
func nightlyBuild(v string) (int, bool) {
	const marker = "-nightly."
	i := strings.LastIndex(v, marker)
	if i < 0 {
		return 0, false
	}
	n, err := strconv.Atoi(v[i+len(marker):])
	if err != nil {
		return 0, false
	}
	return n, true
}

// ensureV prepends the "v" that golang.org/x/mod/semver requires, if absent.
func ensureV(v string) string {
	if strings.HasPrefix(v, "v") {
		return v
	}
	return "v" + v
}

// Update installs the newest build on ch, replacing the running binary. When
// allowDowngrade is true (an explicit channel switch), it installs the channel's
// tip even if that is a version downgrade. It refuses to touch a copy bundled
// inside the macOS app (managed by Sparkle) and verifies the download against
// the release checksums before replacing the binary.
func Update(currentVersion string, ch channel.Channel, allowDowngrade, verbose, pretend bool, w io.Writer) error {
	if currentVersion == "dev" {
		return fmt.Errorf("cannot update a dev build — install from a release instead")
	}

	currentBin, err := resolveSelf()
	if err != nil {
		return err
	}
	if inAppBundle(currentBin) {
		return fmt.Errorf(
			"this workroom is bundled inside the Workroom app and is managed by it — " +
				"update via the app's \"Check for Updates…\" instead")
	}

	fmt.Fprintf(w, "Checking the %s channel...\n", ch)

	rel, err := LatestForChannel(ch)
	if err != nil {
		return err
	}

	switch {
	case isNewerInChannel(ch, currentVersion, rel.Version):
		fmt.Fprintf(w, "Update available: %s → %s\n", currentVersion, rel.Version)
	case allowDowngrade && rel.Version != currentVersion:
		fmt.Fprintf(w, "Switching to the %s channel: %s → %s (downgrade)\n", ch, currentVersion, rel.Version)
	default:
		fmt.Fprintf(w, "Already up-to-date (%s)\n", currentVersion)
		return nil
	}

	if pretend {
		fmt.Fprintf(w, "(pretend) Would download and install %s\n", rel.Version)
		return nil
	}

	if verbose {
		fmt.Fprintf(w, "Downloading %s\n", rel.AssetURL)
	}

	tmpDir, err := os.MkdirTemp("", "workroom-update-*")
	if err != nil {
		return fmt.Errorf("failed to create temp directory: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	archivePath := filepath.Join(tmpDir, rel.AssetName)
	if err := downloadFile(rel.AssetURL, archivePath); err != nil {
		return fmt.Errorf("failed to download update: %w", err)
	}

	if err := verifyChecksum(archivePath, rel, verbose, w); err != nil {
		return err
	}

	binaryName := "workroom"
	if runtime.GOOS == "windows" {
		binaryName = "workroom.exe"
	}

	extractedPath := filepath.Join(tmpDir, binaryName)
	if runtime.GOOS == "windows" {
		err = extractZip(archivePath, tmpDir, binaryName)
	} else {
		err = extractTarGz(archivePath, tmpDir, binaryName)
	}
	if err != nil {
		return fmt.Errorf("failed to extract update: %w", err)
	}

	// Preserve permissions from the current binary.
	info, err := os.Stat(currentBin)
	if err != nil {
		return fmt.Errorf("failed to stat current binary: %w", err)
	}
	if err := os.Chmod(extractedPath, info.Mode()); err != nil {
		return fmt.Errorf("failed to set permissions: %w", err)
	}

	// Atomic replace: rename new over old. Falls back to copy if cross-device.
	if err := os.Rename(extractedPath, currentBin); err != nil {
		if err := copyFile(extractedPath, currentBin); err != nil {
			return fmt.Errorf("failed to replace binary: %w", err)
		}
	}

	fmt.Fprintf(w, "Updated workroom %s → %s\n", currentVersion, rel.Version)
	return nil
}

// CheckOnly reports whether a newer build is available on ch, without installing
// and without any side effects (it never mutates config).
func CheckOnly(currentVersion string, ch channel.Channel, w io.Writer) error {
	if currentVersion == "dev" {
		fmt.Fprintf(w, "Running dev build — cannot check for updates\n")
		return nil
	}

	fmt.Fprintf(w, "Checking the %s channel...\n", ch)

	rel, err := LatestForChannel(ch)
	if err != nil {
		return err
	}

	if isNewerInChannel(ch, currentVersion, rel.Version) {
		fmt.Fprintf(w, "Update available: %s → %s\n", currentVersion, rel.Version)
		fmt.Fprintf(w, "Run 'workroom update' to install\n")
	} else {
		fmt.Fprintf(w, "Already up-to-date (%s)\n", currentVersion)
	}

	return nil
}

// resolveSelf returns the fully symlink-resolved path of the running executable.
func resolveSelf() (string, error) {
	bin, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("failed to find current binary: %w", err)
	}
	bin, err = filepath.EvalSymlinks(bin)
	if err != nil {
		return "", fmt.Errorf("failed to resolve binary path: %w", err)
	}
	return bin, nil
}

// inAppBundle reports whether path lives inside a macOS .app bundle. The app's
// CommandLineInstaller symlinks the bundled CLI into $PATH; that copy is owned
// by the app and updated by Sparkle, so self-updating it would overwrite the
// signed, notarized bundle binary and fight Sparkle.
func inAppBundle(path string) bool {
	return strings.Contains(path, ".app/Contents/")
}

// verifyChecksum verifies archivePath against the release's checksums.txt. A
// release with no checksums asset is verify-skipped with a warning rather than
// failing (defensive — every current release ships one).
func verifyChecksum(archivePath string, rel Release, verbose bool, w io.Writer) error {
	if rel.ChecksumURL == "" {
		fmt.Fprintf(w, "warning: no checksums.txt for %s — skipping verification\n", rel.Tag)
		return nil
	}

	want, err := fetchChecksum(rel.ChecksumURL, rel.AssetName)
	if err != nil {
		return err
	}
	got, err := sha256File(archivePath)
	if err != nil {
		return fmt.Errorf("failed to hash download: %w", err)
	}
	if !strings.EqualFold(got, want) {
		return fmt.Errorf("checksum mismatch for %s (expected %s, got %s)", rel.AssetName, want, got)
	}
	if verbose {
		fmt.Fprintf(w, "Checksum verified (%s)\n", rel.AssetName)
	}
	return nil
}

// fetchChecksum downloads a checksums.txt and returns the SHA-256 for assetName.
func fetchChecksum(url, assetName string) (string, error) {
	resp, err := http.Get(url)
	if err != nil {
		return "", fmt.Errorf("failed to download checksums: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("checksums download returned status %d", resp.StatusCode)
	}

	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		// Each line is "<sha256>  <filename>".
		fields := strings.Fields(sc.Text())
		if len(fields) == 2 && fields[1] == assetName {
			return fields[0], nil
		}
	}
	if err := sc.Err(); err != nil {
		return "", fmt.Errorf("failed to read checksums: %w", err)
	}
	return "", fmt.Errorf("no checksum entry for %s", assetName)
}

// sha256File returns the hex-encoded SHA-256 of the file at path.
func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func downloadFile(url, dest string) error {
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download returned status %d", resp.StatusCode)
	}

	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = io.Copy(f, resp.Body)
	return err
}

func extractTarGz(archivePath, destDir, targetName string) error {
	f, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer f.Close()

	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		if filepath.Base(hdr.Name) == targetName && hdr.Typeflag == tar.TypeReg {
			outPath := filepath.Join(destDir, targetName)
			out, err := os.OpenFile(outPath, os.O_CREATE|os.O_WRONLY, 0o755)
			if err != nil {
				return err
			}
			defer out.Close()
			_, err = io.Copy(out, tr)
			return err
		}
	}

	return fmt.Errorf("binary %q not found in archive", targetName)
}

func extractZip(archivePath, destDir, targetName string) error {
	r, err := zip.OpenReader(archivePath)
	if err != nil {
		return err
	}
	defer r.Close()

	for _, f := range r.File {
		if filepath.Base(f.Name) == targetName {
			rc, err := f.Open()
			if err != nil {
				return err
			}
			defer rc.Close()

			outPath := filepath.Join(destDir, targetName)
			out, err := os.OpenFile(outPath, os.O_CREATE|os.O_WRONLY, 0o755)
			if err != nil {
				return err
			}
			defer out.Close()
			_, err = io.Copy(out, rc)
			return err
		}
	}

	return fmt.Errorf("binary %q not found in archive", targetName)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}
