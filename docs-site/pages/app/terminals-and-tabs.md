---
title: Terminals and tabs
description: Use Workroom's terminals and tabs, open file paths in your editor, find text, run a project command and use the Quick Terminal.
---

Every workroom opens with a real terminal in its directory. This page covers opening and managing terminals and tabs, the Run command, the Quick Terminal and what to know about shell integration.

## Terminals

Terminals are drawn by [libghostty](https://ghostty.org), the engine behind the Ghostty terminal. Select a workroom, and its terminal is already in the right directory. A workroom keeps its terminals running while you work in another one, so a dev server, a build or a coding agent is as you left it when you come back.

While a program in a terminal reports that it is working, such as a coding agent, its tab shows a moving underline and its sidebar row a busy mark, so you can see what is busy without switching to it.

## Tabs

A workroom can hold as many terminals as you like. They sit in a tab strip that you can reorder by dragging. A tab names itself after the running command. When the command ends it goes back to its own name, such as **Terminal 1**, unless your shell sets a title of its own, such as the working directory.

For long titles, the pane's title bar provides more room than the tab. Hover over the pane title to read it in full.

A workroom or a project's root with two or more terminals can list them under its row in the sidebar. Hover over the row and click the arrow that takes the place of its icon to show them or fold them away. Nightly only: or right-click the row and choose **Expand** or **Collapse**, which VoiceOver also offers as an action on the row. A click anywhere on the row opens it and shows its terminals, and a click on it while they show folds them away. While its terminals are listed, the row shows no marks or controls of its own: each terminal's row shows its own.

### Terminal names {nightly}

A terminal with no name of yours, whose program sets no title, is named after the program running in it and the folder it is in, such as **zsh ~/dev/workroom**, **vim ~/dev/workroom/macapp** or **zsh ~**. That goes for every terminal: in a workroom, standalone, in a group or in the Quick Terminal. The folder is shown in full, with your home folder as **~**, and the name follows the terminal as you `cd` and as programs start and end. Terminals in the same folder share a name; nothing numbers them apart. In tabs, title bars and the sidebar the program stands out and the folder is faded. When a tab or row is too narrow, the folder gives way first and is cut in the middle, so the program and the end of the folder stay in view. A name you give a terminal, or a title its program sets, shows instead.

| To do this | Use |
| --- | --- |
| Open a new terminal | <kbd>⌘T</kbd>, or the new-terminal button in the tab strip |
| Open a terminal with no project | Nightly only. <kbd>⌥⌘T</kbd> (**File ▸ New Standalone Terminal**) |
| Rename a terminal | Nightly only. Right-click its tab or its row in the sidebar and choose **Rename…** |
| Focus tab 1 to 9, left to right | <kbd>⌘1</kbd> to <kbd>⌘9</kbd> |
| Next or previous terminal tab | <kbd>⌥⌘→</kbd> and <kbd>⌥⌘←</kbd> |
| Flip to the pane you used last | <kbd>⌃Tab</kbd> (**Go ▸ Last-Used Pane**) |
| Close the tab | <kbd>⌘W</kbd> (**File ▸ Close Tab**), or hover over the tab and click its **✕** <!-- stable --> |
| Scroll to the top or bottom | <kbd>⌘↑</kbd> and <kbd>⌘↓</kbd> |

### Terminals with no project {nightly}

A standalone terminal belongs to no project. It has its own tab in the title bar and its own row in the sidebar's **Open Tabs** view (see [The Open Tabs view](projects.md#the-open-tabs-view)), with a terminal icon and its name. Press <kbd>⌥⌘T</kbd> from anywhere, or <kbd>⌘T</kbd> when a project's row or nothing is selected, or choose **New Terminal** from the **+** at the top of the sidebar while it shows **Open Tabs**. <kbd>⌘T</kbd> on a standalone terminal opens another one. A standalone terminal is one terminal: it starts in the **New terminals open in** folder, comes back after a quit or a crash like a workroom's terminals, and has no run command. Nightly only: its inspector follows the folder the terminal is in, with that folder's repository, and a terminal group's follows its focused terminal. See [Terminals and the inspector](inspector.md#terminals-and-the-inspector). The Quick Terminal has no inspector. A window with no projects shows the **Open Tabs** view too, so you can use Workroom for terminals alone. A standalone terminal or group is listed there only while it has a tab in the window.

A terminal in the **Open Tabs** view is named like any other, after its program and folder, such as **zsh ~** (see **Terminal names** above).

Select a standalone terminal that another window holds, and that window comes forward. Closing a window closes its standalone terminals, and asks first when it has any.

When you close the terminal you're in and its row goes with it, because it was a standalone terminal or the last terminal of a group, the window goes back to where you were before. That is the last place you selected in that window that still has a terminal open, a workroom's included, so you can type straight away. If there isn't one, the nearest row above it in the **Open Tabs** view that has a terminal in this window is selected, else the nearest one below. Closing a terminal in a group that has others left stays in the group, on the tab beside it.

#### Rename a terminal

Any terminal can have a name of its own, in a workroom, a group or on its own. Right-click its tab or its row in the sidebar and choose **Rename…**. On a row, the name is edited in place, as a terminal group's is: press <kbd>Return</kbd> or click away to keep it, or <kbd>Esc</kbd> to leave it as it was. From a tab, a sheet asks for it. The name shows on the tab, the pane's title bar and the row, and it comes back after a quit. Leave the name empty to show the title the program sets again.

Nightly only: a terminal's name is also its session's label, so it is one name everywhere. Every Mac showing the same terminal shows the name you give it, and scripts and coding agents see it too: `workroom sessions` lists it, and `workroom send`, `workroom close` and the other terminal commands accept it as the terminal to act on. A name set by a script, with `workroom new --title` or the terminal API's `session.label`, shows on the tab, and clearing it there shows the default name again. A Run tab is named **Run** until you rename it. A terminal group's name is the app's own and isn't shared.

#### Terminal groups

A terminal group keeps several terminals with no project together. A window selects it and uses it as it does a workroom, with no branch or worktree behind it; the header above its terminals shows its name. It has one tab in the title bar, with a group icon and its name, and the usual tab strip underneath: <kbd>⌘T</kbd>, <kbd>⌘W</kbd>, splits and <kbd>⌘1</kbd> to <kbd>⌘9</kbd> work inside it as in a workroom. Each window keeps its own terminals in a group. Its row in the **Open Tabs** view lists them under it. Hover the row and click the arrow that takes the place of its icon, or right-click the row and choose **Collapse** or **Expand**, to fold them away or show them again. Selecting the group unfolds it. VoiceOver offers the same as an action on the row. Drag rows to reorder them, as you reorder the title-bar tabs.

A group is named or unnamed:

- **Unnamed.** Split a standalone terminal with <kbd>⌘D</kbd> or <kbd>⇧⌘D</kbd>, and it and the new terminal become an unnamed group in its place. It's numbered, such as **Group 1** or **Group 2**, and keeps its number while it lasts. When one terminal is left in it, counting every window, the group goes and that terminal is standalone again. A split followed by closing one half gets you back where you started.
- **Named.** Choose **New Terminal Group…** from the **+** in the **Open Tabs** view, or in **Move to…**, and give it a name. Dragging terminals together makes one too (see [Move a terminal](#move-a-terminal)): Workroom asks for its name first, and **Cancel** leaves the terminals as they were. A named group stays while it has a terminal in any window, and comes back after a quit. Right-click its row and choose **Rename…** to change the name. Clearing the name makes it unnamed, and it then goes when one terminal is left.

Either kind goes when its last terminal does, counting every window: when you close it, move it elsewhere, or close the window that holds it. Workroom doesn't ask about the group. Quitting keeps every group, and its terminals come back when Workroom opens. The **Quick Terminal** group is the exception: it is never deleted, and its panel just hides when its last terminal closes.

Right-click a terminal group's row for **New Terminal in** and the group's name (**New Terminal in Group 1** for an unnamed one), **Rename…**, **Set Starting Folder…** (otherwise its terminals start in **New terminals open in**) and **Delete**, beside **Expand** or **Collapse** and the tab's own items such as **Close**. Deleting a group keeps its terminals open, each as a standalone terminal in its place, and asks first when it has any.

Right-click a terminal group's or a standalone terminal's tab in the title bar for the same items as its row, beside the tab's own, such as **Close**. A standalone terminal's row has **Rename…**, **Move to…**, **Pop Out** and **Close**. **Rename…** edits the name on the row, or asks in a sheet while the sidebar is hidden or shows **Projects**. Run, Restart and Stop belong to a project's run command, so these tabs don't offer them.

#### Move a terminal

Right-click a terminal's tab, a standalone terminal's row in the **Open Tabs** view or the terminal itself and choose **Move to…**, or use the move button in its pane's title bar. It lists **Standalone Terminal**, **Quick Terminal**, your terminal groups, **New Terminal Group…**, and every workroom that is open in a window, written *project / workroom*. A checkmark marks where the terminal is now. The terminal moves still running, with its scrollback.

You can also drag terminals onto each other. One set of rules covers every drag, wherever it starts and wherever you let go.

What you can drag:

- A terminal: its tab in the tab strip, its pane's title bar, or its row in the sidebar (under a group, the Quick Terminal or a workroom).
- A standalone terminal: its row or its title-bar tab.
- A terminal group, meaning all its terminals in order: its row, its title-bar tab, or its title bar above its panes.

A workroom's row or tab doesn't take part. Dragging one reorders, splits the window or moves the workroom to another window, as before.

Where you can let go, and what happens:

- **A group, a workroom or the Quick Terminal** (its row, its title-bar tab or its title bar): the terminals join it at the end. A folded group's row takes them anywhere below its top edge, except from a terminal's row in the **Open Tabs** view that can become standalone, which joins only over a row's middle (see **Between rows in the Open Tabs view** below).
- **A standalone terminal** (its row in the **Open Tabs** view or its tab): Workroom asks you to name a new group, and the two become that group in the standalone terminal's place. **Cancel** drops nothing. If you dragged a group, the standalone terminal joins it at the end instead, and the group keeps its name.
- **A terminal** (its tab in the tab strip, or its row in the sidebar): the terminals join its group or workroom in that place. On a tab, the half you let go over decides whether they land before or after it. On a row, or between two of a group's terminals' rows, they land above it.
- **The Open tab** at the top of the sidebar: a terminal becomes standalone. Nightly only: rest a drag on the **Projects** tab for a moment and the sidebar shows the project tree, so you can drop on a workroom's row there, and the same on **Open Tabs** to get back. A drag that starts on a terminal's row in the project tree doesn't switch.
- **The title bar's empty space** (between or after its tabs, not on one): a terminal becomes standalone, its tab in the title bar where you let go. A standalone terminal's own terminal only moves its tab there.
- Nightly only: **Between rows in the Open Tabs view**, outside the terminal's own group or workroom: a terminal's row dragged out from under its group or workroom opens a gap between the other rows as you drag. Let go in the gap and the terminal becomes standalone there, still running, its tab in the same place in the title bar. Above the first row or below the last works too. Over another row, only its middle joins it; nearer its top or bottom edge the gap opens above or below it. Over its own group's or workroom's rows it reorders them, except over the top half of the group's or workroom's own row, which puts the gap above it.
- Nightly only: **Among another group's terminals in the Open Tabs view**: over the terminals' rows of a group or workroom that can take it, the rows slide apart to open the gap there instead of showing a line. Let go in the gap and the terminal joins that group in that place, after its last terminal included. The group's own row works as yours does: its middle joins it at the end, the lower edge opens the gap above its first terminal, and the top edge puts the gap above the group. Just under a group's last terminal, the gap is that group's while you came from its terminals, and between rows once you have reached the next row's top edge.
- Nightly only: **A tab from the tab strip or the title bar, or a pane's title bar, dragged into the Open Tabs view** lifts its own row there, as if you had dragged that row: the row's own image follows the pointer over the list, its place closes, and the rows open the same gaps, with the same drops. A tab whose group or workroom is folded opens a gap under that row. Back out of the list, the drag shows what it showed before.

The Quick Terminal's tabs take a drag from any window while its panel is showing: drag a terminal, a standalone terminal or a group over one of its tabs and let go, and the terminals join the Quick Terminal in that place, as on a window's tab. The panel stays up and in front while you drag, and slides away when you let go anywhere else.

While you drag, the place it will go is highlighted, with a line where the terminals will land (in the **Open Tabs** view, a gap). Anywhere it can't go shows no highlight, and letting go there does nothing. Every drag inside the window carries the same label with the dragged item's name next to the pointer.

Edges and gaps keep their meaning. Let a row go between the **Open Tabs** view's own rows and it reorders them: the rows slide apart to show the gap it will land in. Let a title-bar tab go near another's edge and it reorders the tabs. Dragging a tab along its own strip reorders it, and onto a pane's edge splits it, as before.

Whichever way you drag, the terminal keeps running, with its scrollback. A group left with no terminals is deleted. A terminal that runs on a remote host can't become standalone or join a group, and nothing can move into a remote workroom, because the shell runs where it started.

**File ▸ Close Other Tabs** and **File ▸ Close All Tabs** close several at once. Closing a terminal ends its shell and anything running in it. When a process is still running, Workroom asks first. This is on by default. Turn it off with **Settings ▸ Terminal ▸ Confirm before closing a terminal**, **File ▸ Confirm Before Closing a Terminal**, or **Don't ask me again** in the prompt.

Right-click a tab for **Split Right**, **Split Left**, **Split Down**, **Split Up**, **Move to New Window** and **Close**. See [Splits and windows](splits-and-windows.md). Right-click inside the terminal for **Paste** and the same split, window and close commands, plus **New Terminal**.

Nightly only: a terminal you pop out into a window of its own, with **Move to New Window** or **Pop Out**, keeps its tab and its pane. Its tab shows a pop-out icon before its dimmed name, and its pane says it is open in another window, with **Go to Window** and **Pull Back Here**. **Pull Back Here** puts it back in the same pane. Closing its tab closes the terminal and its window. See [Its place in the main window](splits-and-windows.md#its-place-in-the-main-window).

## Find text

Press <kbd>⌘F</kbd> to search the focused terminal's scrollback. <kbd>⌘G</kbd> goes to the next match and <kbd>⇧⌘G</kbd> to the previous one. Press <kbd>Esc</kbd> to close the find bar. The same keys search a file you have open in a pane.

## Copy and paste

With **Copy on select** on, anything you select in a terminal is copied to the clipboard straight away. It is on by default. Switch it in **Settings ▸ Terminal ▸ Copy on select** or **Edit ▸ Copy on Select**.

## When something else types into a terminal {nightly}

A coding agent or a script can type into a terminal with `workroom send`, for example a Claude in one tab typing a command into the tab beside it. Whenever that happens, the terminal shows who is typing in a small marker at the top, such as **Claude · tab 2**. The marker shows the agent's logo, or a terminal symbol for any other program, and the tab it is typing from: its place in its workroom's tab strip, the one <kbd>⌘2</kbd> selects, with the workroom's name when it is another workroom's. It reads **Outside Workroom** for a script run outside any Workroom terminal.

The marker fades out 3 seconds after the last keystroke. Hover over it to read who is typing, from which tab, into this terminal. When several are typing at once, it names the first and counts the others (**Claude · tab 2 +1**), and its tooltip names them all. It never takes a click or the keyboard from the terminal, and it can't be turned off, so typing you didn't do is never invisible.

## Open file paths in your editor

<kbd>⌘</kbd>-click a file path in a terminal to open that file in your editor. It works on paths that point at a real file, including relative paths, and on `file:line:column` forms. VS Code, Zed and Xcode open the file at that line.

Choose the editor in **Settings ▸ Terminal ▸ Open file paths in**. It lists **Default App** and whichever of Visual Studio Code, Zed and Xcode you have installed. **Default App** opens the file as Finder would.

A <kbd>⌘</kbd>-click on anything else goes to the terminal as an ordinary click.

To open the whole workroom, use **Room ▸ Open in** your editor, for example **Open in Zed** (<kbd>⇧⌘O</kbd>), or the editor button in the workroom's title bar. Its small arrow lets you pick a different editor. **Room ▸ Reveal in Finder** shows the workroom's folder in Finder. Click the folder path in a pane's footer to copy it or reveal it.

The editor button may briefly show a generic app symbol while its icon loads. The button still opens your editor immediately.

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

A terminal's shell is held by a background helper, not by its tab. That is why terminals keep running when you quit Workroom, and reattach when you open it again. Closing a terminal ends it. Run commands are kept too, unless you choose to stop them when you quit (see [Quitting with a run going](#quitting-with-a-run-going)). Nightly only: standalone terminals, terminal groups and the Quick Terminal's terminals are kept in the same way, and reattach when you open Workroom again.

> [!NOTE]
> Before Workroom 3.0 this was a setting named **Persist sessions**. It is gone, and terminals always survive a quit.

### Images

Programs that use the Kitty graphics protocol, such as `kitten icat`, work in local and remote terminals. An image on screen comes back when you reopen Workroom, when a remote terminal reconnects, and after a background update. It follows the text, so a large image can take a moment on a slow connection. If its top has scrolled off, the part still on screen comes back.

These images don't come back:

- Images in scrollback.
- Images behind a full-screen program.
- Images sent by file path, temp file or shared memory, rather than directly.
- Images over 32 MB once decoded. During an update, a very large image that doesn't compress can be lost too.

### Restoring hidden terminals

When you reopen Workroom, visible panes reconnect immediately. Hidden terminal tabs reconnect gradually after the window appears, so restoring many panes leaves room for clicks and typing. Their shells and commands keep running in the background helper throughout.

### Programs that resume after a restart {nightly}

A restart of your Mac, or a crash of the background helper, ends every terminal's shell. When you open Workroom again, a terminal whose program said how to start itself again gets that program back, in the folder it was in, instead of an empty shell, so a coding agent that reports itself carries on its conversation. Once the program has started, the terminal says **Resumed Claude Code**, or **Resumed** and the program's name for any other.

- When you quit the resumed program, the terminal stays open at a shell prompt in that folder.
- The resumed program runs as a job of the terminal's shell, as if you had typed it: ⌃Z suspends it to the prompt, and `fg` brings it back. Its command line never goes into your shell's history.
- If the program can't start, or exits with an error within 5 seconds of starting, the terminal says **Couldn't resume** and the program's name, and leaves you at a shell prompt. Workroom then forgets the program, so it doesn't try again after the next restart.
- If the program hasn't started within a few seconds, the terminal says it's a new terminal, and Workroom forgets the program. If the program starts after all, the terminal says **Resumed**.
- If the program didn't say which folder it was in, it resumes in the terminal's last folder.
- If the folder the program was in is gone, the terminal opens a new shell, as it does for a program that never said how to resume.
- Programs resume in zsh and bash. In any other shell, and in macOS's own `/bin/bash`, the terminal opens a new shell instead.
- Hidden terminal tabs resume as they reconnect, so their marks in the sidebar come back without opening each tab.
- A run tab doesn't resume: it comes back stopped, and ⌘R starts it again.

A program says how to resume over the Program Resume Protocol (OSC 7577). This works in terminals on this Mac.

### Who is attached to a terminal {nightly}

Each tab or split showing a terminal is one of its clients, on this Mac or, for a remote workroom, on another Mac showing the same terminal. A terminal takes the size of the client you last typed or clicked in.

To see who is attached, run `workroom sessions --clients` in any terminal. Under each terminal it lists its clients: the Mac each is on, how long ago it attached, its size, which one the terminal's size follows, and whether it still answers. Scripts can follow clients coming and going with `workroom events --type client.attached,client.detached`. See [workroom sessions](../cli/workroom-sessions.md) and the [terminal API reference](../reference/terminal-api.md#the-client-object).

### Detached sessions

A session can be running in the background with no tab showing it, in any window. When the current workroom has such sessions, a button with a stack icon and a count appears at the right of the pane footer, the strip along the bottom of a pane.

Click it to see **Detached terminals**. Each row shows the terminal's title and its folder, and three buttons:

- **Active tab** attaches the session to the tab you are in. It is off until that tab has a terminal.
- **New tab** opens the session in a new tab.
- **Stop** ends the session and anything running in it.

#### In a remote workroom

A remote workroom's detached sessions are the sessions on its host that no tab shows, on this Mac or on another one. The workroom's run command isn't listed. The list fills in once Workroom is connected to the host and is checked again every 30 seconds, so a session another Mac lets go shows up within half a minute. If the Mac showing a session goes to sleep or loses its network, the session shows up here within about a minute and a half. When that Mac comes back, its tab carries on with the session, unless it was stopped meanwhile. It is empty while the host is asleep, stopped or out of reach. It never wakes or starts the host.

Only the host account that started a session can see it. Each account on a host has its own background helper, and only that account can reach it, so someone signed in to the host as a different user never sees your sessions and can't open or stop them. Anyone who can sign in to the host as you can see them, as they could from a shell.

### Stop all detached terminals

**Settings ▸ Terminal ▸ Stop Detached Terminals…** counts the background terminals that no open tab is attached to, then asks before it stops them and anything running in them.

## Run a command

Set a run command for a project, such as `npm run dev`, and start it in any of its workrooms with one key. See [Projects](projects.md#run-command) for setting it.

| To do this | Use |
| --- | --- |
| Run, or jump to the run if it is already going | <kbd>⌘R</kbd> (**Room ▸ Run**) |
| Restart | <kbd>⌥⌘R</kbd> (**Room ▸ Restart**) |
| Stop | <kbd>⇧⌘R</kbd> (**Room ▸ Stop**) |
| Go to the run terminal | **Room ▸ Go to Run Terminal** |

The workroom's title bar shows **Run** when idle and **Restart** and **Stop** while a run is going. **Stop** sends the command Ctrl-C and waits for it to exit. If it has not exited after about six seconds, Workroom force-quits it.

The command runs in its own terminal tab, in your login shell, at the workroom's directory. The pane footer of that tab shows the run's state. If a run ends or fails while you are looking at another tab or workroom, a toast tells you.
### Stop from the sidebar

Project-root and workroom rows show their run control only while the run command is running. Click it to stop the command. The run terminal's footer immediately shows **Stopping…**, and the run tab and sidebar control show a busy mark until the command stops. Then the sidebar control disappears even if its run terminal stays open, including for a workroom on a host.

### Run from a context menu

Right-click a project row in the sidebar, a workroom, or its Run terminal tab to choose **Run**, **Restart**, or **Stop**. Project-row actions control the project's root directory; workroom and terminal actions control that workroom. **Run** needs a configured command. **Restart** and **Stop** are enabled while the command is running.

### Quitting with a run going

A run command is held by the background helper, as a terminal is, so it can keep running after you quit. The first time you quit with a run going, Workroom asks whether to keep your dev servers running or stop them, and remembers your answer. Change it in **Settings ▸ General ▸ When quitting with dev servers running**: **Ask**, **Keep running** or **Stop**. An update always keeps them running, whatever you chose.

With **Stop**, the tab of each run that quitting stops is closed and does not come back.

When you open Workroom again, every other run's tab comes back where you left it:

- A run that is still going reattaches, with no toast.
- A run you stopped comes back stopped, with its output. Press Run to start it again.
- A run that exited or failed while Workroom was closed comes back stopped, with the toast that says how it ended.
- A run that ended because your Mac or its host restarted comes back stopped, and says so. Nothing starts by itself.

If Workroom's background helper isn't running, the run tab says so and runs nothing. Press Run to try again.

### Idle stopped runs

Stopped Run tabs keep their output and remain ready for Run or Restart.

### Run on a remote workroom

On a remote or container workroom, the run command runs on the workroom's host, in its directory there, in the host user's login shell. Run, Stop and Restart work as they do on your Mac. If a container is stopped, Run and Restart start it first; Stop never does. If a run ends while Workroom is reconnecting to its host, for example because the host restarted, the tab stops and says so: "This run ended while Workroom was reconnecting to its host. Press Run to start it again." A run started on one Mac shows on another that opens the same workroom: pressing Run there shows the run that's going rather than starting a second one. To reach a container's dev server from your Mac, forward its port. See [Port forwarding](../remote/port-forwarding.md).

## Quick Terminal

The Quick Terminal is a window of shells of its own that slides in from the top of the screen, in your home folder unless you choose another starting folder. It is not part of any workroom. Nightly only: it is also the built-in terminal group, which can't be deleted or renamed. Its terminals live in its own panel, so the sidebar's **Open Tabs** view, which lists this window's tabs, has no row for it. Set its starting folder in **Settings ▸ Terminal ▸ Quick Terminal**.

- Press <kbd>⌥§</kbd> (or the shortcut you set) from any app to slide it in, and press it again to slide it away. It also slides away when you click another window or switch apps. Hiding keeps the shell and its scrollback.
- Nightly only: it slides in over the app you're using without bringing Workroom's other windows forward, so it sits alongside that app and takes your typing while the rest of Workroom stays where it was. It opens on the current Space, over a full-screen app too, and opens while Workroom is hidden without showing its windows. Hiding Workroom (<kbd>⌘H</kbd>) slides it away, and <kbd>Esc</kbd> goes to the terminal, not the panel.
- It appears on the screen your pointer is on, centred along the edge until you move it. Drag the empty part of its tab bar or a footer to slide it along the edge, or towards another edge to move it there. It stays against an edge the whole way. Drag its sides to resize it. It keeps its size and place the next time it opens, even after you close it.
- You can also open it with the Quick Terminal button in the title bar. **File ▸ Quick Terminal** opens it too, and Nightly only: while it shows, the menu item slides it away, as the shortcut does.
- Its tabs and panes work as a workroom's do. <kbd>⌘T</kbd> or the **+** opens a tab in the **New terminals open in** folder, and <kbd>⌘1</kbd>–<kbd>⌘9</kbd> pick one. Drag a tab along the tab bar to reorder it, or onto a pane's edge to split it there. <kbd>⌘D</kbd> splits the focused pane to the right and <kbd>⇧⌘D</kbd> below, and <kbd>⌃⌘</kbd> with an arrow key moves between panes. Each pane has its title bar, focus border and footer, with the folder its shell is in and that folder's branch. See [Splits and windows](splits-and-windows.md).
- Its terminals' notifications work as a workroom terminal's do. They go in the notification list as "Quick Terminal", count on the bell, the menu bar and the Dock badge, and show as a toast or a banner. Programs that report status, such as Claude Code and Codex, get the "needs you" and finished-turn alerts too. Opening one slides the Quick Terminal in on that pane. While the Quick Terminal is in front, toasts show in it. Closing it removes its notifications. See [Notifications](notifications.md).
- Its shells run in Workroom's background helper, as a workroom's do. Nightly only: they are kept when you quit, and come back when you open Workroom again, as a workroom's do, whatever happens to the panel. Before then they ended when you closed their pane, closed the Quick Terminal or quit, and never came back. A crash no longer ends them either.
- Nightly only: **Move to…** works on a Quick Terminal pane as on any terminal, and lists the Quick Terminal among the places other terminals can go. Click **Move to…** in the pane's title bar, or right-click its tab or the terminal, and pick a standalone terminal, a group or a workroom. With more than one window open, the workrooms are listed under each window. Dragging works too: drag its tab or title bar out of the panel and drop it on a window. It joins the workroom whose tab or pane you drop it on, or that window's selected one if you drop it anywhere else in the window. From then on it is that workroom's terminal. A workroom on a remote host can't take one. A pane can also pop out to a window of its own with **Move to New Window**, and **Move Back to Main Window** returns it.
- <kbd>⌘W</kbd> closes the focused pane and ends its shell. **Confirm before closing a terminal** applies, as it does in a workroom. A pane whose shell exits stays open until you close it, also as in a workroom. Closing the last tab hides the Quick Terminal. Nightly only: the group outlives its terminals, so the next time you open it you get a new shell. A starting folder set on its row applies to its new terminals, as it does for any terminal group; with none set they start in **New terminals open in**.
- **Settings ▸ Terminal ▸ Quick Terminal** chooses the edge it slides in from, whether it slides away when it loses focus and, Nightly only, its starting folder, which otherwise follows **New terminals open in** in Settings ▸ Terminal. A new folder applies from the next new shell. See [Settings](settings.md#quick-terminal).

The Quick Terminal's global shortcut is <kbd>⌥§</kbd> by default. It can be changed or removed in **Settings ▸ Shortcuts**, as can the <kbd>⌘§</kbd> show and hide shortcut. In the Quick Terminal, the tab and pane keys are the ones you set for workrooms. See [Settings](settings.md#shortcuts) and [Splits and windows](splits-and-windows.md#show-or-hide-workroom-from-anywhere).
