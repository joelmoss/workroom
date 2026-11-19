# The Go CLI and workroomd become one Rust binary, named `workroom`, that is both the CLI and the daemon

Decided 2026-11-19 (owner, after the terminal API design for #360). Status: accepted, not yet built (#667). Supersedes the "Go CLI stays on the Mac" half of [ADR 0030](0030-app-ships-and-pushes-linux-agent.md). It extends [ADR 0013](0013-cli-json-contract.md) and [ADR 0057](0057-wr-agent-became-workroomd-and-what-keeps-the-old-name.md).

Workroom had two programs:
- **the Go `workroom` CLI:** the engine for workroom lifecycle, Mac only (ADR 0030)
- **the Rust `workroomd`:** the daemon, on the Mac and every host

The terminal API (#360) gives the daemon commands meant for users too. Kept separate, that would mean two user-facing CLIs with two JSON contracts, and code written twice. Setup and teardown scripts already run through the Go CLI locally and through `workroomd run-script` on hosts (ADR 0053), each with its own login-shell probe, process-tree kill and timeout.

So the Go CLI is rewritten in Rust inside the daemon's crate, and the one binary is named `workroom`.

**How it works**
- **Two roles, one binary.** Run as `workroom <command>`, it's the CLI: each command runs and exits, as today. Run as `workroom serve`, it's the daemon. Lifecycle commands run in their own process, never inside the daemon, so a lifecycle bug can't take sessions with it. A command moves into a daemon service only when the app gains something from it.
- **Same command everywhere.** The binary is on the Mac and on every host. A command that needs this Mac's config, `gh` or host drivers says plainly, on a host, that it works only on the Mac.
- **One contract style.** Every command, including the terminal API, keeps ADR 0013's contract:
  - one JSON envelope on stdout with `schema_version`
  - NDJSON logs on stderr
  - stable PascalCase `kind` codes and exit codes
  - `schema_version` bumped only on a breaking change
  - streaming commands (`events`, `capture --all`) print one envelope per line

  The Go CLI's output is reproduced exactly; contract tests run against both implementations before the switch.
- **Separate push from hand-off.** A host gets each newer binary as before (ADR 0037), but the running daemon is handed off only when the daemon's own code or protocol changed. A change to CLI commands alone doesn't restart anything on hosts.
- **Old names stay where ADR 0057 put them.** The daemon's socket, lock and log names, the `WRA1` magic, and the pinned command line (`serve`, `protocol`, `build-number`, `hand-off`, `handoff-check`, `relay`, `attach`) don't change. So older apps and daemons still find and drive it. "Daemon" still names the long-running role. The process shows as `workroom serve`.

**Windows.** The CLI's Windows builds are dropped, along with `install.ps1`, because the daemon has no Windows support and the owner chose not to add it. The standalone CLI release (Linux and macOS) moves from goreleaser to the static builds the app already makes.

**Rejected**
- **Keeping two binaries with shared conventions.** It fixes the contract mismatch, but not the duplicated code, the two toolchains or the second artifact.
- **Rewriting the daemon in Go.** libghostty-vt would need cgo, which loses Go's trivial cross-compiling. And the daemon's pty, hand-off and session code is the riskiest code to rewrite.
- **Swift on Linux,** to match the app. Its Linux runtime is less mature, and it would also mean rewriting the daemon.

Source: #360 (the terminal API spec), #667 (the merge), [`cmd/json.go`](../../cmd/json.go) and [`internal/errs/errs.go`](../../internal/errs/errs.go) (the contract being kept), [`internal/script`](../../internal/script) and [`vcs/crates/workroomd/src/cli/run_script.rs`](../../vcs/crates/workroomd/src/cli/run_script.rs) (the duplicated script runner).
