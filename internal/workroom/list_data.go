package workroom

import (
	"os"
	"sort"

	"github.com/joelmoss/workroom/internal/config"
)

// WarningsLevel controls how much work ListData does to compute per-workroom warnings.
type WarningsLevel string

const (
	// WarningsNone reads config only — zero filesystem or VCS calls (fastest). Each project's
	// stored vcs is reported verbatim (no on-disk reconciliation).
	WarningsNone WarningsLevel = "none"
	// WarningsFast adds an os.Stat per workroom to flag missing directories, and re-detects
	// each project's VCS from disk (a project-level .jj/.git stat) — reporting the real type
	// and healing the stored vcs on drift (e.g. a colocated jj repo whose .jj dir was removed).
	// No per-project VCS command is run at this level.
	WarningsFast WarningsLevel = "fast"
	// WarningsFull additionally verifies VCS workspace membership using the reconciled type,
	// listing once per project (not once per workroom).
	WarningsFull WarningsLevel = "full"
)

// Warning is a structured, machine-readable workroom warning.
type Warning struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
	Path    string `json:"path,omitempty"`
	VCS     string `json:"vcs,omitempty"`
}

// WorkroomInfo describes a single workroom in the JSON contract.
type WorkroomInfo struct {
	Name     string    `json:"name"`
	Path     string    `json:"path"`
	VCSName  string    `json:"vcs_name"`
	Warnings []Warning `json:"warnings"`
}

// ProjectInfo describes a project and its workrooms in the JSON contract.
type ProjectInfo struct {
	Path      string         `json:"path"`
	VCS       string         `json:"vcs"`
	Workrooms []WorkroomInfo `json:"workrooms"`
}

// ListResult is the cwd-independent, deterministic listing of all configured
// projects (including empty ones), suitable for the --json contract.
type ListResult struct {
	Projects     []ProjectInfo `json:"projects"`
	WorkroomsDir string        `json:"workrooms_dir"`
	ConfigPath   string        `json:"config_path"`
}

// ListData returns every configured project (incl. empty), sorted by path with
// workrooms sorted by name, computing warnings at the requested level. Unlike the
// human List, it does not depend on the current working directory.
func (s *Service) ListData(level WarningsLevel) (ListResult, error) {
	projects, err := s.Config.AllProjects()
	if err != nil {
		return ListResult{}, err
	}

	wrDir, _ := s.Config.WorkroomsDir()
	result := ListResult{Projects: []ProjectInfo{}, WorkroomsDir: wrDir, ConfigPath: s.Config.Path()}

	paths := make([]string, 0, len(projects))
	for p := range projects {
		paths = append(paths, p)
	}
	sort.Strings(paths)

	for _, ppath := range paths {
		result.Projects = append(result.Projects, s.projectInfo(ppath, projects[ppath], level))
	}

	return result, nil
}

// projectInfo builds one project's warnings-annotated view. Shared by ListData (--json) and
// List (human) so the two paths compute identical Warning Kind/Message pairs from one place —
// they used to diverge on whether an empty/missing workroom path warns "directory not found"
// (List did unconditionally; ListData silently didn't). That's resolved here in favor of always
// checking: an empty path is exactly as "not found" as a populated one that doesn't exist.
func (s *Service) projectInfo(path string, project config.Project, level WarningsLevel) ProjectInfo {
	vcsType := project.VCS
	// Reconcile the stored vcs against on-disk reality (and heal config on drift) so a project
	// converted between VCSes is reported correctly. Skipped for WarningsNone, which is
	// contractually zero-filesystem.
	if level != WarningsNone {
		vcsType = s.effectiveVCS(path, vcsType, true)
	}
	checksDir := level == WarningsFast || level == WarningsFull
	checksVCS := level == WarningsFull

	names := make([]string, 0, len(project.Workrooms))
	for n := range project.Workrooms {
		names = append(names, n)
	}
	sort.Strings(names)

	// List the project's VCS workspaces exactly once. A nil set means the listing was
	// unavailable (fail-open — no warnings); a non-nil set is authoritative.
	var vcsSet map[string]bool
	if checksVCS {
		vcsSet = s.vcsWorkspaceSet(path, vcsType)
	}

	pinfo := ProjectInfo{Path: path, VCS: vcsType, Workrooms: []WorkroomInfo{}}
	for _, name := range names {
		wrPath := project.Workrooms[name].Path
		wi := WorkroomInfo{Name: name, Path: wrPath, VCSName: "workroom/" + name, Warnings: []Warning{}}

		if checksDir {
			if _, err := os.Stat(wrPath); os.IsNotExist(err) {
				wi.Warnings = append(wi.Warnings, Warning{Kind: "DirectoryMissing", Message: "directory not found", Path: wrPath})
			}
		}
		if checksVCS && vcsSet != nil && !vcsSet[name] {
			wi.Warnings = append(wi.Warnings, Warning{Kind: "VCSWorkroomMissing", Message: vcsType + " workspace not found", VCS: vcsType})
		}
		pinfo.Workrooms = append(pinfo.Workrooms, wi)
	}
	return pinfo
}
