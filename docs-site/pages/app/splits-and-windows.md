---
title: Splits and windows
description: Lay out terminals and workrooms side by side, pop a pane out into its own window, and move work between windows.
---

Splits let you see several terminals, or several workrooms, at once. Windows let you spread them across screens. This page shows how to split, move focus, even out the layout, pop a pane into its own window, and show or hide Workroom with a hotkey.

## Two kinds of split

- A terminal split puts several of one workroom's tabs side by side or stacked.
- A workroom split puts several workrooms side by side in one window, each with its own tabs.

Workroom keeps your layout across launches.

## Split a terminal

| To do this | Use |
| --- | --- |
| Split right | <kbd>⌘D</kbd> |
| Split down | <kbd>⇧⌘D</kbd> |
| Split left or up | **View ▸ Split Left** and **View ▸ Split Up** |
| Close the pane | <kbd>⌘W</kbd> |

Each pane's title bar has **Split right** and **Split down** buttons. You can also right-click a tab, or the terminal, and choose a split from the menu.

The new pane opens next to the focused one, with a new terminal in it. To take a tab out of a split without closing it, right-click the tab and choose **Remove from Split**. The tab keeps running.

## Move focus between panes

Click a pane to focus it. From the keyboard, use <kbd>⌃⌘←</kbd>, <kbd>⌃⌘→</kbd>, <kbd>⌃⌘↑</kbd> and <kbd>⌃⌘↓</kbd>. At the edge of a split they wrap around to the pane on the far side.

<kbd>⌃Tab</kbd> flips to the pane you used last. See [Terminals and tabs](terminals-and-tabs.md#tabs).

With **Dim unfocused panes** on, Workroom shades every pane except the focused one. It is on by default. Turn it off in **Settings ▸ Appearance**.

## Split workrooms

Open a second workroom beside the one you are in. Any of these work:

- Press <kbd>⌥⌘O</kbd> (**File ▸ Open Workroom (split right)**) and pick an existing workroom.
- Press <kbd>⌥⌘N</kbd> (**File ▸ New Workroom (split right)**) to create one beside the current one.
- Right-click a workroom in the sidebar and choose **Open (split right)**.
- Drag a workroom from the sidebar onto a pane. A band shows where it will land.

To take a workroom out of the split, right-click its title bar and choose **Remove from Split**, or click the **Remove this workroom from the split** button in the title bar. It keeps running. The **Close all tabs in this workroom** button next to it closes its terminals. See [Workrooms](workrooms.md).

## Even out a split

With **Resize splits evenly automatically** on, Workroom evens out the dividers whenever a pane joins or leaves a split. A third pane then never lands at a quarter of the width. It is on by default. Turn it off in **Settings ▸ Appearance**.

You can even a split out by hand at any time, whatever the setting:

- **View ▸ Resize Splits Evenly** for the focused terminal split.
- **View ▸ Resize Workroom Splits Evenly** for the workrooms side by side.

An item is off when there is no split of that kind on screen.

## Pop a pane out into its own window

Any pane can leave the main window and live in a window of its own. The terminal keeps running. This is useful for a second display or a long-running log.

To pop a pane out:

- Press <kbd>⌃⌘O</kbd> with the pane focused (**Window ▸ Move pane into new window**).
- Click **Move to new window** in the pane's title bar.
- Right-click the tab, or the terminal, and choose **Move to New Window**.
- Drag the pane's title bar, or its tab, out past the edge of the window.

The pane opens in a window named after its terminal, with a pane footer along the bottom.

To put it back, press <kbd>⌃⌘O</kbd> again (**Window ▸ Move back to main window**), click **Move Back** in the window's toolbar, or right-click and choose **Move Back to Main Window**.

> [!WARNING]
> The window's red button and <kbd>⌘W</kbd> close the pane, not only the window, and end its terminal. Workroom asks first if a process is still running. **Move Back** is the way to close the window and keep the terminal.

Workroom restores a popped-out pane to the same place when you relaunch.

## Move a workroom to another window {nightly}

A whole workroom, with all of its terminals, can move to a new window or into another Workroom window.

- Drag a workroom's tab, or its title bar, out of the window. Drop it on another Workroom window to join that window, or anywhere else to open a new one.
- Right-click a workroom and choose **Move to New Window**.
- Use **Room ▸ Move Workroom into New Window**.

A terminal can also move by itself with **Move to New Window** from its tab menu, right-click menu or sidebar row, then **Move Back to Main Window**. A window's only workroom cannot move. More in [Workrooms](workrooms.md#move-a-workroom-to-another-window).

To open an empty window of your own, choose **Window ▸ New Window**.

## Show or hide Workroom from anywhere

<kbd>⌘§</kbd> hides Workroom when it is in front, and brings it back from any other app. It works system-wide. The hotkey is on by default. Turn it off with **Settings ▸ General ▸ Global show/hide hotkey (⌘§)**. See [Settings](settings.md#general).

The same setting controls the Quick Terminal's <kbd>⌥§</kbd> hotkey. See [Terminals and tabs](terminals-and-tabs.md#quick-terminal).
