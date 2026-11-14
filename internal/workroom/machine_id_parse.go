package workroom

import "strings"

// parseIOPlatformUUID reads the IOPlatformUUID out of `ioreg -rd1 -c IOPlatformExpertDevice`, whose
// line for it is `"IOPlatformUUID" = "<uuid>"`; "" when it is missing or empty.
func parseIOPlatformUUID(output string) string {
	for line := range strings.Lines(output) {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok || strings.TrimSpace(key) != `"IOPlatformUUID"` {
			continue
		}
		return strings.Trim(strings.TrimSpace(value), `"`)
	}
	return ""
}

// parseMachineIDFile reads a systemd or D-Bus machine-id file; "" when it is blank or still holds
// the "uninitialized" placeholder systemd writes before first boot completes, which every such
// machine would share.
func parseMachineIDFile(content string) string {
	id := strings.TrimSpace(content)
	if id == "uninitialized" {
		return ""
	}
	return id
}
