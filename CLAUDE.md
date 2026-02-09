# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Workroom is a standalone CLI tool (Go binary) for creating and managing development workrooms using Git worktrees or JJ (Jujutsu) workspaces. It auto-detects VCS type, generates friendly workroom names, and manages configuration at `~/.config/workroom/config.json`.

## Build & Test

```bash
go build -o workroom .              # build binary
go test ./...                       # run all tests
go test ./internal/workroom/ -v     # run workroom tests verbose
go vet ./...                        # lint
make build                          # build with version injection
make test                           # run tests
make install                        # install to $GOBIN
```

## Architecture

Go project using Cobra for CLI, with clean internal package separation:

- `main.go` — Entry point, sets version via ldflags
- `cmd/` — Cobra command definitions (root, create, list, delete, version)
- `internal/config/` — JSON config CRUD at `~/.config/workroom/config.json`
- `internal/namegen/` — Adjective-noun name generation (120 adjectives, 210 nouns)
- `internal/vcs/` — VCS interface + JJ/Git implementations with `CommandExecutor` for testability
- `internal/workroom/` — Core orchestration: create/delete/list flows
- `internal/script/` — Setup/teardown script runner with env vars
- `internal/ui/` — Colored output, table printing, interactive prompts (huh library)
- `internal/errs/` — Shared error sentinels

### Subcommands

- `workroom create` (alias: `c`) — Auto-generate name, create VCS workspace, update config, run setup script
- `workroom list` (aliases: `ls`, `l`) — List workrooms for current project or all projects
- `workroom delete [NAME]` (alias: `d`) — Delete by name with `--confirm`, or interactive multi-select
- `workroom version` — Print version

### Flags

- `-v`/`--verbose` — Detailed output
- `-p`/`--pretend` — Dry run
- `--confirm NAME` — Skip delete confirmation (delete subcommand only)
