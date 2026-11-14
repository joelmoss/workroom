package workroom

import (
	"context"
	"os/exec"
	"time"
)

// machineID is the Mac's IOPlatformUUID, the hardware id ioreg reports, which survives renaming the
// Mac, reinstalling macOS and any network's view of its hostname.
func machineID() (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice").Output()
	if err != nil {
		return "", false
	}
	id := parseIOPlatformUUID(string(out))
	return id, id != ""
}
