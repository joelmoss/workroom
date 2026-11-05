package workroom

import (
	"iter"
	"sort"
)

// Listing is what the human `workroom list` shows from a directory.
type Listing struct {
	// InWorkroom is true when the directory is inside a workroom; ParentPath is its project.
	InWorkroom bool
	ParentPath string
	// AtProject is true when the directory is a registered project's root. Projects then yields
	// that project alone, or nothing when it has no workrooms.
	AtProject bool
	// Count is how many projects Projects yields.
	Count int
	// Projects yields the projects to show, sorted by path: each one's path, and a function that
	// runs its checks and returns it with its warnings at WarningsFull. Away from any project it
	// is every project that has workrooms. A caller shows each path before its checks run, and
	// each project before the next one's, so one that stalls (a hung network volume) is named
	// and holds back nothing before it.
	Projects iter.Seq2[string, func() ProjectInfo]
}

// Listing returns what the human list shows from cwd. Unlike ListData it depends on cwd, and away
// from a project it holds only projects with workrooms.
func (s *Service) Listing(cwd string) (Listing, error) {
	projectPath, project, found := s.Config.FindCurrentProject(cwd)

	// Inside a workroom
	if found && projectPath != cwd {
		return Listing{InWorkroom: true, ParentPath: projectPath}, nil
	}

	// Inside a parent project. Its warnings are computed only when it has workrooms: projectInfo
	// may heal the stored VCS type, which an empty project's listing never did.
	if found && project != nil {
		if len(project.Workrooms) == 0 {
			return Listing{AtProject: true, Projects: func(func(string, func() ProjectInfo) bool) {}}, nil
		}
		return Listing{AtProject: true, Count: 1, Projects: func(yield func(string, func() ProjectInfo) bool) {
			yield(projectPath, func() ProjectInfo { return s.projectInfo(projectPath, *project, WarningsFull) })
		}}, nil
	}

	// Neither — list all
	projects, err := s.Config.ProjectsWithWorkrooms()
	if err != nil {
		return Listing{}, err
	}

	paths := make([]string, 0, len(projects))
	for path := range projects {
		paths = append(paths, path)
	}
	sort.Strings(paths)

	return Listing{Count: len(paths), Projects: func(yield func(string, func() ProjectInfo) bool) {
		for _, path := range paths {
			if !yield(path, func() ProjectInfo { return s.projectInfo(path, projects[path], WarningsFull) }) {
				return
			}
		}
	}}, nil
}
