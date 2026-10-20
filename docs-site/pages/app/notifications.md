---
title: Notifications
description: Find out which terminal needs you, from the bell, the menu bar, desktop banners and the marks on tabs.
---

Workroom tells you when a terminal you are not looking at has something for you, so you can keep several coding agents and long commands going at once. This page covers the bell, the menu bar item, desktop banners and, in Nightly, the marks that show a terminal is waiting on you.

## The bell

The bell sits at the right of the footer along the bottom of the window. A number on it counts your unread notifications. The footer stays in place when you switch workrooms or hide the sidebars.

Click the bell to open the list. Each entry shows the notification's title and text, the workroom it came from and how long ago. A repeat from the same terminal is counted as `×N`. Click an entry to go straight to that terminal. Right-click an entry for **Delete Notification**, or click **Clear All** at the bottom of the list.

<kbd>⌘</kbd>-click the bell, or press <kbd>⇧⌘N</kbd> (**Go ▸ Next Notification**), to jump to the oldest pending one. Opening it dismisses it, so pressing the key again walks through the backlog from oldest to newest. The bell is off when there are none.

When a terminal in the background posts a notification, its tab and its project in the sidebar show an unread dot. If Workroom is not the app in front, you also get a desktop banner. Click the banner to jump to the terminal.

## The menu bar

Workroom can show its logo in the macOS menu bar, with the same count across all your windows. Turn it on or off with **Settings ▸ Notifications ▸ Show notifications in the menu bar**. In Workroom 2.1.0 this switch is in **Settings ▸ General**.

Click it to open the list. When there is nothing pending, a click brings Workroom to the front instead. Click an entry to open its terminal.

## When a terminal needs you {nightly}

A program in a terminal can tell Workroom what it is doing: working, waiting on you, finished, or failed. Claude Code 2.1.295 and later, and Codex 0.163 and later, do this. Workroom shows it as a mark, and alerts you once when a program starts waiting on you in a terminal you are not looking at.

### The marks

| Mark | Meaning |
| --- | --- |
| A raised hand | The program is waiting on you: a permission, a question or a sign-in |
| A red line under the tab, a red exclamation mark in the sidebar row | The program failed |
| A moving line under the tab, a spinner in the sidebar row | The program is working |
| A check mark | The program finished its turn |

The marks show on the terminal's tab and its row in the sidebar. The hand also shows on a workroom's row with a count, on a collapsed project, and on the switcher. Only one mark shows in each place. The order is waiting, then failed, then working, then finished.

Hover a mark to read what the program said. A finished or failed mark clears when you move focus into that terminal.

A terminal with no mark is not reporting. That is not the same as not waiting. Programs other than Claude Code and Codex mostly do not report yet.

### Go to the terminal that needs you

Click the hand on a workroom row or on a collapsed project to go to the terminal that has waited longest. The switcher shows the hand too, as a mark only. Or press <kbd>⇧⌘M</kbd> (**Go ▸ Go to Terminal That Needs You**), which looks across every window. Press it again to step through the others.

### The alert

When a program starts waiting on you and you are not looking at its terminal, Workroom posts a notification such as "Terminal 2 in fix-auth needs you". It also counts the request on the Dock badge and the menu bar. The count drops when you answer the request, on this Mac or another, or when the program ends. Reading the notification does not lower it.

In the menu bar list, requests appear under **Waiting for you** and everything else under **Unread notifications**.

One request makes one notification. Workroom folds the program's own notification for the same request into its alert, so you do not get two. Claude Code posts its own about 6 seconds after it starts waiting, and if you answer inside that time it never alerts.

Codex does not ask Workroom whether it supports status. Workroom trusts it once it has stayed running in the foreground for about a second after it started waiting, so its alert comes 1 to 3 seconds in. If you switch away before then, you get the hand and the Dock count but no banner.

### A finished turn

When a program finishes its turn in a terminal you are not looking at, Workroom posts an ordinary notification, such as "Terminal 2 in fix-auth finished". It alerts once per turn, and the terminal's next finish replaces it. A session that runs turns on its own leaves one entry, not one per turn. A finish you watched happen leaves only the check mark.

### Turn the alerts off

- **Settings ▸ Notifications ▸ Notify when a terminal needs me** turns off the alerts and the Dock count. The marks stay, and requests still show in the menu bar list. A program's own notifications still arrive as before.
- **Settings ▸ Notifications ▸ Notify when a terminal finishes** turns off the finished-turn alerts. The program's own notification after its turn is then no longer replaced.

### Clear a stuck mark

If a program left a request behind, for example because it crashed in the middle of a question, right-click the tab or the sidebar row and choose **Clear Status**.

### Remote hosts

Marks work in terminals on remote hosts too. When Workroom loses its link to a host, the marks stay with a small clock beside them, and the tooltip says they may be out of date until Workroom reconnects. **Clear Status** waits for the link as well.

Run tabs and other panes that do not run under Workroom's background helper never show program status.

### For program authors

The protocol is OSC 7501. Its specification is the [program status protocol](https://www.superlogical.com/rex/docs/build/program-status). A program asks the terminal whether it supports the protocol, then reports its state.

## Command results {nightly}

A shell command that runs for 10 seconds or longer leaves a result on its pane. A build or test run that ends in a background tab, or on a remote host while your laptop is closed, then tells you how it went without you opening the terminal.

- A check mark means the command exited 0.
- The failed mark means any other exit.
- Nothing shows when you stop the command with <kbd>⌃C</kbd>.
- Quicker commands leave nothing.

Hover the mark to read **Command finished** or **Command failed (exit 1)**, then the command line. Focusing the terminal clears the mark. It never alerts you and never counts on the Dock badge. If you start a program such as `claude` after a failed run, the pane shows that the program is working, not the failure.

It needs Ghostty's shell integration, which Workroom turns on for zsh, bash, fish, elvish and Nushell. macOS's own `/bin/bash` never shows it. See [Terminals and tabs](terminals-and-tabs.md#shell-integration).
