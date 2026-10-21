package workroom

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/joelmoss/workroom/internal/vcs"
)

// Start is where a create starts when the main checkout has work its remote's copy of the base
// branch lacks (vcs.LocalWork).
type Start string

const (
	// StartOrigin starts from the remote's copy, leaving the local work out.
	StartOrigin Start = "origin"
	// StartLocal starts from the local branch, with its unpushed commits.
	StartLocal Start = "local"
	// StartLocalWithChanges starts from the local branch and copies the main checkout's
	// uncommitted changes into the new workroom, leaving them in the main checkout too.
	StartLocalWithChanges Start = "local-with-changes"
	// StartAsk refuses with a LocalWorkError when there is local work, so the caller can ask and
	// create again with its answer: the app's choice.
	StartAsk Start = "ask"
)

// Starts are the values --start takes.
var Starts = []Start{StartOrigin, StartLocal, StartLocalWithChanges, StartAsk}

// LocalWorkError refuses a create that would leave local work out, before anything exists, so the
// caller can choose where it starts. It is ErrLocalWork.
type LocalWorkError struct{ Work vcs.LocalWork }

func (e *LocalWorkError) Error() string {
	behind := ""
	if note := e.Work.BehindNote(); note != "" {
		behind = " " + note
	}
	return fmt.Sprintf("%v: %s.%s Choose what to include with --start local-with-changes (your commits "+
		"and changes), local (your commits) or origin (neither)", ErrLocalWork, e.Work.Summary(), behind)
}

func (e *LocalWorkError) Unwrap() error { return ErrLocalWork }

// chooseStart is where a create with work left out starts: Start when it is set, else
// ChooseStartFn's answer. "" leaves the work out, starting from the remote's copy with a warning:
// what a create with nobody to ask does, as it did before there was a choice. Against a stale
// start (the fetch failed) nobody is asked and nothing more is said, but a start chosen beforehand
// still holds: the local branch is what it was.
func (s *Service) chooseStart(work vcs.LocalWork) (Start, error) {
	if work.Branch == "" {
		return StartOrigin, nil
	}
	switch s.Start {
	case StartOrigin, StartLocal, StartLocalWithChanges:
		return s.Start, nil
	case StartAsk:
		if work.Any() && !work.Stale {
			return "", &LocalWorkError{Work: work}
		}
		return StartOrigin, nil
	}
	if work.Any() && !work.Stale && s.ChooseStartFn != nil {
		return s.ChooseStartFn(work)
	}
	return "", nil
}

// leftOutWarning is the warning for a create that started without the local work.
func leftOutWarning(work vcs.LocalWork) string {
	return work.Summary() + ". This workroom doesn't include that work, because new workrooms start " +
		"from what you've pushed."
}

// carryChanges copies the main checkout's uncommitted changes at root into the new workroom at
// wrPath, which started from the same commit: changes to tracked files, staged or not, and the
// untracked files git doesn't ignore. The main checkout keeps them. It never fails the create; a
// problem ends the step as a warning, returned.
func (s *Service) carryChanges(root, wrPath string) string {
	s.step("changes", "running", "")
	warn := func(text string) string {
		s.step("changes", "warning", text)
		return text
	}
	// Applied anywhere else, the changes conflict: the main checkout moved since the choice.
	if from, err := vcs.HeadCommit(root); err != nil {
		return warn(fmt.Sprintf("Couldn't copy your changes: %v", err))
	} else if to, _ := vcs.HeadCommit(wrPath); from != to {
		return warn("Your project moved to a different commit, so your changes weren't copied")
	}
	stash, err := vcs.StashCommit(root)
	if err != nil {
		return warn(fmt.Sprintf("Couldn't copy your changes: %v", err))
	}
	if stash != "" {
		if err := vcs.ApplyStash(wrPath, stash); err != nil {
			return warn(fmt.Sprintf("Couldn't copy your changes: %v", err))
		}
		s.logLine("Copied your changes to existing files")
	}
	untracked, err := vcs.Untracked(root)
	if err != nil {
		return warn(fmt.Sprintf("Couldn't copy your new files: %v", err))
	}
	// Regular files only, as the include step copies: a symlink could point outside the root. Git
	// lists a folder that is a repository of its own as one entry, which isn't copied; it is said,
	// so the step doesn't end done over files the workroom lacks.
	var files, repos []string
	for _, f := range untracked {
		info, err := os.Lstat(filepath.Join(root, filepath.FromSlash(f)))
		switch {
		case err != nil:
		case info.Mode().IsRegular():
			files = append(files, f)
		case info.Mode()&fs.ModeSymlink != 0:
			s.logLine(SkippedSymlink(f))
		case info.IsDir():
			repos = append(repos, f)
			s.logLine(fmt.Sprintf("Skipped %s: it's a separate git repository", f))
		}
	}
	res := CopyIncluded(root, wrPath, files)
	for _, f := range res.Copied {
		s.logLine("Copied " + f)
	}
	if len(res.Failures) > 0 {
		return warn(fmt.Sprintf("Couldn't copy %s: %s", countFiles(len(res.Failures)), strings.Join(res.Failures, "; ")))
	}
	if len(repos) > 0 {
		return warn(fmt.Sprintf("Didn't copy %s: each is a separate git repository", strings.Join(repos, ", ")))
	}
	s.step("changes", "done", "")
	return ""
}

func (s *Service) logLine(line string) {
	if s.ScriptLogWriter != nil {
		fmt.Fprintln(s.ScriptLogWriter, line)
	}
}
