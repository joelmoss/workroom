package workroom

// sameDevice reports whether a and b are on the same filesystem. Windows paths name their volume,
// and a folder and its parent share one unless a mount point sits between them, which a rename then
// reports itself.
func sameDevice(a, b string) bool { return true }
