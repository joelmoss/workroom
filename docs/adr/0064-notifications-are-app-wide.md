# Notifications are app-wide, and the Quick Terminal's terminals are ordinary ones

Decided 2026-11-04 (owner, triage of #573). Reverses the per-window notifications of #70.

The app keeps one list of notifications, not one per window. Every surface shows that one list and one count: each window's sidebar list and bell, the unread dots, the menu-bar item and its popover, the Dock badge, and toasts, which show in the front window.

Why: each window kept its own notifications only because #70 split everything a window shows, and nothing else depended on it. The split cost more than it gave:

- The menu-bar popover counted every window's notifications but listed only the last-active window's.
- The same workroom could show an unread dot in one window and none in another.
- A toast for a pane in a window behind the one in use was effectively invisible.
- The Quick Terminal, which belongs to no window, had nowhere to put its notifications.

Opening a notification goes to the pane wherever it lives: the window that has it is raised and the pane focused, and a Quick Terminal pane slides the Quick Terminal in. When no window has the pane any more, the workroom opens in the front window if it still exists. A window's notifications go when it closes, so the list never holds rows that open nothing. There is one count everywhere: unread notifications plus the requests waiting for you, which the bell now counts the same way as the Dock badge and the menu bar.

The Quick Terminal's terminals are ordinary terminals that are not kept across a quit. They differ from a workroom's only in that, so they get every notification a workroom terminal gets, including "needs you" and "finished", which come from workroomd sessions. Its panes therefore run in workroomd sessions too, ended when the pane or the Quick Terminal closes and when the app quits, and never restored. They are marked as the Quick Terminal's, so a crash or force quit, which skips that cleanup, can't leave their shells running unseen: the next launch ends any it finds. This replaces the sessionless Quick Terminal of #571.

Rejected: registering the Quick Terminal in `WindowRegistry` as one of its windows. Its notifications would have joined the window sums, but so would session save, window cycling, the quick switcher and run-command ownership, which read the same list of windows' stores. One shared notification list needs nothing registered. (The Quick Terminal had a store of its own then; since 2026-11-07 a `QuickTerminalHost` hosts its panes, and it is still no registered window.)

Rejected: showing the Quick Terminal's notifications in every window's list while keeping workroom ones per window. It would have been a rule no other notification followed.
