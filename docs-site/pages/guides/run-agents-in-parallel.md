---
title: Run agents in parallel
description: Give each coding agent its own workroom, see at a glance which one needs you, and keep an eye on your usage.
---

With Workroom you can have several coding agents, such as Claude Code or Codex, working at once, each
on its own task. This guide shows how to set that up so they never trip over each other, and how to
know which one needs you without checking each in turn.

## One workroom per task

Give every task its own workroom. Each has its own folder and branch, so two agents can edit the same
file in different workrooms without either seeing the other's changes. When a task is done, you review
and ship its workroom on its own.

1. Press <kbd>⌘N</kbd>, pick the project, and press <kbd>Return</kbd>.
2. In the new workroom's terminal, start your agent, such as `claude` or `codex`, and give it the task.
3. Repeat for the next task.

If your project needs dependencies or `.env` files, [prepare it](prepare-a-project.md) first, so every
new workroom is ready for the agent when it starts.

## Watch more than one at a time

To see two workrooms side by side, press <kbd>⌥⌘N</kbd> for a new one, or
<kbd>⌥⌘O</kbd> to open an existing one, as a split beside the current workroom.
See [Splits and windows](../app/splits-and-windows.md).

To move between workrooms quickly:

| Action                        | Keys                                       |
| ----------------------------- | ------------------------------------------ |
| Switch to workroom 1 to 9     | <kbd>⌥⌘1</kbd>–<kbd>⌥⌘9</kbd>              |
| The workroom you were last in | <kbd>⌥⇥</kbd>                              |
| The pane you were last in     | <kbd>⌃⇥</kbd>                              |

## Know which agent needs you

You don't need to keep checking. While a command runs in a terminal, its tab and its row in the sidebar
show it is busy. When a terminal you aren't looking at posts a notification, its tab and project light
up, and if Workroom isn't the app in front, you get a desktop notification. Click it to go straight to
that terminal.

### Waiting, working and finished {nightly}

Claude Code 2.1.295 or later and Codex 0.163 or later tell Workroom what they are doing. Workroom shows
it on the terminal's tab and sidebar row:

- A raised hand means the agent is waiting on you: a permission, a question, a sign-in.
- A tick means it finished its turn.
- A red mark means it failed.

When an agent starts waiting on you in a terminal you aren't looking at, Workroom alerts you once and
counts it in the Dock badge. Press <kbd>⇧⌘M</kbd> to go to the terminal that has
waited longest; press it again for the next. See [Notifications](../app/notifications.md).

## Keep an eye on usage

The footer at the bottom of the window shows how much of your Claude and Codex usage you have left,
once there is a reading. Click it for the details. See [Coding agents](../app/coding-agents.md) for
setting it up, including more than one Claude account.

## When an agent is done

Review the workroom's changes, commit and push them, and open a pull request: see
[Review and ship](review-and-ship.md). When it is merged, delete the workroom.
