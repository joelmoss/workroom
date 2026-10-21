---
title: Settings
description: Every setting in the Workroom app, pane by pane, with what each one does.
---

Open Settings with <kbd>⌘,</kbd> (**Workroom ▸ Settings…**), or click the gear at the bottom of the right-hand activity bar. The window has a list of panes on the left. Changes apply straight away, and Workroom remembers the pane you were on.

Settings that belong to one project, such as its run command, are in [Project Settings](projects.md#project-settings).

## General

| Setting | What it does |
| --- | --- |
| **Confirm before quitting** | Asks before Workroom quits. It is on by default. |
| **Global show/hide hotkey (⌘§)** | Registers <kbd>⌘§</kbd> to show or hide Workroom from any app, and <kbd>⌥§</kbd> to open the Quick Terminal. It is on by default. |

**Workroom ▸ Confirm Before Quitting** in the menu is the same switch.

### New Workrooms {nightly}

| Setting | What it does |
| --- | --- |
| **Base branch** | The branch new workrooms start from in every project that sets none of its own. Leave it empty to use `origin`'s default branch. |
| **Close the checklist automatically when done** | Closes a new workroom's checklist a few seconds after the workroom is ready, instead of waiting for you to click **Done**. |

New workrooms start from `origin`'s copy of the base branch, otherwise the local branch. Write `upstream/main` to start from another remote's branch, such as a fork's upstream. A project's own base branch in Project Settings wins. The field saves when you press <kbd>Return</kbd> or leave it. See [Projects](projects.md#base-branch) and [Workrooms](workrooms.md#watch-the-steps).

## Notifications {nightly}

| Setting | What it does |
| --- | --- |
| **Show notifications in the menu bar** | Shows the Workroom notifications item in the macOS menu bar. Its logo turns yellow while anything is pending. |
| **Show unread count in the menu bar** | Shows how many notifications and requests are pending beside the menu bar logo. Off by default. |
| **Notify when a terminal needs me** | Alerts you, and counts it on the Dock badge, when a program in a terminal waits on you. Off keeps the marks but stops Workroom's alerts. The program's own notifications still arrive. |
| **Notify when a terminal finishes** | Alerts you when a program finishes its turn in a terminal you are not looking at. It replaces the program's own notification after its turn. |

In Workroom 2.1.0 there is no Notifications pane. **Show notifications in the menu bar** is in **General**. See [Notifications](notifications.md).

## Appearance

| Setting | What it does |
| --- | --- |
| **Appearance** | **System**, **Light** or **Dark**. System follows macOS. |
| **Theme** | Opens the theme picker. A theme family has a light and a dark variant, and the one in use follows **Appearance**. Terminals change with it. The picker is also on <kbd>⇧⌘K</kbd> (**View ▸ Theme…**). |
| **Diff view** | **Unified** or **Side by Side** for diffs you open from now on. A narrow pane always falls back to unified. |
| **Dim unfocused panes** | Shades every pane except the focused one so the active terminal stands out in a split. On by default. |
| **Resize splits evenly automatically** | Evens out the dividers whenever a pane joins or leaves a split, only those running the same way as that pane. Off leaves them where they are. **View ▸ Resize Splits Evenly** still works either way. |
| **Load author avatars** | Fetches author and reviewer avatars from Gravatar and GitHub. Off shows coloured initials only and makes no network request. |

<kbd>⇧⌘L</kbd> (**View ▸ Light Mode** or **Dark Mode**) flips between light and dark without opening Settings.

## Terminal

| Setting | What it does |
| --- | --- |
| **Copy on select** | Copies whatever you select in a terminal to the clipboard. On by default. |
| **Confirm before closing a terminal** | Asks before closing a terminal, because that ends its shell and anything running in it, with no undo. |
| **Open file paths in** | The app that opens a file path you <kbd>⌘</kbd>-click in a terminal: **Default App**, or one of Visual Studio Code, Zed and Xcode if installed. |

### Stop Detached Terminals… {nightly}

The **Stop Detached Terminals…** button counts the background terminals that no open tab is attached to and asks before it stops them. The note under it explains that terminals keep running after you quit, reattach when you relaunch, and that run commands and the Quick Terminal are never kept. See [Terminals and tabs](terminals-and-tabs.md#detached-sessions).

In Workroom 2.1.0 this pane has a **Persist sessions** switch instead, and terminals only survive a quit while it is on.

## AI Agents

This pane is called **Agent** in Workroom 2.1.0.

| Setting | What it does |
| --- | --- |
| **Investigate with** | The agent the **Investigate** button opens: **Auto (Claude, else Codex)**, **Claude** or **Codex**. The diagnosis itself always uses Claude Code. Called **Diagnose with** in Workroom 2.1.0. |
| **Diagnose automatically** | Runs the diagnosis as soon as a command fails, instead of waiting for you to ask. |
| **Redact obvious secrets before sending** | Masks obvious secrets in a failed command's output before it goes to the agent. Best-effort, not a guarantee. |

See [Coding agents](coding-agents.md#diagnose-a-failed-command).

### Usage {nightly}

| Setting | What it does |
| --- | --- |
| **Show in the window footer** | Shows every coding agent's usage in the footer of the window. On by default. |
| **Show in the pane footer** | Shows the usage of the coding agent running in a pane in that pane's footer. Only while an agent runs there. Off by default. |
| **Claude usage ▸ Enable…** | Appears only after you chose **Don’t Ask Again** on the footer's **Enable usage…** prompt and Claude usage still comes from the status line. It turns the Claude status-line reading on. |

See [Coding agents](coding-agents.md#usage).

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
