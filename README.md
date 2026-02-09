# Workroom

Create and manage local development workrooms using [JJ](https://martinvonz.github.io/jj/) workspaces or git worktrees.

A workroom is an isolated copy of your project created as a sibling directory, allowing you to work on multiple branches or features simultaneously without stashing or switching contexts.

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
- [JJ (Jujutsu)](https://martinvonz.github.io/jj/) or Git

## Usage

### Create a workroom

```bash
workroom create my-feature
```

This creates a new workroom at `../my-feature` relative to your project root. Workroom automatically detects whether you're using JJ or Git and uses the appropriate mechanism (JJ workspace or git worktree).

### Delete a workroom

```bash
workroom delete my-feature
```

Removes the workspace/worktree and cleans up the directory. You'll be prompted for confirmation before deletion.

### Options

- `-v`, `--verbose` - Print detailed output
- `-p`, `--pretend` - Run through the command without making changes (dry run)

### Naming rules

Workroom names must be alphanumeric (dashes and underscores allowed) and must not start or end with a dash or underscore.

## Setup and teardown scripts

Workroom supports user-defined scripts that run automatically during create and delete operations.

### Setup script

Place an executable script at `scripts/workroom_setup` in your project. It will run inside the new workroom directory after creation.

### Teardown script

Place an executable script at `scripts/workroom_teardown` in your project. It will run after a workroom is deleted.

## Rails integration

Workroom includes a Rails Engine for auto-discovery by host Rails apps. Simply add the gem to your Rails app's Gemfile and it will be loaded automatically.

## License

[MIT](MIT-LICENSE)
