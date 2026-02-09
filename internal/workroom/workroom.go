package workroom

import (
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/joelmoss/workroom/internal/config"
	"github.com/joelmoss/workroom/internal/namegen"
	"github.com/joelmoss/workroom/internal/script"
	"github.com/joelmoss/workroom/internal/ui"
	"github.com/joelmoss/workroom/internal/vcs"
)

var validNameRe = regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?$`)

// PromptFunc abstracts interactive prompts for testability.
type PromptFunc func(message string, options []string) ([]string, error)
type ConfirmFunc func(message string) (bool, error)

// Service orchestrates workroom create/delete/list operations.
type Service struct {
	Config      *config.Config
	VCS         vcs.VCS
	Out         io.Writer
	Verbose     bool
	Pretend     bool
	PromptFn    PromptFunc
	ConfirmFn   ConfirmFunc
	NameGenFunc func() string // override for testing
}

func (s *Service) output() io.Writer {
	if s.Out != nil {
		return s.Out
	}
	return os.Stdout
}

func (s *Service) say(msg string) {
	fmt.Fprintln(s.output(), msg)
}

func (s *Service) sayColor(msg, colorName string) {
	w := s.output()
	switch colorName {
	case "green":
		fmt.Fprintln(w, ui.Green(msg))
	case "red":
		fmt.Fprintln(w, ui.Red(msg))
	case "yellow":
		fmt.Fprintln(w, ui.Yellow(msg))
	case "blue":
		fmt.Fprintln(w, ui.Blue(msg))
	default:
		fmt.Fprintln(w, msg)
	}
}

func (s *Service) sayStatus(status, msg string) {
	if s.Verbose {
		fmt.Fprintf(s.output(), "%12s  %s\n", status, msg)
	}
}

// CheckNotInWorkroom checks if the current directory is already a workroom.
func (s *Service) CheckNotInWorkroom(dir string) error {
	if _, err := os.Stat(filepath.Join(dir, ".Workroom")); err == nil {
		return ErrInWorkroom
	}
	return nil
}

// detectVCS detects the VCS in the given directory and sets s.VCS.
func (s *Service) detectVCS(dir string) error {
	if s.VCS != nil {
		return nil
	}
	v, err := vcs.Detect(dir)
	if err != nil {
		return err
	}
	if v == nil {
		return ErrUnsupportedVCS
	}
	s.VCS = v
	s.sayStatus("repo", fmt.Sprintf("Detected %s", s.VCS.Label()))
	return nil
}

func (s *Service) vcsName(name string) string {
	return "workroom/" + name
}

func (s *Service) workroomPath(name string) string {
	return filepath.Join(s.Config.WorkroomsDir(), name)
}

func (s *Service) generateName() string {
	if s.NameGenFunc != nil {
		return s.NameGenFunc()
	}
	return namegen.Generate()
}

// Create generates a unique name and creates a new workroom.
func (s *Service) Create(dir string) error {
	if err := s.CheckNotInWorkroom(dir); err != nil {
		return err
	}
	if err := s.detectVCS(dir); err != nil {
		return err
	}

	name, err := s.generateUniqueName(dir)
	if err != nil {
		return err
	}

	wrPath := s.workroomPath(name)

	if !s.Pretend {
		exists, err := s.VCS.WorkroomExists(dir, name)
		if err != nil {
			return err
		}
		if exists {
			if s.VCS.Type() == vcs.TypeJJ {
				return fmt.Errorf("%w: %s '%s' already exists", ErrJJWorkspaceExists, s.VCS.Label(), name)
			}
			return fmt.Errorf("%w: %s '%s' already exists", ErrGitWorktreeExists, s.VCS.Label(), name)
		}

		if _, err := os.Stat(wrPath); err == nil {
			return fmt.Errorf("%w: workroom directory '%s' already exists", ErrDirExists, ui.DisplayPath(wrPath))
		}
	}

	// Create VCS workspace
	if !s.Pretend {
		if err := os.MkdirAll(s.Config.WorkroomsDir(), 0o755); err != nil {
			return err
		}
		if _, err := s.VCS.Create(dir, s.vcsName(name), wrPath); err != nil {
			return fmt.Errorf("failed to create workspace: %w", err)
		}
	}

	// Update config
	if !s.Pretend {
		if err := s.Config.AddWorkroom(dir, name, wrPath, string(s.VCS.Type())); err != nil {
			return err
		}
	}

	// Run setup script
	var setupOutput string
	setupScript := filepath.Join(dir, "scripts", "workroom_setup")
	if _, err := os.Stat(setupScript); err == nil {
		s.sayStatus("setup", fmt.Sprintf("Running %s from %q", setupScript, wrPath))
		if !s.Pretend {
			setupOutput, err = script.Run("setup", setupScript, wrPath, name, dir)
			if err != nil {
				return err
			}
		}
	}

	s.say("")
	s.sayColor(fmt.Sprintf("Workroom '%s' created successfully at %s.", name, ui.DisplayPath(wrPath)), "green")

	if setupOutput != "" {
		s.sayColor("Setup script output:", "blue")
		s.say(strings.TrimSpace(setupOutput))
	}

	s.say("")
	return nil
}

func (s *Service) generateUniqueName(dir string) (string, error) {
	var lastName string

	for range 5 {
		lastName = s.generateName()
		exists, err := s.workroomExistsFor(dir, lastName)
		if err != nil {
			return "", err
		}
		wrPath := s.workroomPath(lastName)
		if !exists {
			if _, err := os.Stat(wrPath); os.IsNotExist(err) {
				return lastName, nil
			}
		}
	}

	for {
		candidate := fmt.Sprintf("%s-%d", lastName, rand.IntN(90)+10)
		exists, err := s.workroomExistsFor(dir, candidate)
		if err != nil {
			return "", err
		}
		wrPath := s.workroomPath(candidate)
		if !exists {
			if _, err := os.Stat(wrPath); os.IsNotExist(err) {
				return candidate, nil
			}
		}
	}
}

func (s *Service) workroomExistsFor(dir, name string) (bool, error) {
	return s.VCS.WorkroomExists(dir, name)
}

// List shows workrooms for the current project or all projects.
func (s *Service) List(cwd string) error {
	projectPath, project, found := s.Config.FindCurrentProject(cwd)

	// Inside a workroom
	if found && projectPath != cwd {
		s.sayColor("You are already in a workroom.", "yellow")
		s.say(fmt.Sprintf("Parent project is at %s", ui.DisplayPath(projectPath)))
		return nil
	}

	// Inside a parent project
	if found && project != nil {
		workrooms, ok := project["workrooms"].(map[string]any)
		if !ok || len(workrooms) == 0 {
			s.say("No workrooms found for this project.")
			return nil
		}

		vcsType := ""
		if v, ok := project["vcs"].(string); ok {
			vcsType = v
		}
		s.listWorkrooms(workrooms, vcsType, cwd)
		return nil
	}

	// Neither — list all
	projects, err := s.Config.ProjectsWithWorkrooms()
	if err != nil {
		return err
	}

	if len(projects) == 0 {
		s.say("No workrooms found.")
		return nil
	}

	for path, proj := range projects {
		s.say(fmt.Sprintf("%s:", ui.DisplayPath(path)))
		workrooms, _ := proj["workrooms"].(map[string]any)
		vcsType, _ := proj["vcs"].(string)
		s.listWorkrooms(workrooms, vcsType, path)
		s.say("")
	}

	return nil
}

func (s *Service) listWorkrooms(workrooms map[string]any, vcsType, dir string) {
	var rows [][]string
	for name, info := range workrooms {
		infoMap, ok := info.(map[string]any)
		if !ok {
			continue
		}
		wrPath, _ := infoMap["path"].(string)
		warnings := s.workroomWarnings(name, wrPath, vcsType, dir)

		row := []string{ui.Bold(name), ui.Dim(ui.DisplayPath(wrPath))}
		if len(warnings) > 0 {
			row = append(row, ui.Yellow(fmt.Sprintf("[%s]", strings.Join(warnings, ", "))))
		}
		rows = append(rows, row)
	}
	ui.PrintTable(s.output(), rows, 2)
}

func (s *Service) workroomWarnings(name, wrPath, vcsType, dir string) []string {
	var warnings []string
	if _, err := os.Stat(wrPath); os.IsNotExist(err) {
		warnings = append(warnings, "directory not found")
	}

	// Check VCS workspace existence
	if s.VCS != nil {
		vcsName := "workroom/" + name
		if vcsType == "jj" {
			if jj, ok := s.VCS.(*vcs.JJ); ok {
				workspaces, err := jj.ListWorkrooms(dir)
				if err == nil {
					found := false
					for _, w := range workspaces {
						if w == vcsName {
							found = true
							break
						}
					}
					if !found {
						warnings = append(warnings, "jj workspace not found")
					}
				}
			}
		} else if vcsType == "git" {
			if git, ok := s.VCS.(*vcs.Git); ok {
				workrooms, err := git.ListWorkrooms(dir)
				if err == nil {
					found := false
					for _, w := range workrooms {
						if w == name {
							found = true
							break
						}
					}
					if !found {
						warnings = append(warnings, "git workspace not found")
					}
				}
			}
		}
	}

	return warnings
}

// Delete removes a workroom by name.
func (s *Service) Delete(dir, name, confirmValue string) error {
	if err := s.CheckNotInWorkroom(dir); err != nil {
		return err
	}

	if !validNameRe.MatchString(name) {
		return fmt.Errorf("%w: %q", ErrInvalidName, name)
	}

	if err := s.detectVCS(dir); err != nil {
		return err
	}

	if !s.Pretend {
		exists, err := s.VCS.WorkroomExists(dir, name)
		if err != nil {
			return err
		}
		if !exists {
			if s.VCS.Type() == vcs.TypeJJ {
				return fmt.Errorf("%w: %s '%s' does not exist", ErrJJWorkspaceNotFound, s.VCS.Label(), name)
			}
			return fmt.Errorf("%w: %s '%s' does not exist", ErrGitWorktreeNotFound, s.VCS.Label(), name)
		}

		if confirmValue != "" {
			if confirmValue != name {
				return fmt.Errorf("--confirm value '%s' does not match workroom name '%s'", confirmValue, name)
			}
		} else {
			confirmed, err := s.ConfirmFn(fmt.Sprintf("Are you sure you want to delete workroom '%s'?", name))
			if err != nil {
				return err
			}
			if !confirmed {
				s.sayColor(fmt.Sprintf("Aborting. Workroom '%s' was not deleted.", name), "yellow")
				return nil
			}
		}
	}

	return s.deleteByName(dir, name)
}

// InteractiveDelete shows a multi-select prompt for deleting workrooms.
func (s *Service) InteractiveDelete(dir string) error {
	if err := s.CheckNotInWorkroom(dir); err != nil {
		return err
	}

	_, project, found := s.Config.FindCurrentProject(dir)
	if !found || project == nil {
		s.say("No workrooms found for this project.")
		return nil
	}

	workrooms, ok := project["workrooms"].(map[string]any)
	if !ok || len(workrooms) == 0 {
		s.say("No workrooms found for this project.")
		return nil
	}

	names := make([]string, 0, len(workrooms))
	for name := range workrooms {
		names = append(names, name)
	}

	selected, err := s.PromptFn("Select workrooms to delete:", names)
	if err != nil {
		return err
	}

	if len(selected) == 0 {
		s.sayColor("Aborting. No workrooms were selected.", "yellow")
		return nil
	}

	quotedNames := make([]string, len(selected))
	for i, n := range selected {
		quotedNames[i] = fmt.Sprintf("'%s'", n)
	}
	msg := fmt.Sprintf("Are you sure you want to delete %d workroom(s): %s?", len(selected), strings.Join(quotedNames, ", "))

	confirmed, err := s.ConfirmFn(msg)
	if err != nil {
		return err
	}
	if !confirmed {
		s.sayColor("Aborting. No workrooms were deleted.", "yellow")
		return nil
	}

	if err := s.detectVCS(dir); err != nil {
		return err
	}

	for _, name := range selected {
		if err := s.deleteByName(dir, name); err != nil {
			return err
		}
	}

	return nil
}

func (s *Service) deleteByName(dir, name string) error {
	wrPath := s.workroomPath(name)

	// Run teardown script
	teardownScript := filepath.Join(dir, "scripts", "workroom_teardown")
	var teardownOutput string
	if _, err := os.Stat(teardownScript); err == nil {
		s.sayStatus("teardown", fmt.Sprintf("Running %s from %q", teardownScript, wrPath))
		if !s.Pretend {
			var scriptErr error
			teardownOutput, scriptErr = script.Run("teardown", teardownScript, wrPath, name, dir)
			if scriptErr != nil {
				return scriptErr
			}
		}
	}

	// Delete VCS workspace
	if !s.Pretend {
		if _, err := s.VCS.Delete(dir, s.vcsName(name), wrPath); err != nil {
			return fmt.Errorf("failed to delete workspace: %w", err)
		}
	}

	// Cleanup directory for JJ
	if s.VCS.Type() == vcs.TypeJJ {
		if _, err := os.Stat(wrPath); err == nil {
			if !s.Pretend {
				os.RemoveAll(wrPath)
			}
		}
	}

	// Update config
	if !s.Pretend {
		if err := s.Config.RemoveWorkroom(dir, name); err != nil {
			return err
		}
	}

	s.sayColor(fmt.Sprintf("Workroom '%s' deleted successfully.", name), "green")

	if s.VCS.Type() == vcs.TypeGit {
		s.say("")
		s.say(fmt.Sprintf("Note: Git branch '%s' was not deleted.", s.vcsName(name)))
		s.say(fmt.Sprintf("      Delete manually with `git branch -D %s` if needed.", s.vcsName(name)))
	}

	if teardownOutput != "" {
		s.say("")
		s.sayColor("Teardown script output:", "blue")
		s.say(strings.TrimSpace(teardownOutput))
		s.say("")
	}

	return nil
}
