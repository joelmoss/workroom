package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const DefaultWorkroomsDir = "~/workrooms"

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
		return nil, fmt.Errorf("read config %s: %w", c.path, err)
	}
	var result map[string]any
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, fmt.Errorf("parse config %s: %w", c.path, err)
	}
	return result, nil
}

// Write persists the config data to disk, creating directories as needed.
func (c *Config) Write(data map[string]any) error {
	dir := filepath.Dir(c.path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create config directory %s: %w", dir, err)
	}
	b, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}
	if err := os.WriteFile(c.path, b, 0o644); err != nil {
		return fmt.Errorf("write config %s: %w", c.path, err)
	}
	return nil
}

// AddWorkroom adds a workroom entry under the given parent project path.
func (c *Config) AddWorkroom(parentPath, name, workroomPath, vcs string) error {
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
}

// RemoveWorkroom removes a workroom entry. If the parent has no remaining workrooms, it is removed.
func (c *Config) RemoveWorkroom(parentPath, name string) error {
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
}

// FindCurrentProject finds the project for the given directory. If cwd is a project path in the
// config, returns it directly. Otherwise checks if cwd is a workroom path under any project.
// Returns (projectPath, projectData, found).
func (c *Config) FindCurrentProject(cwd string) (string, map[string]any, bool) {
	data, err := c.Read()
	if err != nil {
		return cwd, nil, false
	}

	if project, ok := data[cwd].(map[string]any); ok {
		return cwd, project, true
	}

	for projectPath, v := range data {
		project, ok := v.(map[string]any)
		if !ok {
			continue
		}
		workrooms, ok := project["workrooms"].(map[string]any)
		if !ok {
			continue
		}
		for _, info := range workrooms {
			infoMap, ok := info.(map[string]any)
			if !ok {
				continue
			}
			if infoMap["path"] == cwd {
				return projectPath, project, true
			}
		}
	}

	return cwd, nil, false
}

// ProjectsWithWorkrooms returns all projects that have at least one workroom.
func (c *Config) ProjectsWithWorkrooms() (map[string]map[string]any, error) {
	data, err := c.Read()
	if err != nil {
		return nil, err
	}

	result := map[string]map[string]any{}
	for path, v := range data {
		project, ok := v.(map[string]any)
		if !ok {
			continue
		}
		workrooms, ok := project["workrooms"].(map[string]any)
		if !ok || len(workrooms) == 0 {
			continue
		}
		result[path] = project
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
	data, err := c.Read()
	if err != nil {
		return err
	}
	data["workrooms_dir"] = path
	return c.Write(data)
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
