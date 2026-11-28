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
| **Default project folder** | The folder new projects start in, shown as its full path: where **Clone a repository…** clones to and **Create new directory…** creates in, and where **Choose…** opens in the New Project sheet. Your home folder is the default. **Choose…** picks another, and **Use Home**, shown only then, goes back. See [Add a project](projects.md#add-a-project). |

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
| **Themes** | The family your light theme and dark theme both belong to, or **Custom** when they come from different families. Click it to go to [Themes](#themes). |
| **Diff view** | **Unified** or **Side by Side** for diffs you open from now on. A narrow pane always falls back to unified. |
| **Glass** | Frosts the window: the desktop shows through it, blurred, behind the theme's colours, and the terminals frost with it. A slider from 70% to 100%: lower shows more through, and 100% (the default) is off. The window is opaque in full screen and while **Reduce transparency** is on in macOS's Accessibility settings. |
| **Show tabs in the title bar** | Shows a tab in the title bar for each open workroom, terminal and terminal group. On by default. Off hides them, leaving the open-workroom and **+** buttons; the sidebar's [Open Tabs view](projects.md#the-open-tabs-view) still lists everything open, and the workroom tab shortcuts still switch between them. Right-click the title bar and choose **Show Tabs** to do the same. |
| **Dim unfocused panes** | Shades every pane except the focused one so the active terminal stands out in a split. On by default. |
| **Automatically resize splits evenly** | When you add or close a pane, or drag one to a new place in its split, the panes in its row or column resize to match. With workrooms side by side, every terminal in the window ends up the same size. Off leaves the dividers where you put them. See [Even out a split](splits-and-windows.md#even-out-a-split). |
| **Load author avatars** | Fetches author and reviewer avatars from Gravatar and GitHub. Off shows coloured initials only and makes no network request. |

<kbd>⇧⌘L</kbd> (**View ▸ Light Mode** or **Dark Mode**) flips between light and dark without opening Settings.

## Themes

**Appearance** decides which of your two themes is on screen: the light theme while the appearance is Light, the dark theme while it is Dark. Terminals change with it. The Themes pane has the same **Appearance** switch at the top, beside the name of your theme family, or **Custom** when your two themes come from different families.

Under it, two small Workroom windows show your light theme and your dark theme as the app would look, with the name of each. The one on screen says **On screen**. Click a window to browse themes for that side.

Below the windows, choose what to browse, and search by name:

- **Family** lists the theme families, each as its dark theme beside its light one. Choosing one sets both your light theme and your dark theme.
- **Light** lists only light themes. Choosing one changes only your light theme.
- **Dark** lists only dark themes. Choosing one changes only your dark theme.

Each theme shows a few lines of terminal output in its own colours. Your current choice is outlined and ticked. While browsing the other appearance, such as **Light** while the appearance is Dark, a note says **Applies when the appearance is Light**: your choice is saved, and the screen keeps its theme until the appearance changes.

<kbd>⇧⌘K</kbd> (**View ▸ Theme…**) opens a smaller theme picker from the toolbar, with the same **Family**, **Light** and **Dark** tabs over a search field. It opens on the tab for the appearance that is showing. <kbd>↑</kbd> and <kbd>↓</kbd> apply the theme as you move, and <kbd>Return</kbd> or <kbd>Esc</kbd> closes it.

Your own Ghostty theme files in `~/.config/ghostty/themes` are listed too, each with a **Yours** label. Workroom puts each file with the light or dark themes by its background colour. A file with the same name as a bundled theme replaces it. A file Workroom can't read is not listed.

A family is hidden from **Family** while one of its two themes isn't on its own side, for example when a dark file of yours replaces its light theme. You can still choose its other theme on its own.

If your light theme is missing, or is now a dark theme, Workroom shows **Workroom Light** in its place. If your dark theme is missing, or is now a light theme, it shows **Workroom**. The window for that side says so beside the theme's name. Your choice is kept, so the theme comes back when its file does.

### Favourite themes

Star the themes and families you come back to. Each theme and family has a star at the end of its name: it shows while you point at the theme, and stays filled on a favourite. Click it, or choose **Add to Favourites** from the theme's right-click menu, to star or unstar a theme without choosing it. <kbd>⌘D</kbd> stars or unstars the theme you're on: the highlighted one in the <kbd>⇧⌘K</kbd> picker, or your current choice in the Themes pane. A theme is starred by its name, on whichever side it's on, and a family is starred apart from its themes.

The star at the end of the search field, or <kbd>⌘F</kbd>, lists only your favourites, on whichever of **Family**, **Light** or **Dark** you're browsing, and together with the search. The Themes pane and the <kbd>⇧⌘K</kbd> picker share it, and it stays on until you turn it off. A theme you unstar while only favourites are listed stays in the list until you change tab or search, so you can star it again. With no favourites on a tab, the list says so and offers **Show All Themes**.

A favourite whose theme file goes missing keeps its star, and is listed again when the file comes back.

## Terminal

| Setting | What it does |
| --- | --- |
| **Copy on select** | Copies whatever you select in a terminal to the clipboard. On by default. |
| **Confirm before closing a terminal** | Asks before closing a terminal, because that ends its shell and anything running in it, with no undo. |
| **Open file paths in** | The app that opens a file path you <kbd>⌘</kbd>-click in a terminal: **Default App**, or one of Visual Studio Code, Zed and Xcode if installed. |

### Font and cursor

The top of the Terminal pane shows a few lines of terminal in your theme, set the way your terminals will be, with your cursor. Changes reach every open terminal straight away.

| Setting | What it does |
| --- | --- |
| **Font** | The terminal's font: **JetBrains Mono (Built-in)**, or any monospaced font installed on your Mac. |
| **Weight** | How heavy the text is, from the weights the font has. A variable font offers every step from Thin to Black that it covers. Bold text is drawn heavier still. |
| **Style** | **Normal** or **Italic** for the terminal's text. Text a program makes italic stays italic, and bold text follows the weight and style too. Unavailable for a font with no italic. |
| **Size** | The font size in points, from 6 to 72. 13 by default. |
| **Line height** | The space each line takes, from 0.8 to 2 times the font's own. |
| **Shape** | The cursor's shape: **Automatic**, **Block**, **Bar**, **Underline** or **Hollow Block**. Automatic shows a bar at the shell prompt and a block elsewhere. |
| **Blink** | Makes the cursor blink. On by default. |
| **Restore Defaults** | Puts the font and cursor back as they were. |

Programs such as Vim can still change the cursor while they run. With a chosen shape, the shell no longer switches the cursor to a bar at its prompt. At the prompt, a chosen shape and blinking apply to terminals you open after changing them. Remote workrooms keep a blinking bar at their prompt.

### Report terminal as Ghostty

Off by default. New terminals set `TERM=xterm-256color`, which every Mac, server and container knows, so `top`, `sudo vim` and `ssh` to any server work as they do in Terminal. Programs still see `COLORTERM=truecolor` and `TERM_PROGRAM=ghostty`, so full colour and Ghostty detection are unchanged.

On, new terminals set `TERM=xterm-ghostty`. Programs that look a terminal up by that name, tmux among them, then use what Ghostty adds: full colour without a tmux setting, curly and coloured underlines, and synchronized output. The `xterm-ghostty` entry only exists on this Mac, so macOS's `top`, editors under `sudo`, and `ssh` to a server without the entry stop working. See [`top` says "Error opening terminal: xterm-ghostty"](../help/troubleshooting.md#top-says-error-opening-terminal-xterm-ghostty).

The setting applies to terminals you open after changing it. Remote workrooms don't use this setting. They use `xterm-ghostty` once Workroom has installed its entry on the remote machine, and `xterm-256color` until then.

### Resume programs after a restart

On by default. When your Mac restarts or Workroom's background helper stops unexpectedly, programs that support it, such as Claude Code, come back where they were. A terminal you end yourself, by closing its tab or typing `exit`, doesn't come back. See [Programs that resume after a restart](terminals-and-tabs.md#programs-that-resume-after-a-restart).

While it's on, Workroom keeps a hook in Claude Code's settings that lets a Claude Code conversation come back, and takes it out when you turn it off. See [Carry on a Claude Code conversation after a restart](coding-agents.md#carry-on-a-claude-code-conversation-after-a-restart).

Off, a terminal whose session is gone gets a new shell, and a remote workroom's says it has ended, as they did before programs resumed. Terminals you open while it's off can't say how to resume. One opened while it was on still can, and comes back once you turn it on again. A terminal that got a new shell while it was off doesn't bring its old program back later.

The setting applies to terminals you open after changing it, and to a terminal whose session is gone when it comes back. It's set on each Mac: in a remote workroom, it follows the setting on the Mac whose terminal started the session.

### Stop Detached Terminals…

The **Stop Detached Terminals…** button counts the background terminals that no open tab is attached to and asks before it stops them. The note under it explains that terminals keep running after you quit and reattach when you relaunch, and that run commands do too unless you choose to stop them. See [Terminals and tabs](terminals-and-tabs.md#detached-sessions).

### Quick Terminal

| Setting | What it does |
| --- | --- |
| **Slides in from** | The screen edge the Quick Terminal slides in from: **Top** (the default), **Bottom**, **Left** or **Right**. It sits centred along that edge until you drag it somewhere else. Dragging it to another edge changes this setting too. |
| **Slide away when it loses focus** | Hides the Quick Terminal when you click another window or switch to another app. On by default. Off leaves it up until you press its shortcut. |
| **Starting folder** | The folder the Quick Terminal's new shells start in. **Choose…** picks one, and **Use “New terminals open in”**, shown only then, goes back. Without one it follows [**New terminals open in**](#terminals-with-no-project). |

A Quick Terminal that is only hidden keeps its shells, so a new folder applies from the next new tab. Its global shortcut is <kbd>⌥§</kbd> by default. Change it in [Shortcuts](#shortcuts). See [Terminals and tabs](terminals-and-tabs.md#quick-terminal).

### Terminals with no project

| Setting | What it does |
| --- | --- |
| **New terminals open in** | The folder a new terminal with no project starts in, a standalone terminal's, or a terminal group's or the Quick Terminal's when it has no starting folder of its own, shown as its full path. Your home folder is the default. **Choose…** picks another, and **Use Home**, shown only then, goes back. If the folder is gone, it opens in your home folder. |

## Shortcuts

Every Workroom shortcut, grouped by what it acts on, with the two global shortcuts first: **Show/Hide Workroom** (<kbd>⌘§</kbd>) and **Quick Terminal** (<kbd>⌥§</kbd>), which work from any app. Each row can be recorded, reset to its default or removed, and the search field finds a shortcut by its name, by what it does or by its keys. **Workroom ▸ Keyboard Shortcuts…** and **Help ▸ Keyboard Shortcuts…** open this pane. See [Keyboard shortcuts](../reference/keyboard-shortcuts.md) for the defaults and the rules for recording.

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

### Workroom skill

| Setting | What it does |
| --- | --- |
| **Install the Workroom skill for Claude Code and Codex** | Adds a skill that teaches Claude Code and Codex the `workroom` commands for driving your other terminals to their skill folders, `~/.claude/skills` (or `$CLAUDE_CONFIG_DIR/skills`) and `~/.agents/skills`, on this Mac and on each host, and removes it when turned off. A host gets it, or loses it, after Workroom next connects to it. A line under the setting says when a skill was left alone or failed, on this Mac or a host. Off by default. |

See [Drive terminals from agents and scripts](../guides/drive-terminals-from-agents-and-scripts.md#teach-your-coding-agents).

## Projects

The pane lists your projects. Click one to open its settings, and the back button to return to the list. They are its run command, its base branch and its boxd and exe.dev options. The gear on a project row in the sidebar, and **Project Settings…** in its right-click menu, open this pane on that project. A text field saves when you press <kbd>Return</kbd> or leave it. See [Project settings](projects.md#project-settings).

## Remote Hosts

The pane lists the remote providers: boxd, exe.dev and Railway. Click one to open its page, and the back button to return to the list. Railway's row shows a warning when a create may have left a sandbox behind.

A provider's page holds what Workroom creates each of its new workrooms' hosts with. Railway's page also has **Set Up Railway…**, to sign in, pick a workspace or sign out. Existing workrooms keep the host they were made with. Every provider is listed whether or not you have set it up, and each setting saves as you change it. Each page's **info** link opens [Choose a host's image and size](../remote/overview.md#choose-a-hosts-image-and-size). In a list, the provider's own default is marked **(default)**, and choosing it leaves the choice to the provider. Where the provider doesn't say what its default is, the list shows **Provider default** instead.

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
