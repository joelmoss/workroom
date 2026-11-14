//go:build !windows

package workroom

import (
	"os"
	"syscall"
)

// sameDevice reports whether a and b are on the same filesystem, so a rename between them works.
// Unknown counts as the same: the rename then reports the problem itself.
func sameDevice(a, b string) bool {
	ai, errA := os.Stat(a)
	bi, errB := os.Stat(b)
	if errA != nil || errB != nil {
		return true
	}
	as, okA := ai.Sys().(*syscall.Stat_t)
	bs, okB := bi.Sys().(*syscall.Stat_t)
	return !okA || !okB || as.Dev == bs.Dev
}
