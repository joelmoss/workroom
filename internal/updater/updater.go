package updater

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

const releasesURL = "https://api.github.com/repos/joelmoss/workroom/releases/latest"

type githubRelease struct {
	TagName string `json:"tag_name"`
}

// CheckLatestVersion fetches the latest release tag from GitHub.
func CheckLatestVersion() (string, error) {
	req, err := http.NewRequest("GET", releasesURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/vnd.github.v3+json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to check for updates: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub API returned status %d", resp.StatusCode)
	}

	var release githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		return "", fmt.Errorf("failed to parse release info: %w", err)
	}

	return release.TagName, nil
}

// IsNewer returns true if latest is a higher semver than current.
// Both may optionally have a "v" prefix.
func IsNewer(current, latest string) bool {
	cur := parseVersion(current)
	lat := parseVersion(latest)
	if cur == nil || lat == nil {
		return false
	}
	for i := range 3 {
		if lat[i] > cur[i] {
			return true
		}
		if lat[i] < cur[i] {
			return false
		}
	}
	return false
}

// parseVersion strips a "v" prefix and splits "major.minor.patch" into ints.
// Returns nil if parsing fails.
func parseVersion(v string) []int {
	v = strings.TrimPrefix(v, "v")
	parts := strings.SplitN(v, ".", 3)
	if len(parts) != 3 {
		return nil
	}
	nums := make([]int, 3)
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil
		}
		nums[i] = n
	}
	return nums
}

// BuildArchiveURL constructs the download URL for the given version/os/arch.
// Version should include the "v" prefix (e.g. "v1.3.0").
func BuildArchiveURL(version, goos, goarch string) string {
	ver := strings.TrimPrefix(version, "v")
	ext := "tar.gz"
	if goos == "windows" {
		ext = "zip"
	}
	return fmt.Sprintf(
		"https://github.com/joelmoss/workroom/releases/download/%s/workroom_%s_%s_%s.%s",
		version, ver, goos, goarch, ext,
	)
}

// Update checks for a newer version and replaces the current binary.
func Update(currentVersion string, verbose, pretend bool, w io.Writer) error {
	if currentVersion == "dev" {
		return fmt.Errorf("cannot update a dev build — install from a release instead")
	}

	fmt.Fprintf(w, "Checking for updates...\n")

	latest, err := CheckLatestVersion()
	if err != nil {
		return err
	}

	if !IsNewer(currentVersion, latest) {
		fmt.Fprintf(w, "Already up-to-date (%s)\n", currentVersion)
		return nil
	}

	fmt.Fprintf(w, "Update available: %s → %s\n", currentVersion, latest)

	if pretend {
		fmt.Fprintf(w, "(pretend) Would download and install %s\n", latest)
		return nil
	}

	archiveURL := BuildArchiveURL(latest, runtime.GOOS, runtime.GOARCH)
	if verbose {
		fmt.Fprintf(w, "Downloading %s\n", archiveURL)
	}

	tmpDir, err := os.MkdirTemp("", "workroom-update-*")
	if err != nil {
		return fmt.Errorf("failed to create temp directory: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	archivePath := filepath.Join(tmpDir, "workroom-archive")
	if err := downloadFile(archiveURL, archivePath); err != nil {
		return fmt.Errorf("failed to download update: %w", err)
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

	currentBin, err := os.Executable()
	if err != nil {
		return fmt.Errorf("failed to find current binary: %w", err)
	}
	currentBin, err = filepath.EvalSymlinks(currentBin)
	if err != nil {
		return fmt.Errorf("failed to resolve binary path: %w", err)
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

	fmt.Fprintf(w, "Updated workroom %s → %s\n", currentVersion, latest)
	return nil
}

// CheckOnly checks for an update and reports status without installing.
func CheckOnly(currentVersion string, w io.Writer) error {
	if currentVersion == "dev" {
		fmt.Fprintf(w, "Running dev build — cannot check for updates\n")
		return nil
	}

	fmt.Fprintf(w, "Checking for updates...\n")

	latest, err := CheckLatestVersion()
	if err != nil {
		return err
	}

	if IsNewer(currentVersion, latest) {
		fmt.Fprintf(w, "Update available: %s → %s\n", currentVersion, latest)
		fmt.Fprintf(w, "Run 'workroom update' to install\n")
	} else {
		fmt.Fprintf(w, "Already up-to-date (%s)\n", currentVersion)
	}

	return nil
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
