# Workroom

A CLI to manage local development workrooms using [Git](https://git-scm.com/) worktrees or [Jujutsu](https://martinvonz.github.io/jj/) workspaces.

A workroom is an isolated copy of your project, allowing you to work on multiple branches or features simultaneously without stashing or switching contexts. Workrooms are created under a centralized directory (`~/workrooms` by default, configurable via `workrooms_dir` in `~/.config/workroom/config.json`).

Use Workroom to create a workroom for each feature or bugfix you're working on, and easily switch between them without worrying about uncommitted changes or context switching. Continue using whatever IDE or editor you like, and let Workroom handle the workroom management.

## Installation

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

**Windows (PowerShell):**

```powershell
iwr https://raw.githubusercontent.com/joelmoss/workroom/master/install.ps1 -useb | iex
```

**Install a specific version:**

```bash
VERSION=v1.2.0 curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

**Override install location (macOS / Linux):**

By default, the binary is installed to `~/.local/bin`. Set `WORKROOM_INSTALL_PATH` to change this:

```bash
WORKROOM_INSTALL_PATH=/usr/local/bin curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

### Alternative methods

**Via Go:**

```bash
go install github.com/joelmoss/workroom@latest
```

**Build from source:**

```bash
git clone https://github.com/joelmoss/workroom.git
cd workroom
make build
```

## Requirements

- [JJ (Jujutsu)](https://martinvonz.github.io/jj/) or [Git](https://git-scm.com/)

## Usage

### Create a workroom

```bash
workroom create
```

A random friendly name (e.g. `swift-meadow`) is auto-generated. Workroom automatically detects whether you're using JJ or Git and uses the appropriate mechanism (JJ workspace or git worktree).

Alias: `workroom c`

### List workrooms

```bash
workroom list
```

Lists all workrooms for the current project. When run from outside a known project, lists all workrooms grouped by parent project. When run from inside a workroom, shows the parent project path.

Aliases: `workroom ls`, `workroom l`

### Delete a workroom

```bash
workroom delete my-feature
```

Removes the workspace/worktree and cleans up the directory. You'll be prompted for confirmation before deletion.

When run without a name, an interactive multi-select menu is shown, allowing you to pick one or more workrooms to delete:

```bash
workroom delete
```

To skip the confirmation prompt (useful for scripting), pass `--confirm` with the workroom name:

```bash
workroom delete my-feature --confirm my-feature
```

Alias: `workroom d`

### Options

- `-v`, `--verbose` - Print detailed output
- `-p`, `--pretend` - Run through the command without making changes (dry run)
- `--confirm NAME` - Skip delete confirmation when NAME matches the workroom being deleted

## Setup and teardown scripts

Workroom supports user-defined scripts that run automatically during create and delete operations.

### Setup script

Place an executable script at `scripts/workroom_setup` in your project. It will run inside the new workroom directory after creation.

### Teardown script

Place an executable script at `scripts/workroom_teardown` in your project. It will run inside the workroom directory before it is deleted.

### Environment variables

The following environment variables are available to setup and teardown scripts:

- `WORKROOM_NAME` - The name of the workroom being created or deleted.
- `WORKROOM_PARENT_DIR` - The absolute path to the parent project directory. Since scripts run inside the workroom directory, this lets you reference files in the original project root.

## Releasing

Pushing a version tag triggers GitHub Actions to build binaries for all platforms and attach them to a GitHub release.

```bash
git tag v1.3.0
git push origin v1.3.0
```

You can test the build locally with [GoReleaser](https://goreleaser.com/) before tagging:

```bash
goreleaser build --snapshot --clean
```

This produces binaries in `dist/` without publishing anything.

## License

[MIT](MIT-LICENSE)
