package script

import "os"

// loginEnvironment is this process's own on Windows, which has no login shell to ask.
func loginEnvironment(string) ([]string, string) { return os.Environ(), "" }
