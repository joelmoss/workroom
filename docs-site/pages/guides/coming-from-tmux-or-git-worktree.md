---
title: Coming from tmux or git worktree
description: How Workroom maps onto the tmux sessions and git worktrees you already use, and what changes.
---

If you already juggle tasks with `git worktree` and tmux, Workroom will feel familiar: it is built on the
same ideas. This page maps what you know onto Workroom, so you can switch without relearning.

## From git worktree

A workroom is a git worktree. Workroom runs `git worktree add` for you, with a few choices made up
front:

| With `git worktree`                         | In Workroom                                                       |
| ------------------------------------------- | ----------------------------------------------------------------- |
| You pick a folder for each worktree.        | Workrooms live in `~/workrooms`, one folder each.                  |
| You name the branch.                        | A new workroom gets a generated name and the branch `workroom/<name>`. |
| You fetch and choose where to branch from.  | Workroom fetches `origin` and starts from its default branch, or your [base branch](prepare-a-project.md#choose-the-branch-new-workrooms-start-from). |
| You install dependencies in each one.       | A [setup script](prepare-a-project.md#run-a-setup-script) does it for every new workroom. |
| You copy `.env` and other ignored files.    | [`.worktreeinclude`](prepare-a-project.md#copy-gitignored-files-into-new-workrooms) copies them. |
| `git worktree remove`, then tidy up.        | Delete the workroom; a teardown script cleans up after it.        |

Your existing worktrees keep working. Workroom only manages the ones it makes, and it never changes your
root checkout. The branches it makes are ordinary branches, so `git` and every other tool see them as
usual, and deleting a workroom keeps its branch.

To change where workrooms go, set `workrooms_dir` in your
[config file](../reference/config-json.md).

## From tmux

Workroom does the jobs you use tmux for, with each workroom as the unit instead of a session:

| In tmux                         | In Workroom                                                         |
| ------------------------------- | ------------------------------------------------------------------- |
| A session per project or task   | A workroom per task, grouped under its project in the sidebar.       |
| Windows                         | Tabs: <kbd>⌘T</kbd> for a new one, <kbd>⌘1</kbd>–<kbd>⌘9</kbd> to jump. |
| Split panes                     | <kbd>⌘D</kbd> splits right, <kbd>⇧⌘D</kbd> splits down. |
| Moving between panes            | <kbd>⌃⌘</kbd> and an arrow key.                          |
| Detach, and the session runs on | Switch workroom, and its terminals keep running.                    |
| Switching sessions              | <kbd>⌥⌘1</kbd>–<kbd>⌥⌘9</kbd>, or <kbd>⌥⇥</kbd> for the last one. |
| Activity and bell monitoring    | Busy and needs-you marks on tabs and sidebar rows, with alerts.     |

There is no prefix key: shortcuts use <kbd>⌘</kbd>, like any Mac app. See
[Keyboard shortcuts](../reference/keyboard-shortcuts.md) for all of them.

### Terminals that outlive the app {nightly}

A small background process on each host keeps your terminals running when you quit Workroom, as a tmux
server does. When you open Workroom again, each terminal reattaches with its output where you left it.
On a [remote workroom](../remote/overview.md), the terminals run on the host, so they keep going even
when your Mac sleeps.

### Running tmux inside Workroom

You can still run tmux in a Workroom terminal, for a remote shell for example. Keep it out of the
shell startup, though. Workroom reads your environment from your login shell, and a `.zshrc` that ends
in `exec tmux` stops it doing so, leaving it with only the system's `PATH`. See
[Troubleshooting](../help/troubleshooting.md).
