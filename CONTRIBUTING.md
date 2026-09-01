# Contributing to Workroom

Issues and PRs are welcome at <https://github.com/joelmoss/workroom>. This document covers the
architecture, the local development setup, the test/lint gates, and the release process. For what
Workroom *is* and how to use it, see [`README.md`](README.md).

Before opening a PR:

- Run the linters on everything you touched: `make cli-lint` (Go) and `make app-lint` (Swift).
- Run the relevant tests: `make cli-test` and/or `make app-test`.
- Keep the `--json` contract stable — it's the boundary between the CLI and the app. Breaking changes
  bump `schema_version` (`cmd/json.go`). See
  [the contract](README.md#the---json-machine-contract).
- Note that this repo is a **colocated Git + JJ** repo, so either VCS works for contributing.

See [`CLAUDE.md`](CLAUDE.md) and [`macapp/CLAUDE.md`](macapp/CLAUDE.md) for the conventions the
maintainer follows.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Tech Stack](#tech-stack)
- [Architecture Overview](#architecture-overview)
  - [Repository layout](#repository-layout)
  - [The macOS app architecture](#the-macos-app-architecture)
  - [The Go CLI engine](#the-go-cli-engine)
  - [How a workroom is created (lifecycle)](#how-a-workroom-is-created-lifecycle)
  - [How a workroom is deleted (lifecycle)](#how-a-workroom-is-deleted-lifecycle)
  - [VCS abstraction](#vcs-abstraction)
  - [The config file](#the-config-file)
- [Local Development](#local-development)
  - [Working on the macOS app](#working-on-the-macos-app)
  - [Working on the Go CLI (engine)](#working-on-the-go-cli-engine)
  - [Available commands (`make`)](#available-commands-make)
- [Testing](#testing)
- [Deployment & Releases](#deployment--releases)
  - [Continuous integration](#continuous-integration)
  - [Cutting a release](#cutting-a-release)
  - [Release channels](#release-channels)
  - [Required CI secrets](#required-ci-secrets)
  - [Release artifacts](#release-artifacts)
  - [The macOS app release pipeline](#the-macos-app-release-pipeline)
  - [Auto-update (Sparkle appcast)](#auto-update-sparkle-appcast)
- [Troubleshooting a build](#troubleshooting-a-build)

---

## Prerequisites

**To develop the app** (the primary product):

- **Xcode 16+** with the macOS 15 SDK.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`) — the `.xcodeproj`
  is generated from `macapp/project.yml`, not checked in.
- **`protoc`** (`brew install protobuf`) — a build-time dep of the Rust jj-lib VCS core (`make app-vcs`).
  A universal release build also needs rustup `stable` ≥ 1.93 with the `x86_64`/`aarch64-apple-darwin` targets.
- **Go 1.25+** (the module targets `go 1.25.7`; CI and the maintainer build with Go 1.26) — the app
  embeds the CLI engine at build time, so a Go toolchain must be on `PATH`.
- **`jj`** (`brew install jj`) — needed for the app's VCS integration tests, and if you develop in this
  repo itself (it is a colocated Git+JJ repo).

**To develop the CLI engine only:** Go 1.25+, and **`golangci-lint` v1.x** for `make cli-lint`
(`go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest`).

Runtime requirements for *using* Workroom are in [the README](README.md#requirements).

---

## Tech Stack

The macOS app is the product; the Go CLI is the bundled engine (and an optional standalone addon).

| Component | Technology |
| --- | --- |
| **App language** | Swift 5 + SwiftUI (macOS 15 Sequoia+, Apple Silicon) |
| **Terminal engine** | [libghostty](https://ghostty.org) (`libghostty-spm`, Metal-rendered) |
| **VCS reading core** | jj via Rust [`jj-lib`](https://github.com/jj-vcs/jj) (UniFFI); git via [SwiftGitX](https://github.com/ibrahimcetin/SwiftGitX) (libgit2) |
| **Syntax highlighting** | [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) + tree-sitter grammars |
| **App auto-update** | [Sparkle](https://sparkle-project.org) 2.6 (EdDSA-signed appcast) |
| **App crash reporting** | [Sentry](https://sentry.io) (optional, dSYM upload at release) |
| **App build tooling** | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` → `.xcodeproj`) |
| **VCS backends** | Git worktrees, Jujutsu (JJ) workspaces |
| **Config store** | JSON at `~/.config/workroom/config.json` |
| **CLI engine language** | Go 1.25+ (built/tested on Go 1.26) |
| **CLI framework** | [Cobra](https://github.com/spf13/cobra) for commands |
| **CLI prompts / output** | [charmbracelet/huh](https://github.com/charmbracelet/huh) · [fatih/color](https://github.com/fatih/color) |
| **CLI release tooling** | [GoReleaser](https://goreleaser.com) v2 |
| **CI/CD** | GitHub Actions (CI on push/PR, release on `v*` tags) |

---

## Architecture Overview

The product is the **macOS app** (`macapp/`). For workroom management (create/delete/list) it's a
SwiftUI client over **one shared engine** — the Go CLI, which it bundles and drives over a stable
`--json` contract (no cgo, no duplicated lifecycle logic). The same engine is usable standalone as
the CLI addon. VCS **reading** (history, diffs, working-copy status) is done natively in the app
through a structured core — jj via Rust `jj-lib` (UniFFI), git via SwiftGitX (libgit2) — not by
scraping CLI output.

```
┌──────────────────────────────┐        ┌──────────────────────────────┐
│  macOS app (Swift / SwiftUI)  │        │   You, in a terminal          │
│  macapp/                      │        │                               │
└───────────────┬──────────────┘        └───────────────┬──────────────┘
                │  spawns bundled binary                 │  runs installed binary
                │  `workroom … --json`                   │  `workroom …`
                ▼                                         ▼
        ┌────────────────────────────────────────────────────────┐
        │                  The workroom Go engine                 │
        │  cmd/  (Cobra commands)                                 │
        │  internal/workroom/  (create / delete / list orchestr.) │
        │  internal/vcs/  ──►  Git worktrees  |  JJ workspaces     │
        │  internal/config/  ──►  ~/.config/workroom/config.json   │
        │  internal/script/  ──►  setup / teardown hooks           │
        └────────────────────────────────────────────────────────┘
```

### Repository layout

```
workroom/
├── main.go                  # Entry point; injects version via ldflags, calls cmd.Execute()
├── cmd/                     # Cobra command definitions
│   ├── root.go              # Root command, global flags, Service construction
│   ├── create.go            # `workroom create` (alias c)
│   ├── list.go              # `workroom list` (aliases ls, l)
│   ├── delete.go            # `workroom delete` (alias d)
│   ├── update.go            # `workroom update` (alias u) — CLI self-update
│   ├── version.go           # `workroom version`
│   ├── add_project.go       # Hidden; --json only; used by the app to register a project
│   ├── delete_project.go    # Hidden; --json only; used by the app to drop a project
│   ├── json.go              # --json success/error envelope writers
│   ├── jsonlog.go           # NDJSON streaming of setup/teardown output (stderr)
│   └── helpers.go           # cwd / --project resolution
├── internal/
│   ├── config/              # JSON config CRUD (atomic writes + advisory lock)
│   ├── namegen/             # Adjective-noun name generation (120 × 210)
│   ├── vcs/                 # VCS interface + Git/JJ impls + CommandExecutor (testable)
│   ├── workroom/            # Core orchestration: Service.{Create,Delete,List,ListData}
│   ├── script/              # Setup/teardown script runner (env vars + live streaming)
│   ├── ui/                  # Colored output, tables, log panels, interactive prompts (huh)
│   ├── updater/             # `workroom update`: GitHub release check + binary swap
│   └── errs/                # Shared error sentinels + machine codes + exit codes
├── macapp/                  # ★ The macOS app (SwiftUI) — the product; see macapp/CLAUDE.md & macapp/README.md
├── vcs/                     # Rust VCS-reading core for the app (jj-lib + UniFFI → the WrVcs SwiftPM package)
├── scripts/workroom_setup   # This repo's own example setup hook
├── testdata/fixtures/       # Setup/teardown scripts used by Go tests
├── .github/workflows/       # CI + release + appcast automation
├── .goreleaser.yml          # CLI cross-platform build/release config
├── .golangci.yml            # Linter config
├── install.sh / install.ps1 # Standalone CLI installers
└── Makefile                 # Dev tasks: app-* (macOS app) and cli-* (Go engine)
```

### The macOS app architecture

The app (`macapp/`, see [`macapp/CLAUDE.md`](macapp/CLAUDE.md)) is a value-based, **multi-window**
SwiftUI app. The core loop:

1. **Sidebar selection** (project / root / workroom) sets `AppStore.selectedTargetID`.
2. **Opening a target** creates a libghostty terminal surface (`GhosttySurfaceView`), caches it in
   `TerminalSessions` keyed by target, and renders it in the detail pane. One live terminal per
   target persists for the session.
3. **Terminal I/O** surfaces libghostty/OSC callbacks app-wide — title (OSC 0/2), command-finished
   (OSC 133), busy/progress (OSC 9;4), and notifications (OSC) drive tab/sidebar animation, badges,
   the inspector, and desktop banners.
4. **VCS reading** (History, changeset/diffs, working-copy status, the sidebar's branch/bookmark)
   goes through a `VCSProviding` layer with two backends: a Rust core (`vcs/`, jj-lib over UniFFI →
   the `WrVcs` SwiftPM package) for JJ, and SwiftGitX (libgit2) for Git — both mapped to app-native
   models, no CLI text parsing.
5. **Mutations** (create/delete workroom, add/remove project) call the bundled Go CLI via
   `WorkroomCLI` (a `Process` wrapper that locates `Workroom.app/Contents/Resources/workroom`,
   overlays `PATH`, drains stdout/stderr concurrently, streams NDJSON logs, and decodes the JSON
   envelope), then update the store on success.
6. **State** splits into a shared `ProjectStore` (the one project list + derived branch/status data)
   and a per-window `AppStore` (selection, terminals, splits) — so multiple windows share projects
   but keep independent layouts. `WindowRegistry` tracks open windows.
7. **Preferences** live in `DefaultsKeys` (via the `Defaults` library); **auto-update** is Sparkle
   (`Updater`); **themes** load from bundled CSS theme families.

Key dependencies: **libghostty-spm** (terminal), the **WrVcs** Rust/jj-lib core + **SwiftGitX**
(VCS reading), **Sparkle** (update), **Sentry** (crash reporting), **Defaults** (preferences), and
**SwiftTreeSitter** + grammars (syntax highlighting). The app is **non-sandboxed** with the
**hardened runtime** enabled (it spawns `git`/`jj`/`workroom` and opens arbitrary directories), and
registers a global `⌘§` hotkey via Carbon. The embedded Go helper is built and signed during the
Xcode build by `macapp/Scripts/build-helper.sh` and placed under `Contents/Resources/` (not
`Contents/MacOS/`, to avoid a case-insensitive collision with `Workroom`).

### The Go CLI engine

This is the shared workroom-management engine the app drives (and the standalone CLI addon).
Everything routes through `cmd.Execute()` (called from `main.go`). The root command sets up the
persistent flags (`--verbose`, `--pretend`, `--json`) and `SilenceUsage`/`SilenceErrors` so Workroom
renders its own error format. Each subcommand builds a `workroom.Service` via `newService()`:

```go
// internal/workroom/workroom.go
type Service struct {
    Config         *config.Config
    VCS            vcs.VCS
    Out            io.Writer
    Verbose        bool
    Pretend        bool
    PromptFn       PromptFunc   // interactive multi-select (huh)
    ConfirmFn      ConfirmFunc  // interactive yes/no (huh)
    // ... plus test-injection hooks and --json wiring (SuppressEditor,
    //     KeepEmptyProject, ScriptLogWriter, OnReady)
}
```

In `--json` mode, `newService()` swaps the human pieces for machine-safe ones: output is discarded
(the command writes the JSON itself), the editor prompt is suppressed, empty projects are pinned,
and the interactive prompt/confirm hooks return errors rather than blocking. This is how the same
`Service` serves both the interactive terminal and the GUI.

`Service` methods (`Create`, `CreateNamed`, `Delete`, `InteractiveDelete`, `List`, `ListData`) hold
the orchestration logic and delegate VCS work to the `vcs.VCS` interface, persistence to
`config.Config`, and hook execution to `script.Run`.

### How a workroom is created (lifecycle)

`Service.CreateNamed` (the machine path; `Service.Create` wraps it for humans with a log panel and
the editor prompt):

1. **Guard:** reject if the cwd is already a workroom (presence of a `.Workroom` marker).
2. **Detect VCS:** `vcs.Detect(dir)` looks for `.jj` then `.git` and returns a `JJ` or `Git` impl.
3. **Generate a unique name:** try `namegen.Generate()` up to 5 times; on persistent collision,
   append a random 2-digit suffix (up to 10 more tries).
4. **Collision checks:** ensure the VCS workspace and the target directory don't already exist.
5. **Create the workspace:** `mkdir -p ~/workrooms`, then `git worktree add -b workroom/<name> <path>`
   or `jj workspace add <path> --name workroom/<name>`.
6. **Persist:** `config.AddWorkroom(...)` records `{path}` under the project, keyed by project path,
   with the VCS type.
7. **Signal readiness:** fire `OnReady` (the app mounts the workroom and starts streaming the setup
   log) before the potentially slow setup script runs.
8. **Run setup:** if `scripts/workroom_setup` exists, `script.Run("setup", …)` executes it inside the
   new workroom with the [environment variables](README.md#environment-variables), streaming combined
   stdout/stderr live.

Creation is **not transactional**: if setup fails, the workspace and config entry already exist, so
the returned `CreateResult` is populated even on error — callers can report "created, but setup
failed" and offer cleanup.

### How a workroom is deleted (lifecycle)

`Service.Delete` → `deleteByName`:

1. **Guard + validate** the name against `^[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?$`.
2. **Confirm** (interactively, or via a matching `--confirm <name>` value).
3. **Run teardown:** if `scripts/workroom_teardown` exists, run it inside the workroom (streaming).
4. **Remove the workspace:** `git worktree remove <path> --force` or `jj workspace forget workroom/<name>`.
   For JJ, the directory is also `os.RemoveAll`'d (Git's `worktree remove` already does this).
   **Branches/bookmarks are intentionally left intact** in both cases.
5. **Update config:** remove the workroom entry. If it was the project's last workroom, the project
   is dropped too — unless `KeepEmptyProject` is set (the app pins empty projects in its sidebar).

### VCS abstraction

`internal/vcs` hides Git vs JJ behind one interface:

```go
type VCS interface {
    Type() Type                                  // "git" | "jj"
    Label() string                               // human label
    WorkroomExists(dir, name string) (bool, error)
    Create(dir, vcsName, path string) (string, error)
    Delete(dir, vcsName, path string) (string, error)
    ListWorkrooms(dir string) ([]string, error)
}
```

All shell-outs go through a `CommandExecutor` (`RealExecutor` in production, a mock in tests), which
makes the orchestration fully unit-testable without touching a real repo. `vcs.Detect` is used when
creating/deleting (it touches the filesystem); `vcs.New(type)` reconstructs a VCS from the stored
config type string for listing, without requiring the project directory to exist.

### The config file

`~/.config/workroom/config.json` is the single source of truth, shared by the CLI and the app. Shape:

```json
{
  "workrooms_dir": "~/workrooms",
  "/Users/you/dev/myapp": {
    "vcs": "git",
    "workrooms": {
      "swift-meadow": { "path": "/Users/you/workrooms/swift-meadow" },
      "calm-harbor":  { "path": "/Users/you/workrooms/calm-harbor" }
    }
  }
}
```

- Top-level keys are **canonical, symlink-resolved absolute project paths** (so the same project via
  a symlink or trailing slash maps to one entry). `workrooms_dir` is a reserved key.
- Writes are **atomic** (write to a temp file, `fsync`, then `rename`) so a concurrent reader never
  sees a partial file.
- Read-modify-write cycles are guarded by a **best-effort cross-process advisory lock**
  (`config.json.lock`) so the standalone CLI and the app's bundled binary don't clobber each other;
  it degrades to running unlocked rather than failing, and steals locks left by crashed processes
  after 10s.

The CLI's machine-readable `--json` envelope — the contract the app drives the engine over — is
documented in [the README](README.md#the---json-machine-contract).

---

## Local Development

Dev tasks run through the **repo-root `Makefile`**, namespaced `app-*` (macOS app) and `cli-*` (Go
engine). Run `make` with no target to list everything.

### Working on the macOS app

The app is built with [XcodeGen](https://github.com/yonaskolb/XcodeGen): the `.xcodeproj` is
generated from `macapp/project.yml` and **gitignored**, so you regenerate it rather than editing it.

```bash
# Fastest loop: generate (if needed) → build (Debug) → relaunch the dev app
make app-run

# Build / test / lint / format
make app-build
make app-test           # WorkroomAppTests (unit, headless)
make app-uitest         # WorkroomAppUITests (XCUITest — needs a real GUI login session)
make app-lint           # swift-format --strict
make app-format         # swift-format, rewrite in place
make app-generate       # force-regenerate the .xcodeproj from project.yml

# Open in Xcode instead
cd macapp && xcodegen generate && open WorkroomApp.xcodeproj   # then ⌘R
```

The Debug product is **"Workroom Dev"** — a distinct bundle id (`…workroom.dev`) and name, with an
amber icon — so it runs alongside the installed release "Workroom" without conflict. It shares the
same `~/.config/workroom/config.json`, but skips the global `⌘§` hotkey and Sparkle scheduled checks
so it doesn't interfere with your real install.

> **Adding/removing Swift files** requires regenerating the project (`make app-generate`), since the
> file list lives in the generated `.xcodeproj`.

The Xcode build runs `macapp/Scripts/build-helper.sh` as a phase, which compiles the Go CLI and
embeds it in the app bundle — so a Go toolchain must be on `PATH` when building the app. The app
targets also run **`make app-vcs`** first (the Rust jj-lib core → the `WrVcs` SwiftPM package), which
needs **`protoc`** on `PATH` (`brew install protobuf`); a universal release build additionally needs
rustup `stable` ≥ 1.93. See [`macapp/README.md`](macapp/README.md) and
[`macapp/CLAUDE.md`](macapp/CLAUDE.md) for the full architecture, the VCS core, the libghostty
integration notes (`macapp/QA-libghostty.md`), and signing details.

### Working on the Go CLI (engine)

```bash
# Build the binary (version injected from git tags via ldflags)
make cli-build              # → ./workroom

# Run the full test suite
make cli-test               # go test ./...
go test ./internal/workroom/ -v   # one package, verbose

# Lint (golangci-lint v1.x — see Prerequisites)
make cli-lint

# Install into $GOBIN
make cli-install

# Remove the built binary
make cli-clean
```

Raw Go also works: `go build -o workroom .`, `go test ./...`. The version string defaults to `dev`
when built without ldflags (which disables `workroom update`).

**Where to make changes:**

- A new subcommand → add a file under `cmd/` and register it in its `init()`.
- New orchestration logic → `internal/workroom/`.
- A new VCS operation → extend the `vcs.VCS` interface and both `git.go` / `jj.go`.
- A new config field → `internal/config/config.go`.
- A new error class → add a sentinel in `internal/errs/errs.go` and map it in `Code`/`ExitCode`.

Because all shell-outs go through `vcs.CommandExecutor`, orchestration is testable with a mock
executor and a temp config — no real repo required.

### Available commands (`make`)

| Target | What it does |
| --- | --- |
| `make` | List all targets |
| `app-run` | Build (Debug) and relaunch the dev app |
| `app-build` | Build the app (Debug) |
| `app-test` | Run `WorkroomAppTests` (unit) |
| `app-uitest` | Run `WorkroomAppUITests` (XCUITest; needs a GUI session) |
| `app-vcs` | Build the Rust VCS core → the `WrVcs` package (auto-run before app builds) |
| `app-generate` | Regenerate the `.xcodeproj` from `project.yml` |
| `app-format` / `app-lint` | Format / lint Swift via swift-format |
| `app-release` | Build → sign → notarize → staple → DMG (full release) |
| `app-icon` | Regenerate the AppIcon PNGs |
| `app-clean` | Remove `DerivedData` + the `.xcodeproj` |
| `cli-build` | Build `./workroom` with version injected |
| `cli-test` | `go test ./...` |
| `cli-install` | `go install` into `$GOBIN` |
| `cli-lint` | `golangci-lint run` |
| `cli-clean` | Remove the built binary |

---

## Testing

**Go CLI** — standard `go test`. Coverage spans config CRUD, name generation, the VCS Git/JJ parsers
(with a mock `CommandExecutor`), the script runner (using `testdata/fixtures/{setup,teardown,failed_setup,failed_teardown}`),
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

There is no server to deploy — Workroom is a desktop app plus a CLI distributed through **GitHub
Releases**. "Deployment" here means cutting a release: GitHub Actions builds and publishes both
components automatically when you push a version tag.

### Continuous integration

`.github/workflows/ci.yml` runs on every push to `master` and every PR against it:

- **`cli` job** (`ubuntu-latest`): sets up Go from `go.mod`, runs `golangci-lint` (subsumes `go vet`
  / `gofmt`), `go build`, and `go test ./...`.
- **`app` job** (`macos-15`): sets up Xcode + Go, `brew install xcodegen jj`, runs `make app-lint`
  (swift-format `--strict`) and `make app-test` with **ad-hoc signing** flags (hosted runners have
  no signing cert), e.g.:

  ```
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
  ```

### Cutting a release

Releases are **tag-driven**. Push a `v*` tag and `.github/workflows/release.yml` does the rest:

```bash
git tag v1.4.0
git push origin v1.4.0
```

A clean `vX.Y.Z` tag publishes as a normal ("Latest") release; a tag with a prerelease component
(e.g. `v2.0.0-beta.1`, `v1.4.0-rc1`) is auto-marked as a GitHub **pre-release** so it never becomes
"Latest" (GoReleaser `prerelease: auto`).

You can test the CLI build locally with [GoReleaser](https://goreleaser.com/) before tagging
(produces binaries in `dist/` without publishing):

```bash
goreleaser build --snapshot --clean
```

**After a release publishes, curate its GitHub release notes** — replace GoReleaser's raw commit
list with a succinct, themed summary (a headline, a one-line framing, and grouped bullets). Editing
the release notes also triggers `appcast-notes.yml`, which re-renders the Sparkle update dialog's
notes from your curated body.

### Release channels

Channels are delivered as **two products**, not one switchable install:

- **Main product** — one install (the `workroom` CLI and the "Workroom" app) that tracks **stable**
  or **pre**, chosen at runtime (`workroom update --channel stable|pre`, or the app's *Settings ▸
  General ▸ Release channel*). Mutually exclusive; no side-by-side.
- **Nightly product** — a **separate download** (the `workroom-nightly` CLI and a distinct "Workroom
  Nightly" app: own bundle id `…workroom.nightly`, name, violet icon) pinned to nightly, running
  **alongside** the main install (and the Debug "Workroom Dev" build). Channel here is a *build
  identity*, not a runtime preference, so nothing can drift or collide.

| Channel | Source | Appcast tagging | Delivered as |
| --- | --- | --- | --- |
| `stable` | clean `vX.Y.Z` tags | untagged (Sparkle default — everyone) | main app / `workroom` |
| `pre` | `vX.Y.Z-beta.N` / `-rc` / `-alpha` tags | `<sparkle:channel>pre</sparkle:channel>` | main app / `workroom` |
| `nightly` | daily build off `master` | `<sparkle:channel>nightly</sparkle:channel>` | Workroom Nightly / `workroom-nightly` |

`stable` and `pre` fall out of the normal tag-driven release above. **Nightly** is a scheduled
build — `.github/workflows/nightly.yml` runs on a daily cron (and `workflow_dispatch`), building the
`Nightly` configuration ("Workroom Nightly" app) and baking `-X main.channel=nightly` into the CLI
archives. It's hosted on a single fixed **`nightly`** prerelease whose assets and appcast item are
clobbered in place each run (no per-day tags accumulate). Its version is
`<incpatch(latest-tag)>-nightly.<commit-count>`; the commit count is the monotonic key the CLI and
Sparkle order nightlies by. A no-new-commits guard skips a run when nothing changed, and the release
title (the version) is stamped only after assets + appcast publish succeed, so a partial run retries.

One appcast feed carries all channels; the main app's `allowedChannels` is the picked stable/pre
floor while the nightly app's is fixed to `{nightly}`, and Sparkle's bundle-id check is the backstop
that stops either from ever installing the other's DMG. The canonical tag → channel classification
lives in **`internal/channel`** (Go), mirrored by `macapp/WorkroomApp/Core/ReleaseChannel.swift` and
`macapp/Scripts/channel-helper.sh` — keep the three in sync. All appcast-writing workflows
(`release`, `nightly`, `appcast-notes`) share a `concurrency: appcast-feed` group so they can't
clobber each other's `appcast.xml` edits.

### Required CI secrets

The CLI release needs only the default `GITHUB_TOKEN`. The macOS app release (the `macapp` job) needs
Apple signing/notarization credentials (plus optional Sparkle/Sentry):

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PWD` | Password for the `.p12` |
| `KEYCHAIN_PASSWORD` | Password for the temporary build keychain |
| `NOTARY_KEY` | Base64-encoded App Store Connect API key (`.p8`) |
| `NOTARY_KEY_ID` | App Store Connect API key ID |
| `NOTARY_ISSUER_ID` | App Store Connect issuer ID |
| `SPARKLE_PRIVATE_KEY` | _(optional)_ EdDSA key to sign the DMG for the appcast |
| `SENTRY_AUTH_TOKEN` / `SENTRY_ORG` / `SENTRY_PROJECT` | _(optional)_ dSYM upload to Sentry |

> If the notarization job fails with a `403` / "agreement missing or expired", that's an Apple
> account gate — accept the latest agreement at developer.apple.com, then `gh run rerun <id> --failed`.

### Release artifacts

Each release publishes both components:

| Artifact | Pattern | Example |
| --- | --- | --- |
| CLI archive (macOS/Linux) | `workroom_<version>_<os>_<arch>.tar.gz` | `workroom_1.4.0_darwin_arm64.tar.gz` |
| CLI archive (Windows) | `workroom_<version>_windows_<arch>.zip` | `workroom_1.4.0_windows_amd64.zip` |
| macOS app installer | `workroom-macos-app_<version>.dmg` | `workroom-macos-app_1.4.0.dmg` |
| Nightly CLI archive | `workroom_nightly_<os>_<arch>.<ext>` | `workroom_nightly_linux_amd64.tar.gz` |
| Nightly app installer | `workroom-macos-app_nightly.dmg` | (clobbered on the fixed `nightly` release) |
| Sparkle feed | `appcast.xml` | published to a fixed `appcast` release |

Nightly asset names are **version-independent** (the fixed `nightly` release clobbers them each
run, so download URLs stay stable). `workroom update` on the stable/pre channels resolves the exact
asset URL from the GitHub API rather than constructing it, so those don't share the name-lockstep
constraint below; the constructed path is still used by `install.sh` and the nightly channel.

GoReleaser builds the CLI for `darwin`/`linux`/`windows` × `amd64`/`arm64` with
`CGO_ENABLED=0` and `-s -w -X main.version=<tag>`. The archive name (`workroom_<version>_…`) is what
`install.sh` and `internal/updater/updater.go` download, so the GoReleaser `name_template` and those
two paths must stay in lockstep — a rename in one without the others breaks `curl | sh` and
`workroom update`.

### The macOS app release pipeline

The `macapp` job runs `make app-release` (`macapp/Scripts/release.sh`) on `macos-15`:

1. `xcodegen generate`, then `xcodebuild archive` with `MARKETING_VERSION` from the tag and
   `CURRENT_PROJECT_VERSION` from the commit count (a monotonic build number for Sparkle).
2. `exportArchive` with Developer ID signing (re-signs nested helpers, including the embedded Go CLI).
3. _(optional)_ upload dSYMs to Sentry.
4. Verify signatures, then **notarize** the app (`xcrun notarytool submit --wait`), **staple** the
   ticket, and run a Gatekeeper assessment (`spctl`).
5. Build the DMG (`create-dmg`, signed), notarize + staple the DMG too.
6. _(optional)_ EdDSA-sign the DMG for Sparkle and write `appcast-fields.env`.
7. Upload the DMG to the release as `workroom-macos-app_<version>.dmg`.

### Auto-update (Sparkle appcast)

Existing app installs update themselves via [Sparkle](https://sparkle-project.org). After the DMG is
published, `macapp/Scripts/appcast.sh` merges a new `<item>` (version, build number, minimum system
version, download URL, EdDSA signature, release notes) into `appcast.xml` and uploads it to a fixed
`appcast` GitHub release that serves as the feed. When you later curate the GitHub release notes,
`.github/workflows/appcast-notes.yml` re-renders that item's `<description>` so the in-app update
dialog shows the polished notes instead of raw commits.

**Channels.** One feed carries every channel. `appcast.sh` tags each item with
`<sparkle:channel>pre</sparkle:channel>` or `nightly` (stable items stay untagged). The **main app**
reads `Updater.allowedChannels(for:)` = the picked stable/pre floor (from *Settings ▸ General ▸
Release channel*); the **Workroom Nightly** app returns a fixed `{nightly}`. Sparkle only offers
items whose channel is allowed — the untagged/default (stable) channel is always allowed, giving the
nested model for free — and its bundle-id check means the nightly app can never install a main-app
DMG (or vice-versa) even though they share the feed. The nightly item is a single **rolling** entry
(replaced each run so its enclosure signature never goes stale); pre/GA items are appended and
idempotent on `(channel, build)`. The app's channel is separate from the CLI's `workroom update`
channel — the app is Sparkle-managed, the standalone CLI self-updates.

**Upgrade migration (main app).** New installs default to `stable`. But since the app has only ever
shipped betas, an existing user upgrading into the channel-aware build would otherwise be defaulted
to `stable` and stop receiving betas until GA. So on first launch, if the channel preference is unset
*and* the running build is a prerelease, `Updater` opts the user into `pre` — preserving their
existing beta update stream. A legacy `nightly` selection (the first-pass picker briefly offered it)
is coerced to `stable`, since nightly is now the separate Workroom Nightly product. Fresh/stable
installs are untouched; the nightly build skips migration entirely (its channel is fixed).

---

## Troubleshooting a build

**App build fails** — most app build failures trace to a stale generated project or a missing tool.
Run `make app-generate` (or `make app-clean` then `make app-build`), confirm `xcodegen` and a Go
toolchain are on `PATH`, and remember adding/removing Swift files requires regenerating the project.

See [the README's Troubleshooting section](README.md#troubleshooting) for runtime issues.
