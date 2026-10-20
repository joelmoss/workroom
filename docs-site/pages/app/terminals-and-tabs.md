---
title: Terminals and tabs
description: Use Workroom's terminals and tabs, open file paths in your editor, find text, run a project command and use the Quick Terminal.
---

Every workroom opens with a real terminal in its directory. This page covers opening and managing terminals and tabs, the Run command, the Quick Terminal and what to know about shell integration.

## Terminals

Terminals are drawn by [libghostty](https://ghostty.org), the engine behind the Ghostty terminal. Select a workroom, and its terminal is already in the right directory. A workroom keeps its terminals running while you work in another one, so a dev server, a build or a coding agent is as you left it when you come back.

While a program in a terminal reports that it is working, such as a coding agent, its tab shows a moving underline and its sidebar row a spinner, so you can see what is busy without switching to it.

## Tabs

A workroom can hold as many terminals as you like. They sit in a tab strip that you can reorder by dragging. A tab names itself after the running command. When the command ends it goes back to its own name, such as **Terminal 1**, unless your shell sets a title of its own, such as the working directory.

| To do this | Use |
| --- | --- |
| Open a new terminal | <kbd>⌘T</kbd>, or the new-terminal button in the tab strip |
| Focus tab 1 to 9, left to right | <kbd>⌘1</kbd> to <kbd>⌘9</kbd> |
| Next or previous terminal tab | <kbd>⌥⌘→</kbd> and <kbd>⌥⌘←</kbd> |
| Flip to the pane you used last | <kbd>⌃Tab</kbd> (**Go ▸ Last-Used Pane**) |
| Close the tab | <kbd>⌘W</kbd> (**File ▸ Close Tab**) |
| Scroll to the top or bottom | <kbd>⌘↑</kbd> and <kbd>⌘↓</kbd> |

**File ▸ Close Other Tabs** and **File ▸ Close All Tabs** close several at once. Closing a terminal ends its shell and anything running in it. When a process is still running, Workroom asks first. This is on by default. Turn it off with **Settings ▸ Terminal ▸ Confirm before closing a terminal**, **File ▸ Confirm Before Closing a Terminal**, or **Don't ask me again** in the prompt.

Right-click a tab for **Split Right**, **Split Left**, **Split Down**, **Split Up**, **Move to New Window** and **Close**. See [Splits and windows](splits-and-windows.md). Right-click inside the terminal for **Paste** and the same split, window and close commands, plus **New Terminal**.

## Find text

Press <kbd>⌘F</kbd> to search the focused terminal's scrollback. <kbd>⌘G</kbd> goes to the next match and <kbd>⇧⌘G</kbd> to the previous one. Press <kbd>Esc</kbd> to close the find bar. The same keys search a file you have open in a pane.

## Copy and paste

With **Copy on select** on, anything you select in a terminal is copied to the clipboard straight away. It is on by default. Switch it in **Settings ▸ Terminal ▸ Copy on select** or **Edit ▸ Copy on Select**.

## Open file paths in your editor

<kbd>⌘</kbd>-click a file path in a terminal to open that file in your editor. It works on paths that point at a real file, including relative paths, and on `file:line:column` forms. VS Code, Zed and Xcode open the file at that line.

Choose the editor in **Settings ▸ Terminal ▸ Open file paths in**. It lists **Default App** and whichever of Visual Studio Code, Zed and Xcode you have installed. **Default App** opens the file as Finder would.

A <kbd>⌘</kbd>-click on anything else goes to the terminal as an ordinary click.

To open the whole workroom, use **Go ▸ Open in** your editor, for example **Open in Zed** (<kbd>⇧⌘O</kbd>), or the editor button in the workroom's title bar. Its small arrow lets you pick a different editor. **File ▸ Reveal in Finder** shows the workroom's folder in Finder. Click the folder path in a pane's footer to copy it or reveal it.

## Shell integration

Workroom turns on Ghostty's shell integration for zsh, bash, fish, elvish and Nushell. It lets Workroom know when a command starts and ends and where your shell is. Failed-command diagnosis, the tab title reset after a command and working-directory tracking depend on it, and so does the [command result mark](notifications.md#command-results).

macOS's own `/bin/bash` is version 3.2, and it ignores the startup hook the integration uses. If that is your login shell, you get none of these. Homebrew bash 4.4 or newer works:

```sh
brew install bash
echo "$(brew --prefix)/bin/bash" | sudo tee -a /etc/shells
chsh -s "$(brew --prefix)/bin/bash"
```

Log out and back in so apps you open from the Dock see the new shell, then open a new terminal in Workroom. `echo $BASH_VERSION` should print 5.x.

## Terminals that outlive their tabs

A terminal's shell is held by a background helper, not by its tab. That is why terminals keep running when you quit Workroom, and reattach when you open it again. Closing a terminal ends it. Run commands and the Quick Terminal are never kept.

> [!NOTE]
> In Workroom 2.1.0 this was a setting named **Persist sessions**. Nightly removed the setting, and terminals always survive a quit.

### Detached sessions

A session can be running in the background with no tab in the workroom showing it. When the current workroom has such sessions, a button with a stack icon and a count appears at the right of the pane footer, the strip along the bottom of a pane.

Click it to see **Detached terminals**. Each row shows the terminal's title and its folder, and three buttons:

- **Active tab** attaches the session to the tab you are in. It is off until that tab has a terminal.
- **New tab** opens the session in a new tab.
- **Stop** ends the session and anything running in it.

### Stop all detached terminals {nightly}

**Settings ▸ Terminal ▸ Stop Detached Terminals…** counts the background terminals that no open tab is attached to, then asks before it stops them and anything running in them.

## Run a command

Set a run command for a project, such as `npm run dev`, and start it in any of its workrooms with one key. See [Projects](projects.md#run-command) for setting it.

| To do this | Use |
| --- | --- |
| Run, or jump to the run if it is already going | <kbd>⌘R</kbd> (**Run ▸ Run**) |
| Restart | <kbd>⌥⌘R</kbd> (**Run ▸ Restart**) |
| Stop | <kbd>⇧⌘R</kbd> (**Run ▸ Stop**) |
| Go to the run terminal | **Go ▸ Run Terminal** |

The workroom's title bar and the root row in the sidebar have the same buttons. While a run is going, the title bar shows **Restart** and **Stop**. **Stop** sends the command Ctrl-C and waits for it to exit. If it has not exited after about six seconds, Workroom force-quits it.

The command runs in its own terminal tab, in your login shell, at the workroom's directory. The pane footer of that tab shows the run's state. If a run ends or fails while you are looking at another tab or workroom, a toast tells you. Run commands stop when you quit Workroom.

## Quick Terminal

The Quick Terminal is a plain shell in your home folder, in a small window of its own. It is not part of any workroom.

- Press <kbd>⌥§</kbd> from any app to show it, and press it again to hide it. Hiding keeps the shell and its scrollback.
- You can also open it from **File ▸ Quick Terminal** or the Quick Terminal button in the title bar.
- <kbd>⌘W</kbd> or the red button closes it and ends its shell. The next time you open it, you get a new shell.

The <kbd>⌥§</kbd> hotkey is on while **Settings ▸ General ▸ Global show/hide hotkey (⌘§)** is on. The same switch controls the <kbd>⌘§</kbd> show and hide hotkey. See [Settings](settings.md#general) and [Splits and windows](splits-and-windows.md#show-or-hide-workroom-from-anywhere).
