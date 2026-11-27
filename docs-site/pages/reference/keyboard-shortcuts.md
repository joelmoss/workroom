---
title: Keyboard shortcuts
description: Every keyboard shortcut in the Workroom app, and how to change them in Settings ▸ Shortcuts.
---

These are Workroom's default shortcuts. The glyphs are ⌘ Command, ⇧ Shift, ⌥ Option and ⌃ Control. **Settings ▸ Shortcuts** changes them, grouped as below. Open it from **Workroom ▸ Keyboard Shortcuts…** or **Help ▸ Keyboard Shortcuts…**.

## Changing a shortcut

Every Workroom action has a row in **Settings ▸ Shortcuts**, including the ones with no shortcut yet, so you can give any of them one.

- **Record** a shortcut by clicking its keys and pressing the new ones. Press Escape to cancel. A shortcut needs ⌘, ⌥ or ⌃; F1–F12 also work on their own.
- **Reset** puts a changed shortcut back to its default. When another action holds those keys now, Workroom asks first, as recording them would, and **Cancel** changes nothing. When System Settings gives them to another menu item, the row says so and stays as it is. **Remove** leaves the action with no shortcut, and the keys go back to the terminal.
- **Conflicts:** when the keys belong to another action, Workroom asks first. Choosing **Use for …** takes them and leaves the other action with none.
- **Tabs and panes by position:** each terminal tab 1–9, workroom tab 1–9 and pane direction has a shortcut of its own, so you can move just one. The last-used switchers take modifiers plus Tab; holding ⇧ steps back.
- **Terminal programs:** a shortcut without ⌘ takes its keys from terminal programs, and the row says so.
- **Keys you can't record:** standard macOS shortcuts such as ⌘Q, ⌘H, ⌘, and the Edit menu's ⌘C and ⌘V stay as macOS has them.
- **System Settings:** a shortcut set for a Workroom menu item in **System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts**, under Workroom or under All Applications, takes effect over Workroom's own, and its row shows it.
- **Other keyboard layouts:** a shortcut with ⌘ uses the letter the layout types with ⌘ held, so <kbd>⌘T</kbd> is still <kbd>⌘T</kbd> on a Russian or Greek layout.
- **Search** by name, by what an action does, or by its keys ("⌘T", "cmd t"). The record button beside the search field finds the shortcut that holds the keys you press.
- **Restore Defaults** puts every shortcut back.

The two **Global** shortcuts work from any app; every other shortcut works while Workroom is in front. While the Quick Terminal is in front, New Terminal, Close Tab, Split Right, Split Down, Focus Terminal Tab 1–9 and Focus Pane Left, Right, Up and Down act on its own tabs and panes. See [Terminals and tabs](../app/terminals-and-tabs.md#quick-terminal).

<!-- stable -->
## Global

| Action | Keys |
| --- | --- |
| Show/Hide Workroom | <kbd>⌘§</kbd> |
| Quick Terminal | <kbd>⌥§</kbd> |

<!-- stable -->
## Projects & Workrooms

| Action | Keys |
| --- | --- |
| New Workroom… | <kbd>⌘N</kbd> |
| New Workroom (split right) | <kbd>⌥⌘N</kbd> |
| Open Workroom… | <kbd>⌘O</kbd> |
| Open Workroom (split right) | <kbd>⌥⌘O</kbd> |
| Open in Editor | <kbd>⇧⌘O</kbd> |

<!-- stable -->
## Workroom Tabs

| Action | Keys |
| --- | --- |
| Switch to Workroom Tab 1 | <kbd>⌥⌘1</kbd> |
| Switch to Workroom Tab 2 | <kbd>⌥⌘2</kbd> |
| Switch to Workroom Tab 3 | <kbd>⌥⌘3</kbd> |
| Switch to Workroom Tab 4 | <kbd>⌥⌘4</kbd> |
| Switch to Workroom Tab 5 | <kbd>⌥⌘5</kbd> |
| Switch to Workroom Tab 6 | <kbd>⌥⌘6</kbd> |
| Switch to Workroom Tab 7 | <kbd>⌥⌘7</kbd> |
| Switch to Workroom Tab 8 | <kbd>⌥⌘8</kbd> |
| Switch to Workroom Tab 9 | <kbd>⌥⌘9</kbd> |
| Next Workroom Tab | <kbd>⌥⇧⌘→</kbd> |
| Previous Workroom Tab | <kbd>⌥⇧⌘←</kbd> |
| Last-Used Workroom | <kbd>⌥⇥</kbd> |

<!-- stable -->
## Terminal Tabs

| Action | Keys |
| --- | --- |
| New Terminal | <kbd>⌘T</kbd> |
| New Standalone Terminal | <kbd>⌥⌘T</kbd> |
| Close Tab | <kbd>⌘W</kbd> |
| Focus Terminal Tab 1 | <kbd>⌘1</kbd> |
| Focus Terminal Tab 2 | <kbd>⌘2</kbd> |
| Focus Terminal Tab 3 | <kbd>⌘3</kbd> |
| Focus Terminal Tab 4 | <kbd>⌘4</kbd> |
| Focus Terminal Tab 5 | <kbd>⌘5</kbd> |
| Focus Terminal Tab 6 | <kbd>⌘6</kbd> |
| Focus Terminal Tab 7 | <kbd>⌘7</kbd> |
| Focus Terminal Tab 8 | <kbd>⌘8</kbd> |
| Focus Terminal Tab 9 | <kbd>⌘9</kbd> |
| Next Terminal Tab | <kbd>⌥⌘→</kbd> |
| Previous Terminal Tab | <kbd>⌥⌘←</kbd> |

Nightly only: **New Standalone Terminal** opens a terminal that belongs to no project, from anywhere. <kbd>⌘T</kbd> does the same when a project's row or nothing is selected, or when a standalone terminal is. See [Terminals with no project](../app/terminals-and-tabs.md#terminals-with-no-project).

<!-- stable -->
## Panes & Splits

| Action | Keys |
| --- | --- |
| Split Right | <kbd>⌘D</kbd> |
| Split Down | <kbd>⇧⌘D</kbd> |
| Focus Pane Left | <kbd>⌃⌘←</kbd> |
| Focus Pane Right | <kbd>⌃⌘→</kbd> |
| Focus Pane Up | <kbd>⌃⌘↑</kbd> |
| Focus Pane Down | <kbd>⌃⌘↓</kbd> |
| Last-Used Pane | <kbd>⌃⇥</kbd> |
| Move Pane into New Window / Back | <kbd>⌃⌘O</kbd> |

Nightly only: <kbd>⌘D</kbd> and <kbd>⇧⌘D</kbd> on a standalone terminal turn it and the new terminal into an unnamed terminal group. See [Terminal groups](../app/terminals-and-tabs.md#terminal-groups).

<!-- stable -->
## In the Terminal

| Action | Keys |
| --- | --- |
| Find… | <kbd>⌘F</kbd> |
| Find Next | <kbd>⌘G</kbd> |
| Find Previous | <kbd>⇧⌘G</kbd> |
| Scroll to Top | <kbd>⌘↑</kbd> |
| Scroll to Bottom | <kbd>⌘↓</kbd> |

<!-- stable -->
## Run Command

| Action | Keys |
| --- | --- |
| Run | <kbd>⌘R</kbd> |
| Restart | <kbd>⌥⌘R</kbd> |
| Stop | <kbd>⇧⌘R</kbd> |

<!-- stable -->
## Version Control

| Action | Keys |
| --- | --- |
| Commit… | <kbd>⌥⌘↩</kbd> |
| Fetch | <kbd>⌥⇧⌘F</kbd> |
| Push | <kbd>⇧⌘P</kbd> |
| Pull with Rebase | <kbd>⌥⇧⌘P</kbd> |

## Sidebar & Inspector

| Action | Keys |
| --- | --- |
| Show Sidebar (Nightly only) | <kbd>⌃⌘S</kbd> |
| Sidebar: Open (Nightly only) | <kbd>⌃⌘T</kbd> |
| Sidebar: Projects (Nightly only) | <kbd>⌃⌘P</kbd> |
| Show Inspector (Nightly only) | <kbd>⌘B</kbd> |
| Details | <kbd>⌥⌘I</kbd> |
| Changes | <kbd>⌥⌘C</kbd> |
| History | <kbd>⌥⌘Y</kbd> |
| Pull Request | <kbd>⌥⌘P</kbd> |
| Files | <kbd>⌥⌘F</kbd> |

Nightly only: **Sidebar: Open** and **Sidebar: Projects** show the sidebar's two views, from **View ▸ Sidebar**. In the stable release **Show Sidebar** is **Projects** and **Show Inspector** is **Inspector**. See [Open and Projects](../app/projects.md#open-and-projects).

<!-- stable -->
## Navigation & Attention

| Action | Keys |
| --- | --- |
| Back | <kbd>⌘[</kbd> |
| Forward | <kbd>⌘]</kbd> |
| Next Notification | <kbd>⇧⌘N</kbd> |
| Go to Terminal That Needs You | <kbd>⇧⌘M</kbd> |

<!-- stable -->
## Windows

| Action | Keys |
| --- | --- |
| Next Window | <kbd>⌘`</kbd> |
| Previous Window | <kbd>⇧⌘`</kbd> |

<!-- stable -->
## Appearance

| Action | Keys |
| --- | --- |
| Theme… | <kbd>⇧⌘K</kbd> |
| Toggle Light/Dark Mode | <kbd>⇧⌘L</kbd> |

Nightly only: in a theme list, the <kbd>⇧⌘K</kbd> picker or Settings ▸ Themes, <kbd>⌘D</kbd> stars or unstars the theme you're on and <kbd>⌘F</kbd> lists only your favourites. Everywhere else they keep their usual commands, Split Right and Find. See [Favourite themes](../app/settings.md#favourite-themes).

The last-used switchers switch to where you were last, not to the next one in position. See [Details and ports](../app/details-and-ports.md) for the inspector's Details.
