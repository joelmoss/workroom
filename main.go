package main

import (
	"os"

	"github.com/joelmoss/workroom/cmd"
)

// version and channel are set via -ldflags at build time. channel is the binary's baked release
// channel identity: empty for the main `workroom` binary (which switches stable/pre at runtime via
// --channel), or "nightly" for the separate side-by-side `workroom-nightly` binary.
var (
	version = "dev"
	channel = ""
)

func main() {
	cmd.SetVersion(version)
	cmd.SetBakedChannel(channel)
	os.Exit(cmd.Execute())
}
