package script

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/joelmoss/workroom/internal/errs"
)

// Run executes a user script in the given workroom directory with environment variables set.
// Returns the combined stdout+stderr output and any error.
func Run(scriptType string, scriptPath, workroomDir, name, parentDir string) (string, error) {
	if _, err := os.Stat(scriptPath); os.IsNotExist(err) {
		return "", nil
	}

	cmd := exec.Command(scriptPath)
	cmd.Dir = workroomDir
	cmd.Env = append(os.Environ(),
		"WORKROOM_NAME="+name,
		"WORKROOM_PARENT_DIR="+parentDir,
	)

	out, err := cmd.CombinedOutput()
	output := string(out)

	if err != nil {
		var sentinel error
		if scriptType == "setup" {
			sentinel = errs.ErrSetup
		} else {
			sentinel = errs.ErrTeardown
		}
		return output, fmt.Errorf("%w: %s returned a non-zero exit code.\n%s", sentinel, scriptPath, output)
	}

	return output, nil
}
