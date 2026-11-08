# Contributing to Workroom

Issues and PRs are welcome at <https://github.com/joelmoss/workroom>. This document covers the
local development setup and the test/lint gates. The architecture is in
[`docs/contributing/architecture.md`](docs/contributing/architecture.md), the release process in
[`docs/contributing/releasing.md`](docs/contributing/releasing.md), and who owns each area in
[`docs/contributing/ownership.md`](docs/contributing/ownership.md). For what Workroom *is* and how to
use it, see the [user docs](https://codaset.dev/workroom/docs), written in [`docs-site/`](docs-site/).

Before opening a PR:

- Run the linters on everything you touched: `make cli-lint` (Go), `make app-lint` (Swift),
  `make vcs-lint` (Rust) and `make actions-lint` (GitHub workflows).
- Run the relevant tests: `make cli-test` and/or `make app-test`.
- Keep the `--json` contract stable — it's the boundary between the CLI and the app. Breaking changes
  bump `schema_version` (`cmd/json.go`). See
  [the contract](docs-site/pages/reference/json-output.md).
- Workroom supports Git repos only, so contribute through Git.
- Report security vulnerabilities privately, as [`SECURITY.md`](SECURITY.md) describes. Do not file
  them as public issues or PRs.

See [`AGENTS.md`](AGENTS.md) and [`macapp/AGENTS.md`](macapp/AGENTS.md) for the conventions the
maintainer follows.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Tech Stack](#tech-stack)
- [Architecture Overview](#architecture-overview)
- [Local Development](#local-development)
  - [Working on the macOS app](#working-on-the-macos-app)
  - [Working on the Go CLI (engine)](#working-on-the-go-cli-engine)
  - [Available commands (`make`)](#available-commands-make)
- [Testing](#testing)
- [Deployment & Releases](#deployment--releases)
- [Troubleshooting a build](#troubleshooting-a-build)

---

## Prerequisites

**To develop the app** (the primary product):

- **Xcode 27.1**, the version CI, Nightly and Release build with.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`) — the `.xcodeproj`
  is generated from `macapp/project.yml`, not checked in.
- **Rust** (rustup `stable`) — the app build compiles the embedded `workroomd` from the `vcs/` workspace
  (`macapp/Scripts/build-daemon.sh`).
- **Zig 0.17.0** (installed through mise when it is available) — `xcodegen generate` builds the pinned
  Ghostty on its first run, which also needs Xcode's Metal toolchain (the build downloads it, about
  840 MB, if it is missing).
- **Go 1.27+** (the module targets `go 1.27.3`, which CI builds with) — the app
  embeds the CLI engine at build time, so a Go toolchain must be on `PATH`.

**To develop the CLI engine only:** Go 1.27+, and **`golangci-lint` v2.x** for `make cli-lint`
(`go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0` — note the `/v2` in the
module path). Install it with `go install`, not a prebuilt binary: a golangci-lint built against an
older Go cannot read the current toolchain's export data. v1 is not an option here — its vendored
`go/types` caps out at export-data version 2, so it cannot analyze a Go 1.27 stdlib, and it rejects
the v2-format `.golangci.yml`.

**To change the Rust workspace (`vcs/`):** Rust **1.96.1** with rustfmt and clippy for `make vcs-lint`
(`rustup toolchain install 1.96.1 --component rustfmt,clippy`), the version CI's lint jobs pin. Its
`terminal-state` half also needs Zig 0.17.0 (installed through mise when it is available) and builds a
pinned Ghostty on its first run. The workspace lint table in `vcs/Cargo.toml` is a floor of lints the
code already passes; never silence one with an `allow` without asking first.

Use `make vcs-lint-linux` before landing Linux-specific Rust changes from a Mac: native lint
does not compile `cfg(target_os = "linux")` code. It runs the same Makefile gate in a Linux
image with pinned Rust and checksum-verified Zig, using the host's architecture. The first run
downloads the image, crates and Ghostty; later runs reuse caches under
`${XDG_CACHE_HOME:-~/.cache}/workroom/linux-lint/<architecture>`, except Zig's own caches: they
live inside the container, because a macOS bind mount's file locks don't hold, so a Ghostty pin
change rebuilds them from cold. The checkout is mounted read-only,
and Linux Cargo output and credentials are separate from the Mac's. A working `container`, Docker
or Podman runtime is required; the compiler container gets 4 GB of memory. The command fails rather
than reporting a skipped check as a pass.
On Linux it runs the canonical gate natively, with its normal Rust/Zig prerequisites.

**To change a GitHub workflow:** **`jactionlint` 2.5.0** for `make actions-lint`
(`go install github.com/jdx/jactionlint/v2/cmd/jactionlint@v2.5.0`, or
`mise use -g github:jdx/jactionlint@2.5.0`), with `shellcheck` on `PATH` so `run:` blocks are
checked too. It runs every actionlint check plus security rules: pinned action SHAs, job-level
`permissions`, `timeout-minutes` on every job, no restored caches in publishing jobs. CI's
`workflows` job (`ci-actions.yml`) runs the same version, checked by the release archive's sha256: bump the version
and the hash there together. That job
installs `shellcheck` 0.11.0 the same way (`SHELLCHECK_VERSION` and `SHELLCHECK_SHA256`), because the
runner's own is older, and also lints `macapp/Scripts/*.sh` through `make app-scripts-lint`.

Runtime requirements for *using* Workroom are in the docs'
[Install page](docs-site/pages/get-started/install.md).

---

## Tech Stack

The macOS app is the product; the Go CLI is the bundled engine (and an optional standalone addon).

| Component | Technology |
| --- | --- |
| **App language** | Swift 6 + SwiftUI (macOS 15 Sequoia+, Apple silicon only) |
| **Terminal engine** | [libghostty](https://ghostty.org) (stock upstream built from source, Metal-rendered) |
| **VCS reading core** | git via [SwiftGitX](https://github.com/ibrahimcetin/SwiftGitX) (libgit2); daemon-routed reads and writes via the Rust `workroomd` |
| **Syntax highlighting** | [tree-sitter](https://github.com/tree-sitter/tree-sitter) C runtime + grammars |
| **App auto-update** | [Sparkle](https://sparkle-project.org) 2.6 (EdDSA-signed appcast) |
| **App crash reporting** | [Sentry](https://sentry.io) (optional, dSYM upload at release) |
| **App build tooling** | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` → `.xcodeproj`) |
| **VCS backend** | Git worktrees |
| **Config store** | JSON at `~/.config/workroom/config.json` |
| **CLI engine language** | Go 1.27+ (built and tested on Go 1.27.3) |
| **CLI framework** | [Cobra](https://github.com/spf13/cobra) for commands |
| **CLI prompts / output** | [charmbracelet/huh](https://github.com/charmbracelet/huh) · [fatih/color](https://github.com/fatih/color) |
| **CLI release tooling** | [GoReleaser](https://goreleaser.com) v2 |
| **CI/CD** | GitHub Actions (CI on push/PR, release on `v*` tags) |

---

## Architecture Overview

How the app and the Go CLI engine fit together, the repository layout, the create and delete
lifecycles, the VCS abstraction and the config file are in
[`docs/contributing/architecture.md`](docs/contributing/architecture.md).

---

## Local Development

Dev tasks run through the **repo-root `Makefile`**, namespaced `app-*` (macOS app) and `cli-*` (Go
engine), plus `vcs-lint` for the Rust workspace. Run `make` with no target to list everything.

### Working on the macOS app

The app is built with [XcodeGen](https://github.com/yonaskolb/XcodeGen): the `.xcodeproj` is
generated from `macapp/project.yml` and **gitignored**, so you regenerate it rather than editing it.

```bash
# Fastest loop: generate (if needed) → build (Debug) → relaunch the dev app
make app-run

# Build / test / lint / format
make app-build
make app-test           # WorkroomAppTests (unit, headless)
make app-package-test   # macapp/Packages tests (swift test, no app host)
make app-uitest         # WorkroomAppUITests (XCUITest — needs a real GUI login session)
make app-lint           # swift-format --strict
make app-format         # swift-format, rewrite in place
make app-generate       # force-regenerate the .xcodeproj from project.yml

# Open in Xcode instead
cd macapp && xcodegen generate && open WorkroomApp.xcodeproj   # then ⌘R
```

The Debug product is **"Workroom Dev"** — a distinct bundle id (`…workroom.dev`) and name, with an
amber icon — so it runs alongside the installed release "Workroom" without conflict. It keeps its
own config at `~/Library/Application Support/Workroom/<bundle id>/config.json` (the app sets
`$WORKROOM_CONFIG` for the CLI), so its remote workrooms never show in your installed app. It also
skips the global `⌘§` hotkey and Sparkle scheduled checks so it doesn't interfere with your real
install.

> **Adding/removing Swift files** requires regenerating the project (`make app-generate`), since the
> file list lives in the generated `.xcodeproj`.

The Xcode build runs `macapp/Scripts/build-helper.sh` as a phase, which compiles the Go CLI and
embeds it in the app bundle — so a Go toolchain must be on `PATH` when building the app. The app
targets also build the embedded `workroomd` (`macapp/Scripts/build-daemon.sh`), which needs a Rust
toolchain on `PATH`. See
[`macapp/README.md`](macapp/README.md) for setup and signing, the
[app instructions](macapp/AGENTS.md) for working rules and reference navigation, and
[VCS and sessions](docs/macapp/vcs-and-sessions.md) for their architecture.
The [runtime reference](docs/macapp/runtime.md) links the libghostty integration and pin procedure.

### Working on the Go CLI (engine)

```bash
# Build the binary (version injected from git tags via ldflags)
make cli-build              # → bin/workroom

# Run the full test suite
make cli-test               # go test ./...
go test ./internal/workroom/ -v   # one package, verbose

# Lint (golangci-lint v2.x — see Prerequisites)
make cli-lint

# Install into $GOBIN
make cli-install

# Remove the built binary
make cli-clean
```

Raw Go also works: `go build -o bin/workroom .`, `go test ./...`. The version string defaults to `dev`
when built without ldflags (which disables `workroom update`).

**Where to make changes:**

- A new subcommand → add a file under `cmd/` and register it in its `init()`.
- New orchestration logic → `internal/workroom/`.
- A new VCS operation → extend the `vcs.VCS` interface and `git.go`.
- A new config field → `internal/config/config.go`.
- A new error class → add a sentinel in `internal/errs/errs.go` and map it in `Code`/`ExitCode`.

Because all shell-outs go through `vcs.CommandExecutor`, orchestration is testable with a mock
executor and a temp config — no real repo required.

### Available commands (`make`)

| Target | What it does |
| --- | --- |
| `make` | List all targets |
| `app-run` | Build (Debug) and relaunch the dev app |
| `app-run-exedev-fresh` | Build (Debug) and launch the dev app as a user exe.dev has never seen, to try the exe.dev setup (`rm -rf ~/.workroom-exedev-fresh` to start over) |
| `app-run-boxd-fresh` | Build (Debug) and launch the dev app as a user boxd has never seen, to try the boxd setup (install, sign in, GitHub) without signing your own boxd out (`rm -rf ~/.workroom-boxd-fresh` to start over) |
| `app-build` | Build the app (Debug) |
| `app-test` | Run `WorkroomAppTests` (unit) |
| `app-package-test` | Run each `macapp/Packages` package's tests with `swift test` (no app host) |
| `app-uitest` | Run `WorkroomAppUITests` (XCUITest; needs a GUI session) |
| `app-generate` | Regenerate the `.xcodeproj` from `project.yml` |
| `app-format` / `app-lint` | Format / lint Swift via swift-format |
| `app-test-preflight` | Fast Makefile/workflow invariants and headless benchmark failure checks; run after changing test infrastructure |
| `app-test-scripts` | Run the preflight, then packaging and helper script tests |
| `app-scripts-lint` | shellcheck over `macapp/Scripts/*.sh` (needs `shellcheck` on `PATH`) |
| `app-release` | Build → sign → notarize → staple → DMG (full release) |
| `app-icon` | Regenerate the AppIcon PNGs |
| `app-clean` | Remove `DerivedData` + the `.xcodeproj` |
| `cli-build` | Build `bin/workroom` with version injected |
| `cli-test` | `go test ./...` |
| `cli-install` | `go install` into `$GOBIN` |
| `cli-lint` | `golangci-lint run` |
| `cli-clean` | Remove the built binary |
| `vcs-lint` | rustfmt, clippy and `cargo doc -D warnings` over `vcs/`, with and without `terminal-state`, on CI's Rust 1.96.1 |
| `vcs-lint-linux` | The same pinned lint gate on Linux, including Linux-only code; uses a working container, Docker or Podman runtime on macOS |

---

## Testing

**Go CLI** — standard `go test`. Coverage spans config CRUD, name generation, the VCS Git parsers
(with a mock `CommandExecutor`), the script runner (using `testdata/fixtures/{setup,failed_setup,failed_teardown}`),
the updater's version comparison, and the full create/delete/list/`list_data` orchestration plus the
`delete-project` command (unit + integration).

```bash
make cli-test                       # everything
go test ./internal/workroom/ -v     # one package, verbose
go test -run TestCreate ./...       # a single test by name
```

**macOS app** — two suites:

- **`WorkroomAppTests/`** — host-based unit tests (`@testable import Workroom`) covering app logic:
  the AppStore, tab/split math, navigation history, notification routing, diff resolution, run
  commands, multi-window behavior, and the CLI bridge. Run with `make app-test` (headless).
- **`WorkroomAppUITests/`** — XCUITest workflows driven through the accessibility tree (sidebar,
  tabs, menus, diffs). Run with `make app-uitest`. These need a **real GUI login session** (not a
  headless runner), and the Metal-rendered terminal content isn't in the a11y tree, so they exercise
  the app shell rather than terminal output.

> On Xcode 26, the test summary can be hidden; read pass/fail from the `.xcresult` via
> `xcresulttool` if `make app-test` looks quiet.

---

## Deployment & Releases

Continuous integration, cutting a release, patch releases, release channels, the CI secrets,
release artifacts, the macOS app release pipeline and the Sparkle appcast are in
[`docs/contributing/releasing.md`](docs/contributing/releasing.md).

---

## Troubleshooting a build

**App build fails** — most app build failures trace to a stale generated project or a missing tool.
Run `make app-generate` (or `make app-clean` then `make app-build`), confirm `xcodegen` and a Go
toolchain are on `PATH`, and remember adding/removing Swift files requires regenerating the project.

See the docs' [Troubleshooting page](docs-site/pages/help/troubleshooting.md) for runtime issues.
