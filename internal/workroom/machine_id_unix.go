//go:build !windows && !darwin

package workroom

import "os"

// machineID is the machine id systemd keeps in /etc/machine-id, or D-Bus's copy where there is no
// systemd: made once per install and unchanged by renaming the machine.
func machineID() (string, bool) {
	for _, path := range []string{"/etc/machine-id", "/var/lib/dbus/machine-id"} {
		if b, err := os.ReadFile(path); err == nil {
			if id := parseMachineIDFile(string(b)); id != "" {
				return id, true
			}
		}
	}
	return "", false
}
