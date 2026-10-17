package vcs

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"
	"sort"
	"strings"
)

// Included lists the root's untracked files that match the patterns in patternFile (gitignore
// syntax) and that the root's own ignore rules ignore, as root-relative slash paths, sorted (#367).
// git does both matches, so `**/`, negation and directory patterns behave exactly as in a
// .gitignore. The candidates come first and the ignore check second: listing every ignored file
// instead takes seconds in a root with a large ignored tree (about 5 s for 450,000 files).
func Included(root, patternFile string) ([]string, error) {
	out, err := gitOutput(root, nil, "ls-files", "-z", "--others", "--ignored", "--exclude-from="+patternFile)
	if err != nil {
		return nil, err
	}
	candidates := splitNUL(out)
	if len(candidates) == 0 {
		return nil, nil
	}
	out, err = gitOutput(root, []byte(strings.Join(candidates, "\x00")+"\x00"), "check-ignore", "-z", "--stdin")
	// check-ignore exits 1 when it ignores none of them.
	if exit := (*exec.ExitError)(nil); errors.As(err, &exit) && exit.ExitCode() == 1 {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	included := splitNUL(out)
	sort.Strings(included)
	return included, nil
}

// gitOutput runs git in dir with stdin, and returns its stdout alone; stderr goes into the error.
func gitOutput(dir string, stdin []byte, args ...string) ([]byte, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = childEnvironment(dir)
	cmd.Stdin = bytes.NewReader(stdin)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("git %s: %w: %s", args[0], err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

func splitNUL(b []byte) []string {
	var out []string
	for s := range strings.SplitSeq(string(b), "\x00") {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}
