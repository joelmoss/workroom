# Workroom

Create and manage local development workrooms using [Git](https://git-scm.com/) worktrees or [Jujutsu](https://martinvonz.github.io/jj/) workspaces.

A workroom is an isolated copy of your project, allowing you to work on multiple branches or features simultaneously without stashing or switching contexts. Workrooms are created under a centralized directory (`~/workrooms` by default, configurable via `workrooms_dir` in `~/.config/workroom/config.json`).

## Installation

Add to your Gemfile:

```ruby
gem 'workroom'
```

Then run `bundle install`.

Or install directly:

```bash
gem install workroom
```

## Requirements

- Ruby >= 3.1
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

## Rails integration

Workroom includes a Rails Engine for auto-discovery by host Rails apps. Simply add the gem to your Rails app's Gemfile and it will be loaded automatically.

## License

[MIT](MIT-LICENSE)
