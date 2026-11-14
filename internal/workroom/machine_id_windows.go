package workroom

import "golang.org/x/sys/windows/registry"

// machineID is the MachineGuid Windows makes at install, read from the 64-bit registry view so a
// 32-bit build sees the same value.
func machineID() (string, bool) {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Cryptography`, registry.QUERY_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return "", false
	}
	defer func() { _ = key.Close() }()
	id, _, err := key.GetStringValue("MachineGuid")
	if err != nil || id == "" {
		return "", false
	}
	return id, true
}
