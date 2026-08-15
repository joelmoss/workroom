package config

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/gofrs/flock"
	"github.com/joelmoss/workroom/internal/errs"
)

const DefaultWorkroomsDir = "~/workrooms"

// DefaultChannel is the release channel used when none is configured.
const DefaultChannel = "stable"

// reservedKeys are top-level config keys that hold scalar settings, not project
// entries. Every project enumerator already skips non-map values, so these are
// naturally excluded from listings; this set is the single source of truth for
// the places that must guard by name (e.g. RemoveProject).
var reservedKeys = map[string]bool{
	"workrooms_dir": true,
	"channel":       true,
}

// isReserved reports whether key is a reserved scalar setting rather than a project path.
func isReserved(key string) bool { return reservedKeys[key] }

// Workroom describes one workroom entry as stored under a project's "workrooms" map.
type Workroom struct {
	Path string
}

// Project describes one top-level project entry in the config. It's a read-side view:
// mutators (AddWorkroom, RemoveWorkroom, ...) keep working directly against the raw
// map[string]any so Read/Write round-trip fidelity for unknown keys is unaffected.
type Project struct {
	VCS       string
	Workrooms map[string]Workroom
}

// decodeProject converts a project's raw stored entry into a typed Project. A missing or
// malformed "workrooms" value decodes as zero workrooms rather than failing, so a hand-edited
// or legacy config entry degrades gracefully instead of panicking.
func decodeProject(raw map[string]any) Project {
	vcs, _ := raw["vcs"].(string)
	project := Project{VCS: vcs, Workrooms: map[string]Workroom{}}
	wrMap, ok := raw["workrooms"].(map[string]any)
	if !ok {
		return project
	}
	for name, v := range wrMap {
		entry, ok := v.(map[string]any)
		if !ok {
			continue
		}
		path, _ := entry["path"].(string)
		project.Workrooms[name] = Workroom{Path: path}
	}
	return project
}

// Config manages the workroom configuration stored at ~/.config/workroom/config.json.
type Config struct {
	path string
}

// New creates a Config. If configPath is empty, uses the default location.
func New(configPath string) (*Config, error) {
	if configPath == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("determine home directory: %w", err)
		}
		configPath = filepath.Join(home, ".config", "workroom", "config.json")
	}
	return &Config{path: configPath}, nil
}

// Path returns the config file path.
func (c *Config) Path() string {
	return c.path
}

// Read returns the config data as a map, or an empty map if the file doesn't exist.
func (c *Config) Read() (map[string]any, error) {
	data, err := os.ReadFile(c.path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]any{}, nil
		}
		return nil, fmt.Errorf("%w %s: %v", errs.ErrConfigRead, c.path, err)
	}
	var result map[string]any
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, fmt.Errorf("%w %s: %v", errs.ErrConfigRead, c.path, err)
	}
	return result, nil
}

// Write persists the config data to disk atomically (temp file + rename) so a
// concurrent reader never observes a truncated or partial file.
func (c *Config) Write(data map[string]any) error {
	dir := filepath.Dir(c.path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("%w: create config directory %s: %v", errs.ErrConfigWrite, dir, err)
	}
	b, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return fmt.Errorf("%w: marshal config: %v", errs.ErrConfigWrite, err)
	}

	tmp, err := os.CreateTemp(dir, ".config-*.json.tmp")
	if err != nil {
		return fmt.Errorf("%w: create temp file: %v", errs.ErrConfigWrite, err)
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }

	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		cleanup()
		return fmt.Errorf("%w %s: %v", errs.ErrConfigWrite, tmpName, err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		cleanup()
		return fmt.Errorf("%w %s: %v", errs.ErrConfigWrite, tmpName, err)
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return fmt.Errorf("%w %s: %v", errs.ErrConfigWrite, tmpName, err)
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		cleanup()
		return fmt.Errorf("%w %s: %v", errs.ErrConfigWrite, tmpName, err)
	}
	if err := os.Rename(tmpName, c.path); err != nil {
		cleanup()
		return fmt.Errorf("%w %s: %v", errs.ErrConfigWrite, c.path, err)
	}
	return nil
}

// withLock runs fn while holding a cross-process OS advisory lock on the config
// (an exclusive sidecar lock file, taken via flock(2) on Unix / LockFileEx on
// Windows through github.com/gofrs/flock). It serialises read-modify-write
// cycles between the standalone CLI and the desktop app's bundled binary. It is
// best-effort: on any lock-acquisition trouble, or on hitting the pathological-
// hang backstop below, it degrades to running fn unlocked rather than failing
// the operation. Unlike a stale-file mtime heuristic, an OS advisory lock is
// released by the kernel the instant the holding process dies or crashes —
// there is no elapsed-time staleness window to reason about or steal from a
// still-live holder, so ordinary contention (even an unusually slow
// read-modify-write) is never mistaken for abandonment.
//
// Rollout note: an OLD CLI binary built before this change still runs the
// previous O_CREATE|O_EXCL + mtime-staleness scheme against the same ".lock"
// path, and the two mechanisms do not recognise each other at all. During a
// mixed-version window (an un-upgraded standalone CLI alongside a freshly
// updated one) this is no worse than the pre-fix status quo for that specific
// pairing, but it isn't fully closed by this change either. Decide, before
// cutting the next tag that ships this, whether withLock should also touch the
// legacy sidecar file for one release cycle so an old binary's staleness
// heuristic at least sees a fresh mtime from a live new-style holder instead of
// misreading it as abandoned.
func (c *Config) withLock(fn func() error) error {
	lockPath := c.path + ".lock"
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o755); err != nil {
		return fn()
	}
	fl := flock.New(lockPath)
	// 30s is a backstop against a genuinely pathological hang (e.g. a suspended
	// or wedged holder), not a throttle on ordinary contention: a config
	// read-modify-write is microseconds to low milliseconds of work, so any real
	// holder releases long before this fires. Sized to match JJSnapshotGate's own
	// "well above any routine case" self-heal ceiling elsewhere in this codebase.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	locked, err := fl.TryLockContext(ctx, 10*time.Millisecond)
	if err != nil || !locked {
		// Lock-acquisition trouble, or the pathological-hang backstop fired:
		// proceed unlocked rather than fail the operation or block forever.
		return fn()
	}
	defer func() { _ = fl.Unlock() }()
	return fn()
}

// CanonicalPath resolves a path to an absolute, symlink-evaluated form so that
// the same project referenced via a symlink or trailing slash maps to one key.
// A leading ~ (or ~/) is expanded to the user's home directory first — a shell
// does this before a program sees the path, but a path typed into the app's New
// Project dialog reaches the CLI raw. If the path does not exist (EvalSymlinks
// fails), the absolute form is returned.
func CanonicalPath(p string) (string, error) {
	expanded, err := expandTilde(p)
	if err != nil {
		return "", err
	}
	abs, err := filepath.Abs(expanded)
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		return resolved, nil
	}
	return abs, nil
}

// expandTilde expands a leading "~" or "~/" to the user's home directory. Other
// forms (e.g. "~user") are left untouched — only the current user's home is
// resolved.
func expandTilde(p string) (string, error) {
	if p != "~" && !strings.HasPrefix(p, "~/") {
		return p, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if p == "~" {
		return home, nil
	}
	return filepath.Join(home, p[2:]), nil
}

// AddWorkroom adds a workroom entry under the given parent project path.
func (c *Config) AddWorkroom(parentPath, name, workroomPath, vcs string) error {
	return c.withLock(func() error {
		data, err := c.Read()
		if err != nil {
			return err
		}

		project, ok := data[parentPath].(map[string]any)
		if !ok {
			project = map[string]any{"vcs": vcs, "workrooms": map[string]any{}}
			data[parentPath] = project
		}
		project["vcs"] = vcs

		workrooms, ok := project["workrooms"].(map[string]any)
		if !ok {
			workrooms = map[string]any{}
			project["workrooms"] = workrooms
		}
		workrooms[name] = map[string]any{"path": workroomPath}

		return c.Write(data)
	})
}

// AddProject registers a project with no workrooms (idempotent). An existing
// project's workrooms are never clobbered; only its vcs is refreshed.
func (c *Config) AddProject(parentPath, vcs string) error {
	return c.withLock(func() error {
		data, err := c.Read()
		if err != nil {
			return err
		}
		if project, ok := data[parentPath].(map[string]any); ok {
			project["vcs"] = vcs
			if _, ok := project["workrooms"].(map[string]any); !ok {
				project["workrooms"] = map[string]any{}
			}
		} else {
			data[parentPath] = map[string]any{"vcs": vcs, "workrooms": map[string]any{}}
		}
		return c.Write(data)
	})
}

// SetProjectVCS updates the stored vcs type for an already-registered project. It is a
// no-op (returning nil) if the project isn't in the config — it never creates a project,
// and it preserves the project's workrooms map. Used to reconcile the persisted type when
// a project's on-disk VCS has changed (e.g. a colocated jj repo whose .jj dir was removed,
// leaving plain git); see Service.effectiveVCS.
func (c *Config) SetProjectVCS(parentPath, vcs string) error {
	return c.withLock(func() error {
		data, err := c.Read()
		if err != nil {
			return err
		}
		project, ok := data[parentPath].(map[string]any)
		if !ok {
			return nil
		}
		project["vcs"] = vcs
		return c.Write(data)
	})
}

// RemoveWorkroom removes a workroom entry. If the parent has no remaining workrooms, it is removed.
func (c *Config) RemoveWorkroom(parentPath, name string) error {
	return c.withLock(func() error {
		data, err := c.Read()
		if err != nil {
			return err
		}

		project, ok := data[parentPath].(map[string]any)
		if !ok {
			return nil
		}

		workrooms, ok := project["workrooms"].(map[string]any)
		if !ok {
			return nil
		}

		delete(workrooms, name)

		if len(workrooms) == 0 {
			delete(data, parentPath)
		}

		return c.Write(data)
	})
}

// RemoveWorkroomKeepProject removes a workroom entry but leaves the parent project
// registered even when it has no remaining workrooms. Used by GUI callers that pin
// empty projects in the sidebar.
func (c *Config) RemoveWorkroomKeepProject(parentPath, name string) error {
	return c.withLock(func() error {
		data, err := c.Read()
		if err != nil {
			return err
		}

		project, ok := data[parentPath].(map[string]any)
		if !ok {
			return nil
		}

		workrooms, ok := project["workrooms"].(map[string]any)
		if !ok {
			return nil
		}

		delete(workrooms, name)

		return c.Write(data)
	})
}

// RemoveProject removes a project entry (and its nested workrooms map) from the
// config. It does NOT touch the filesystem or VCS — any worktree/workspace teardown
// is the caller's job (via Service.Delete). Idempotent: an absent project is a no-op
// returning nil. Reserved scalar keys (e.g. "workrooms_dir", "channel") are never
// deletable through here.
func (c *Config) RemoveProject(parentPath string) error {
	return c.withLock(func() error {
		data, err := c.Read()
		if err != nil {
			return err
		}
		if isReserved(parentPath) {
			return nil // reserved key, not a project
		}
		delete(data, parentPath)
		return c.Write(data)
	})
}

// WorkroomNames returns the names of every workroom registered under the given
// project path, sorted for deterministic ordering. An unknown project or one with
// no workrooms yields an empty slice (never nil-panics). The reserved
// "workrooms_dir" key is treated as having no workrooms.
func (c *Config) WorkroomNames(parentPath string) ([]string, error) {
	data, err := c.Read()
	if err != nil {
		return nil, err
	}
	project, ok := data[parentPath].(map[string]any)
	if !ok {
		return []string{}, nil
	}
	workrooms, ok := project["workrooms"].(map[string]any)
	if !ok {
		return []string{}, nil
	}
	names := make([]string, 0, len(workrooms))
	for name := range workrooms {
		names = append(names, name)
	}
	sort.Strings(names)
	return names, nil
}

// FindCurrentProject finds the project for the given directory. If cwd is a project path in the
// config, returns it directly. Otherwise checks if cwd is a workroom path under any project.
// Returns (projectPath, project, found). project is nil when found is false.
func (c *Config) FindCurrentProject(cwd string) (string, *Project, bool) {
	data, err := c.Read()
	if err != nil {
		return cwd, nil, false
	}

	if raw, ok := data[cwd].(map[string]any); ok {
		project := decodeProject(raw)
		return cwd, &project, true
	}

	for projectPath, v := range data {
		raw, ok := v.(map[string]any)
		if !ok {
			continue
		}
		workrooms, ok := raw["workrooms"].(map[string]any)
		if !ok {
			continue
		}
		for _, info := range workrooms {
			infoMap, ok := info.(map[string]any)
			if !ok {
				continue
			}
			if infoMap["path"] == cwd {
				project := decodeProject(raw)
				return projectPath, &project, true
			}
		}
	}

	return cwd, nil, false
}

// ProjectsWithWorkrooms returns all projects that have at least one workroom.
func (c *Config) ProjectsWithWorkrooms() (map[string]Project, error) {
	data, err := c.Read()
	if err != nil {
		return nil, err
	}

	result := map[string]Project{}
	for path, v := range data {
		raw, ok := v.(map[string]any)
		if !ok {
			continue
		}
		workrooms, ok := raw["workrooms"].(map[string]any)
		if !ok || len(workrooms) == 0 {
			continue
		}
		result[path] = decodeProject(raw)
	}
	return result, nil
}

// AllProjects returns every registered project, including those with zero
// workrooms. Non-project top-level keys (e.g. workrooms_dir) are skipped.
func (c *Config) AllProjects() (map[string]Project, error) {
	data, err := c.Read()
	if err != nil {
		return nil, err
	}

	result := map[string]Project{}
	for path, v := range data {
		raw, ok := v.(map[string]any)
		if !ok {
			continue
		}
		result[path] = decodeProject(raw)
	}
	return result, nil
}

// WorkroomsDir returns the configured workrooms directory, or the default ~/workrooms.
func (c *Config) WorkroomsDir() (string, error) {
	data, err := c.Read()
	if err != nil {
		return expandPath(DefaultWorkroomsDir)
	}

	if dir, ok := data["workrooms_dir"].(string); ok && dir != "" {
		return expandPath(dir)
	}
	return expandPath(DefaultWorkroomsDir)
}

// SetWorkroomsDir sets the workrooms_dir key in the config.
func (c *Config) SetWorkroomsDir(path string) error {
	return c.withLock(func() error {
		data, err := c.Read()
		if err != nil {
			return err
		}
		data["workrooms_dir"] = path
		return c.Write(data)
	})
}

// Channel returns the configured release channel, or DefaultChannel ("stable")
// if unset. A read error is treated as unset so a broken config never blocks an
// update check. Validation of the value is the caller's job.
func (c *Config) Channel() string {
	data, err := c.Read()
	if err != nil {
		return DefaultChannel
	}
	if ch, ok := data["channel"].(string); ok && ch != "" {
		return ch
	}
	return DefaultChannel
}

// SetChannel persists the release channel in the config.
func (c *Config) SetChannel(ch string) error {
	return c.withLock(func() error {
		data, err := c.Read()
		if err != nil {
			return err
		}
		data["channel"] = ch
		return c.Write(data)
	})
}

// expandPath replaces a leading ~ with the user's home directory.
func expandPath(path string) (string, error) {
	if strings.HasPrefix(path, "~/") || path == "~" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("determine home directory: %w", err)
		}
		return filepath.Join(home, path[1:]), nil
	}
	return path, nil
}
