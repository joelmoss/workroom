package workroom

import "os"

// createStagingLock reports errLockUnsupported: Windows can't hand a lock to git the way Unix passes
// an open file, so a clone there is judged by its pid alone.
func createStagingLock(string) (*os.File, error) { return nil, errLockUnsupported }

// probeStagingLock reports lockUnsupported, so the sweep falls back to the pid rule.
func probeStagingLock(string) (*os.File, lockState) { return nil, lockUnsupported }
