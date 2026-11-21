# Terminals need no project: standalone terminals and terminal groups survive a quit like any other

Decided 2026-11-19 (owner, design grilling over the prototype on branch `prototype/terminal-groups`, variant B). Status: accepted, not built. Supersedes in part ADR 0064: its rule that the Quick Terminal's terminals are not kept across a quit, and the launch sweep that ends them.

Every terminal is equal, whether or not it belongs to a project. Until now a terminal needed a root or a workroom, or else lived in the Quick Terminal, which ended its shells at quit and had no place in a window. Two new kinds of target remove that: the **standalone terminal**, one terminal with a sidebar row and a workroom tab of its own, and the **terminal group**, a set of terminals that a window selects and uses as it does a workroom, with no branch or worktree behind it. Both run in workroomd sessions on this Mac, start in the folder the user chose (a group can set its own), and reattach after a quit or crash as a workroom's terminals do. They get the same notifications, program status and command-result marks, pop out, appear in the quick switcher, ⌥Tab and navigation history, and move to and from workrooms by Move to… and by drag.

The Quick Terminal becomes the built-in terminal group, which can't be deleted. Its global shortcut slides in a panel that is the only place holding its terminals (its sidebar row slides the panel in too), and those terminals survive a quit like the rest. The panel no longer closes when its last terminal does; it hides, since the group outlives its terminals.

How groups come and go:

- Splitting a standalone terminal (⌘D, ⌘⇧D) turns it and the new terminal into an unnamed terminal group in its place. Dropping one standalone terminal on another does the same. Move to… → New Terminal Group… makes one as well.
- An unnamed group is labelled by its terminals' names, and goes when one terminal is left in it, counted across every window; that terminal becomes standalone again. So a split followed by closing one half gets back exactly where it started.
- Naming a group is what keeps it: a named group stays when it is empty. Clearing the name makes it unnamed again.
- Deleting a group makes its terminals standalone; it asks first when the group has terminals.

Across windows a terminal group behaves as a workroom does: each window keeps its own terminals in it. A standalone terminal is one terminal, so selecting it in a window that doesn't hold it raises the window that does. Closing a window takes its standalone and group terminals with it, as it does a workroom's (ADR 0069), and asks first when it holds a standalone terminal.

Both are this Mac's only. A remote workroom's terminal can't become standalone or join a group, and neither can move into a remote workroom, because the shell runs where it started. Groups and standalone terminals are the app's, kept with its saved layout; the workroom lifecycle commands, whose subject is projects and workrooms, don't know them (the terminal API, #360, does, as a caller's scope). ⌘T opens a standalone terminal when the selection opens none (a project's row, or nothing, including a window with no projects), and New Standalone Terminal (⌥⌘T) opens one from anywhere. Any terminal can be renamed, and the name survives a quit.

Rejected: one shared row and title-bar tab for every ungrouped terminal (prototype variant A), and groups as top-level peers of projects with a two-zone title bar (variant C). The owner wanted each terminal on its own to be a first-class thing in the sidebar and the title bar, not a tab inside a bucket.

Rejected: calling a terminal group a workroom. A workroom is a branch of a project, and its base branch, setup, run commands, pull request, host and inspector all rest on that; a group has none of them, so every workroom feature would have to ask which kind it has.

Rejected: keeping the Quick Terminal a separate place whose terminals end at quit. It would be the one terminal that isn't equal. Rejected: a Quick Terminal panel that shows standalone terminals one at a time. Making it a terminal group reuses a kind of target instead of adding another.

Rejected: ⌘D on a standalone terminal opening a second standalone terminal beside it, or doing nothing. The owner chose a group: splitting is how terminals come together.

Source: [`CONTEXT.md`](../../CONTEXT.md) (Target, Standalone terminal, Terminal group, Terminal name, Quick Terminal), the prototype on branch `prototype/terminal-groups` (`macapp/Prototypes/terminal-groups.prototype.html?variant=B`).
