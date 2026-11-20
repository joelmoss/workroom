# The Go CLI and workroomd become one Rust binary, named `workroom`, that is both the CLI and the daemon

Decided 2026-11-19 (owner, after the terminal API design for #360). Status: accepted, not yet built (#667). Supersedes the "Go CLI stays on the Mac" half of [ADR 0030](0030-app-ships-and-pushes-linux-agent.md). It extends [ADR 0013](0013-cli-json-contract.md) and ADR 0057.

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
- **Separate push from hand-off.** A host gets each newer binary as before (ADR 0037), but the running daemon is handed off only when the daemon's own code or protocol changed. A change to CLI commands alone doesn't restart anything, on hosts or on the Mac.
  - The binary reports `daemon-build <hash>` beside `build-number`. The hash is computed at build time over every source file except the CLI `commands` module, plus `Cargo.lock` and the compiler (`rustc -vV`), so a change to shared code or a new rustc counts as a daemon change. Which arguments are the daemon's is decided outside `commands`, so the module never runs for a daemon subcommand.
  - Bootstrap installs when `build-number` is higher, as before, and hands off only when `daemon-build` differs too. A daemon offered a binary compares `daemon-build`, not file hashes. A daemon without the line is always handed off.
- **Old names stay where ADR 0057 put them.** The daemon's socket, lock and log names, the `WRA1` magic, and the pinned command line don't change, so older apps and daemons still find and drive it.
  - The pinned commands are `serve`, `protocol`, `build-number`, `hand-off`, `handoff-check`, `relay`, `attach`, `list`, `run-supervisor` and `run-script`, plus `run-script`'s stderr prefix `workroomd run-script: `.
  - On a host the installed file stays `<daemon dir>/workroomd`, so an older app still sees that the host is newer. A `workroom` symlink beside it is what panes' PATH uses.
  - In the app the one binary is `Contents/Resources/workroom` (today's CLI path; `MacOS/workroom` would clash with `Workroom` on a case-insensitive disk), and the Linux builds are `Contents/Resources/workroom-linux-<arch>`.
  - "Daemon" still names the long-running role (not "server", which already means an SSH host and the dev servers run commands start). The process shows as `workroom serve`.
- **One switch.** The Rust binary replaces the Go one in a single release, once contract tests pass against both. No release ships both, and Go isn't forwarded to Rust command by command. The contract covers the JSON, the NDJSON logs, `kind` codes, exit codes and flag spelling; human-readable text may change wording.
- **`list` keeps both meanings it has today, told apart by `--socket`.** `workroom list` is the workroom list, ADR 0013's contract. `list --socket <path>` is the daemon's pinned session listing, on the Mac and on hosts and hidden from `--help`; bootstrap uses its exit status to tell whether a daemon is running. So the terminal API's session listing is `workroom sessions` (#360).
- **Mac-only commands on a host** stay in `--help`, marked "(Mac only)", and fail with kind `MacOnly` (exit 3). `workroom update` refuses inside an app bundle or a host's daemon directory with kind `ManagedInstall` (exit 3); a standalone install updates itself as before.
- **Config.** Rust reads and writes `config.json` as untyped JSON, as Go does: same sorted keys and indent, exact numbers, the same lock file and atomic rename, so keys either version doesn't know survive.

**Windows.** The CLI's Windows builds are dropped, along with `install.ps1`, because the daemon has no Windows support and the owner chose not to add it. The standalone CLI release (Linux and macOS) moves from goreleaser to the static builds the app already makes. It keeps goreleaser's archive names (`workroom_<ver>_<os>_<arch>.tar.gz`) and `checksums.txt`, so `install.sh` and existing Go CLIs' `workroom update` reach the Rust binary. Nightly's binary is also `workroom`; only its links are named `workroom-nightly`.

**Rejected**
- **Keeping two binaries with shared conventions.** It fixes the contract mismatch, but not the duplicated code, the two toolchains or the second artifact.
- **Rewriting the daemon in Go.** libghostty-vt would need cgo, which loses Go's trivial cross-compiling. And the daemon's pty, hand-off and session code is the riskiest code to rewrite.
- **Swift on Linux,** to match the app. Its Linux runtime is less mature, and it would also mean rewriting the daemon.

Source: #360 (the terminal API spec), #667 (the merge), [`cmd/json.go`](../../cmd/json.go) and [`internal/errs/errs.go`](../../internal/errs/errs.go) (the contract being kept), [`internal/script`](../../internal/script) and [`vcs/crates/workroomd/src/cli/run_script.rs`](../../vcs/crates/workroomd/src/cli/run_script.rs) (the duplicated script runner).
