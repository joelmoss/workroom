# The sidebar's Open section mirrors the window's workroom tabs, and the Terminals section is retired

Decided 2026-11-25 (owner, design grilling for #819). Status: accepted. Amends ADR 0077 and ADR 0081: wherever they say the sidebar's Terminals section, read the Open section.

The title bar's workroom tabs are the only way to see everything open in a window, and they truncate and overflow once several workrooms, standalone terminals and terminal groups are open. The sidebar's Terminals section spent the top of the sidebar on standalone terminals and groups alone, so it showed only part of what is open. The Terminals section goes. In its place the sidebar's top pane is an **Open section**: a vertical list of the window's workroom tabs, each row unfolding to its tabs (terminal, diff, file and changeset), the same chips as the detail tab strip.

- **One source of truth.** The section is a read-only view of what the title bar and the detail tab strip already read: the window's displayed workroom tabs in their persisted order, and each target's tabs in pane state order. It keeps no list of its own, so selecting, reordering or closing in either place shows in the other at once. The only new state is which workroom rows are folded, kept per window with its saved layout. The selected row is always unfolded.
- **Visibility mirrors the title bar.** A standalone terminal or terminal group appears only while it has tabs in this window, and leaves when its last tab closes, exactly as its title-bar tab does. Another window's tabs never appear.
- **The Quick Terminal group is not pinned.** It is ordered like any other workroom tab. With nothing open it is absent from the section, and its global shortcut still shows its panel.
- **Closed groups stay reachable through the Open Workroom picker (⌘O)**, which already lists them, and through the Quick Terminal shortcut. Nothing is lost by a group leaving the list.
- **Group management moves into the section.** Group and standalone rows keep the old section's menus, inline rename and drag rules (ADR 0077's rule set): a heading drop makes a terminal standalone, standalone on standalone forms a group, standalone on a group joins it. The model of standalone terminals and groups is unchanged; only its sidebar list goes. The heading's "+" is one pull-down: Open Workroom… (⌘O), New Terminal (⌥⌘T), New Terminal Group….
- **The Projects tree is unchanged**, including its terminal rows under each workroom and root. So are the title-bar tabs and the detail tab strip.

The inspector rule of ADR 0081 holds: a standalone or group row in the Open section selects its target, and the inspector follows that target's focused terminal's folder.

Rejected: keeping the Terminals section beside a new section (two lists of overlapping things, and groups pinned first would disagree with the title bar's order). Rejected: a section with its own list and ordering (two sources of truth that drift; every reorder or close would need syncing). Rejected: keeping empty groups listed so they stay visible (the section would then show more than the title bar, which is the one thing it must not do).
