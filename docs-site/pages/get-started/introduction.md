---
title: Introduction
description: What Workroom is, what it does best, and the four ideas the rest of the docs build on.
---

Workroom is a Mac app for working on many tasks at once. Each task gets its own workroom: a separate
copy of your project on its own branch, with its own terminals, history and diffs. You can run a dev
server in one workroom, a coding agent in another and a test suite in a third, and none of them gets in
the others' way.

The terminal is at the centre of Workroom. It is where your coding agents run, where your servers and
tests run, and where you review and commit your work. Around it, Workroom keeps every workroom's terminals
alive, shows you which ones need you, and lets you review and ship each one's changes without leaving
the app.

## Highlights

- **A workroom per task.** Each one is a git worktree on a branch of its own, so parallel work never
  collides. See [Workrooms](../app/workrooms.md).
- **Terminals that keep running.** Switch workrooms or quit the app, and every terminal carries on,
  ready to reattach. See
  [Terminals and tabs](../app/terminals-and-tabs.md#terminals-that-outlive-their-tabs).
- **Know which terminal needs you.** The bell, the menu bar, desktop banners and marks on tabs show
  where an agent or a command is waiting. See [Notifications](../app/notifications.md).
- **Built for coding agents.** Run Claude Code and Codex side by side, one per workroom, and have an
  agent diagnose a failed command and suggest the fix. See [Coding agents](../app/coding-agents.md).
- **Review and ship without leaving the app.** Read diffs, commit, push, follow the pull request's CI
  checks and merge it from the inspector. See [Inspector](../app/inspector.md).
- **Workrooms ready to work in.** A setup script installs dependencies in every new workroom, and a
  run command starts your dev server with one key. See
  [Prepare a project](../guides/prepare-a-project.md).
- **Splits and windows.** Put terminals and workrooms side by side, or pop a pane out into a window of
  its own. See [Splits and windows](../app/splits-and-windows.md).
- **The Quick Terminal.** A shell one keystroke away from any app. See
  [Terminals and tabs](../app/terminals-and-tabs.md#quick-terminal).
- **Remote workrooms.** Run a workroom on a boxd or exe.dev machine, or in a container, and work in it
  as if it were local. Nightly only. See [Remote workrooms](../remote/overview.md).

## Four ideas

**Project.** A git repository you have added to Workroom. It appears in the sidebar, and every workroom
you make belongs to one project. Your original checkout of it is called the root.

**Workroom.** A copy of a project that you work in. It is a git worktree: a real directory with its own
working copy and its own branch, sharing the project's history. A new workroom gets a generated name,
such as `swift-meadow`, lives in `~/workrooms/swift-meadow`, and is on the branch
`workroom/swift-meadow`. Nothing you do in it touches the root or any other workroom.

**Base.** The branch new workrooms start from. Unless you choose another, it is the default branch on
`origin`, freshly fetched.

**Host.** Where a workroom runs. Most workrooms run on this Mac. A remote workroom runs on a host of its
own, such as a boxd or exe.dev machine or a container, while you work in it from the app as if it were
local. See [Remote workrooms](../remote/overview.md).

## The app and the CLI

The Mac app is the product. It bundles the `workroom` command-line tool and drives it for every project
and workroom operation, so you never need to install the CLI separately. If you want the command in
your own shell too, the app can put it on your `PATH`. The CLI also runs on its own on macOS, Linux and
Windows. See [Install](install.md).

## Where to go next

1. [Install](install.md) the app.
2. Follow [Your first workroom](your-first-workroom.md), from adding a project to merging a pull request.
3. [Prepare a project](../guides/prepare-a-project.md) so every new workroom is ready to work in.
