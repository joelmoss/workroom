# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Workroom manages development workrooms (isolated project copies) using Git worktrees or JJ
(Jujutsu) workspaces. It ships as two components that share one engine:

- **The macOS app** (`macapp/` — see [`macapp/CLAUDE.md`](macapp/CLAUDE.md)) is the primary,
  recommended product: a native SwiftUI app (macOS 14+) with a project/workroom sidebar and
  embedded terminals. It **bundles the CLI** and drives it over the machine-readable `--json` API
  (`create`/`list`/`delete`/`add-project`/`delete-project --json`).
- **The Go CLI** (repo root, documented below) is the engine that does the VCS work. It's also a
  fully **standalone** tool — terminal-first, and the only option on Linux/Windows — so app users
  never need to install it separately. It auto-detects VCS type, generates friendly workroom
  names, and stores config at `~/.config/workroom/config.json`.

The app's structured **VCS engine** lives in `vcs/` — a Rust workspace (jj via `jj-lib`/UniFFI)
plus SwiftGitX (libgit2) for git, built via `make app-vcs`. It's app-only and separate from this
Go CLI; see `macapp/CLAUDE.md` → "VCS core".

When working on the app, start with `macapp/CLAUDE.md`; the rest of this file covers the Go CLI.

## Build & Test

```bash
go build -o workroom .              # build binary
go test ./...                       # run all tests
go test ./internal/workroom/ -v     # run workroom tests verbose
```

Dev tasks run through the repo-root `Makefile`, namespaced `cli-*` (Go CLI) and `app-*` (macOS
app under `macapp/`). `make` with no target lists them. The Go CLI:

```bash
make cli-build                      # build with version injection
make cli-test                       # run tests
make cli-lint                       # golangci-lint (config: .golangci.yml)
make cli-install                    # install to $GOBIN
```

`cli-lint` requires `golangci-lint` (v1.x): `go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest`.
The macOS app targets (`app-build`, `app-run`, `app-test`, `app-format`, `app-lint`, …) are
documented in `macapp/CLAUDE.md`.

## Releases

Tag-driven (see README "Releases"). After a release publishes, **curate its GitHub release
notes** — replace GoReleaser's raw commit list with a succinct, themed summary in the style of
`v2.0.0-beta.1` (a headline, a one-line framing, and grouped bullets). The commit list is what
the git log is for.

## Architecture

Go project using Cobra for CLI, with clean internal package separation:

- `main.go` — Entry point, sets version via ldflags
- `cmd/` — Cobra command definitions (create, list, delete, add-project, delete-project, update,
  version) plus the `--json` envelope/NDJSON-log plumbing (`json.go`, `jsonlog.go`, `helpers.go`)
- `internal/config/` — JSON config CRUD at `~/.config/workroom/config.json`
- `internal/namegen/` — Adjective-noun name generation (120 adjectives, 210 nouns)
- `internal/vcs/` — VCS interface + JJ/Git implementations with `CommandExecutor` for testability
- `internal/workroom/` — Core orchestration: create/delete/list flows
- `internal/script/` — Setup/teardown script runner with env vars
- `internal/updater/` — Self-update from GitHub Releases (backs the `update` command)
- `internal/ui/` — Colored output, table printing, interactive prompts (huh library)
- `internal/errs/` — Shared error sentinels

### Subcommands

- `workroom create` (alias: `c`) — Auto-generate name, create VCS workspace, update config, run setup script
- `workroom list` (aliases: `ls`, `l`) — List workrooms for current project or all projects
- `workroom delete [NAME]` (alias: `d`) — Delete by name with `--confirm`, or interactive multi-select
- `workroom update` (alias: `u`) — Self-update from GitHub Releases (`--check` to only check)
- `workroom version` — Print version
- `workroom add-project [PATH]` / `delete-project [PATH]` — Hidden, app-only: register/remove a
  project in config so the macOS app's sidebar can show empty projects. Both error outside `--json`
  mode. `add-project` is repo-only by default (PATH must already be a Git/JJ repo) unless `--create`:
  with `--create` a missing PATH is created and git-initialized with an initial empty commit (so it's
  immediately usable as a project), an empty/junk-only existing dir is git-initialized, an existing
  Git/JJ repo is used as-is, and a non-empty non-repo dir or a file path is rejected
  (`ErrUnsupportedVCS` / `ErrNotDirectory`); `--create --pretend` is a dry-run (reports
  `would_create`, mutates nothing). Backs the app's "Create new directory…" mode (issue #103).
  `delete-project` is config-only unless: `--with-workrooms` cascades the per-workroom
  teardown (hard-deletes worktree dirs, branches kept); or `--from-disk` runs each workroom's
  teardown, drops the project from config, and returns `trash_paths` (project root first, then
  workrooms) — it does NOT delete anything itself, the macOS app moves those dirs to the Bin via
  `FileManager.trashItem` (recoverable). `--from-disk` refuses unsafe targets (`ErrUnsafeDeletePath`:
  root, `$HOME`, the workrooms dir, or an ancestor of another registered project).

### Flags

- `-v`/`--verbose` — Detailed output
- `-p`/`--pretend` — Dry run
- `--json` — Emit one machine-readable JSON envelope on stdout (errors included); non-interactive.
  How the macOS app drives the CLI; streams setup/teardown as NDJSON log events on stderr.
- `--confirm NAME` — Skip delete confirmation (delete subcommand only)
