---
title: Settings
description: Every setting in the Workroom app, pane by pane, with what each one does.
---

Open Settings with <kbd>⌘,</kbd> (**Workroom ▸ Settings…**), or click the gear at the bottom of the right-hand activity bar. The window has a list of panes on the left. Changes apply straight away, and Workroom remembers the pane you were on.

Settings that belong to one project, such as its run command, are in the [Projects](#projects) pane.

## General

| Setting | What it does |
| --- | --- |
| **Confirm before quitting** | Asks before Workroom quits. It is on by default. |
| **Global show/hide hotkey (⌘§)** | Registers <kbd>⌘§</kbd> to show or hide Workroom from any app, and the Quick Terminal's shortcut (<kbd>⌥§</kbd> unless you change it in [Terminal](#quick-terminal)). It is on by default. |

**Workroom ▸ Confirm Before Quitting** in the menu is the same switch.

### Quitting with dev servers running

| Setting | What it does |
| --- | --- |
| **When quitting with dev servers running** | What quitting does to run commands that are still going. **Ask** (the default) asks the first time and keeps your answer. **Keep running** leaves them going, and their tabs reattach when you reopen Workroom. **Stop** stops each one as Stop does, and its tab does not come back. An update always keeps them running. |

The question appears whether or not **Confirm before quitting** is on. See [Quitting with a run going](terminals-and-tabs.md#quitting-with-a-run-going).

### New Workrooms

| Setting | What it does |
| --- | --- |
| **Base branch** | The branch new workrooms start from in every project that sets none of its own. Leave it empty to use `origin`'s default branch. |
| **Close the checklist automatically when done** | Closes a new workroom's checklist a moment after the workroom is ready, instead of waiting for you to click **Done**. |

New workrooms start from `origin`'s copy of the base branch, otherwise the local branch. Write `upstream/main` to start from another remote's branch, such as a fork's upstream. A project's own base branch in [Projects](#projects) wins. The field saves when you press <kbd>Return</kbd> or leave it. See [Projects](projects.md#base-branch) and [Workrooms](workrooms.md#watch-the-steps).

## Notifications

| Setting | What it does |
| --- | --- |
| **Show notifications in the menu bar** | Shows the Workroom notifications item in the macOS menu bar. Its logo turns yellow while anything is pending. |
| **Show unread count in the menu bar** | Shows how many notifications and requests are pending beside the menu bar logo. Off by default. |
| **Notify when a terminal needs me** | Alerts you, and counts it on the Dock badge, when a program in a terminal waits on you. Off keeps the marks but stops Workroom's alerts. The program's own notifications still arrive. |
| **Notify when a terminal finishes** | Alerts you when a program finishes its turn in a terminal you are not looking at. It replaces the program's own notification after its turn. |

See [Notifications](notifications.md).

## Appearance

| Setting | What it does |
| --- | --- |
| **Appearance** | **System**, **Light** or **Dark**. System follows macOS. |
| **Theme** | Opens the theme picker. A theme family has a light and a dark variant, and the one in use follows **Appearance**. Terminals change with it. The picker is also on <kbd>⇧⌘K</kbd> (**View ▸ Theme…**). |
| **Diff view** | **Unified** or **Side by Side** for diffs you open from now on. A narrow pane always falls back to unified. |
| **Dim unfocused panes** | Shades every pane except the focused one so the active terminal stands out in a split. On by default. |
| **Automatically resize splits evenly** | When you add or close a pane, or drag one to a new place in its split, the panes in its row or column resize to match. With workrooms side by side, every terminal in the window ends up the same size. Off leaves the dividers where you put them. See [Even out a split](splits-and-windows.md#even-out-a-split). |
| **Load author avatars** | Fetches author and reviewer avatars from Gravatar and GitHub. Off shows coloured initials only and makes no network request. |

<kbd>⇧⌘L</kbd> (**View ▸ Light Mode** or **Dark Mode**) flips between light and dark without opening Settings.

## Terminal

| Setting | What it does |
| --- | --- |
| **Copy on select** | Copies whatever you select in a terminal to the clipboard. On by default. |
| **Confirm before closing a terminal** | Asks before closing a terminal, because that ends its shell and anything running in it, with no undo. |
| **Open file paths in** | The app that opens a file path you <kbd>⌘</kbd>-click in a terminal: **Default App**, or one of Visual Studio Code, Zed and Xcode if installed. |

### Report terminal as Ghostty

Off by default. New terminals set `TERM=xterm-256color`, which every Mac, server and container knows, so `top`, `sudo vim` and `ssh` to any server work as they do in Terminal. Programs still see `COLORTERM=truecolor` and `TERM_PROGRAM=ghostty`, so full colour and Ghostty detection are unchanged.

On, new terminals set `TERM=xterm-ghostty`. Programs that look a terminal up by that name, tmux among them, then use what Ghostty adds: full colour without a tmux setting, curly and coloured underlines, and synchronized output. The `xterm-ghostty` entry only exists on this Mac, so macOS's `top`, editors under `sudo`, and `ssh` to a server without the entry stop working. See [`top` says "Error opening terminal: xterm-ghostty"](../help/troubleshooting.md#top-says-error-opening-terminal-xterm-ghostty).

The setting applies to terminals you open after changing it. Remote workrooms don't use this setting. They use `xterm-ghostty` once Workroom has installed its entry on the remote machine, and `xterm-256color` until then.

### Stop Detached Terminals…

The **Stop Detached Terminals…** button counts the background terminals that no open tab is attached to and asks before it stops them. The note under it explains that terminals keep running after you quit and reattach when you relaunch, that run commands do too unless you choose to stop them, and that the Quick Terminal is never kept. See [Terminals and tabs](terminals-and-tabs.md#detached-sessions).

### Quick Terminal

| Setting | What it does |
| --- | --- |
| **Slides in from** | The screen edge the Quick Terminal slides in from: **Top** (the default), **Bottom**, **Left** or **Right**. It sits centred along that edge until you drag it somewhere else. Dragging it to another edge changes this setting too. |
| **Slide away when it loses focus** | Hides the Quick Terminal when you click another window or switch to another app. On by default. Off leaves it up until you press its shortcut. |
| **Opens in** | The folder a new Quick Terminal shell starts in, shown as its full path. Your home folder is the default. **Choose…** picks another, and **Use Home**, shown only then, goes back. If the folder is gone, it opens in your home folder. |
| **Keyboard shortcut** | The global shortcut that shows and hides the Quick Terminal from any app, <kbd>⌥§</kbd> by default. Click it and press the new keys, with at least one of <kbd>⌘</kbd>, <kbd>⌥</kbd> or <kbd>⌃</kbd>. <kbd>Esc</kbd> cancels, and **Reset** goes back to <kbd>⌥§</kbd>. A shortcut another app already uses is refused. |

A Quick Terminal that is only hidden keeps its shells, so a new folder applies from the next new tab. The shortcut works while **Global show/hide hotkey (⌘§)** in General is on. See [Terminals and tabs](terminals-and-tabs.md#quick-terminal).

## AI Agents

| Setting | What it does |
| --- | --- |
| **Investigate with** | The agent the **Investigate** button opens: **Auto (Claude, else Codex)**, **Claude** or **Codex**. The diagnosis itself always uses Claude Code. |
| **Diagnose automatically** | Runs the diagnosis as soon as a command fails, instead of waiting for you to ask. |
| **Redact obvious secrets before sending** | Masks obvious secrets in a failed command's output before it goes to the agent. Best-effort, not a guarantee. |

See [Coding agents](coding-agents.md#diagnose-a-failed-command).

### Usage

| Setting | What it does |
| --- | --- |
| **Show in the window footer** | Shows every coding agent's usage in the footer of the window. On by default. |
| **Show in the pane footer** | Shows the usage of the coding agent running in a pane in that pane's footer. Only while an agent runs there. Off by default. |
| **Claude usage ▸ Enable…** | Appears only after you chose **Don’t Ask Again** on the footer's **Enable usage…** prompt and Claude usage still comes from the status line. It turns the Claude status-line reading on. |

See [Coding agents](coding-agents.md#usage).

## Projects

The pane lists your projects. Click one to open its settings, and the back button to return to the list. They are its run command, its base branch and its boxd and exe.dev options. The gear on a project row in the sidebar, and **Project Settings…** in its right-click menu, open this pane on that project. A text field saves when you press <kbd>Return</kbd> or leave it. See [Project settings](projects.md#project-settings).

## Remote Hosts

What Workroom creates each new boxd and exe.dev workroom's host with. Existing workrooms keep the host they were made with. There is a group for each provider, shown whether or not you have set that provider up, and each setting saves as you change it. Each group's **info** link opens [Choose a host's image and size](../remote/overview.md#choose-a-hosts-image-and-size). In a list, the provider's own default is marked **(default)**, and choosing it leaves the choice to the provider. Where the provider doesn't say what its default is, the list shows **Provider default** instead.

| Setting | What it does |
| --- | --- |
| **Snapshot** (boxd) | A snapshot of one of your boxd machines to start new machines from. Pick one from the list, or type a name. A name that the boxd account you're signed in to doesn't have shows a warning, whose **help** link opens [Start from a snapshot](../remote/boxd.md#start-from-a-snapshot). Empty, new machines start fresh. |
| **Size** (boxd) | One of boxd's sizes, up to your org's limit per machine. Your org's default size is marked **(default)**. A machine made from a snapshot keeps the snapshot's size, so this is off while a snapshot is set. |
| **Custom image** (exe.dev) | The container image new VMs start from, with its registry: a name without one, such as `boldsoftware/exeuntu`, is looked up on Docker Hub. Empty, exe.dev uses its own `ghcr.io/boldsoftware/exeuntu`. |
| **CPU**, **Memory**, **Disk** (exe.dev) | The size of new VMs, up to what your plan allows. exe.dev's default CPU and your plan's default disk are marked **(default)**. If Workroom can't read your plan, these are text fields. |

A project can choose its own in [Projects](#projects), and one create can choose its own. See [Choose a host's image and size](../remote/overview.md#choose-a-hosts-image-and-size).

## About

| Setting | What it does |
| --- | --- |
| **Version** | The version you are running. |
| **View release notes** | Opens the releases page on GitHub. |
| **Repository on GitHub** | Opens the Workroom repository. |
| **Check for Updates…** | Checks for a newer version now. |
| **Automatically check for updates** | Lets Workroom check in the background. |
| **Release channel** | **Stable** or **Pre-release**. The Nightly app does not show it, because its channel is fixed. |

See [Updates and release channels](updates-and-channels.md).
