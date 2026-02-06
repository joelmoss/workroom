# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Workroom is a Rails Engine gem that provides a `rails workroom` command for creating and managing development workrooms or workspaces using Git worktrees or JJ workspaces. Targets Rails >= 7.1, Ruby >= 3.3.

## Build

```bash
bundle install
gem build workroom.gemspec
```

No test suite exists yet.

## Lint

```bash
bin/rubocop
bin/rubocop -a  # auto-fix
```

## Code Style

Rubocop enforced with plugins: `rubocop-disable_syntax`, `rubocop-packaging`, `rubocop-performance`.

- **No `unless`** — use `if !condition` instead (enforced by `rubocop-disable_syntax`)
- **No `and`/`or`/`not`** — use `&&`/`||`/`!`
- **No numbered parameters** (`_1`, `_2`)
- Indentation: `indented_internal_methods` (private methods indented one extra level)
- Line length: 100 chars max

## Architecture

A minimal Rails Engine with a single custom Rails command.

- `lib/workroom/engine.rb` — Empty `Rails::Engine` subclass for auto-discovery by host Rails apps
- `lib/commands/workroom_command.rb` — All core logic in `Rails::WorkroomCommand < Rails::Command::Base`

### Command: `rails workroom`

Two subcommands: `add NAME` and `delete NAME`.

**`add`** creates a workroom as a sibling directory (`../NAME`), detects JJ (via `.jj` dir at `Rails.root`) vs git, copies `.env.local` with prepended workroom env vars (`DEFAULT_WORKROOM_PATH`, `PROJECT_NAME`, `HOST_DOMAIN`), and symlinks `.bundle`.

**`delete`** removes the workspace/worktree, deletes the Caddy reverse proxy route via admin API at `localhost:2019` (route ID: `{name}-{project_name}`), and cleans up the directory for JJ.

The `check_not_in_workroom!` guard prevents running from within an existing workroom by checking for `$DEFAULT_WORKROOM_PATH`. The command requires `PROJECT_NAME` and `HOST_DOMAIN` env vars to be set. Uses Thor actions (inherited from `Rails::Command::Base`) for file operations.
