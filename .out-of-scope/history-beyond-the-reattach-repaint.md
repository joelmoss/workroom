# History beyond the reattach repaint

A pane that reattaches to a wr-agent session gets the screen plus the newest history that fits the repaint's budget, about 4 MiB (`REPAINT_MAX_BYTES`, `format_tail` in `vcs/crates/wr-agent/src/terminal.rs`). The agent keeps more than that, the app's own 50 MB, but there is no way to page the older part into the app: no paged history over the attach protocol, and no separate history viewer.

## Why this is out of scope

The budget already covers ordinary use. ADR 0051 measured it: a full 50 MB history of short coloured lines (28,809 rows at 200 columns) repaints whole in 2.5 MiB. Only unusually dense output gets cut: about 18,000 rows survive for random text, about 800 for truecolour that changes every cell. Even then the older rows aren't lost, they stay in the agent; they just aren't reachable from a reattached pane.

Paging inside the pane isn't possible. GhosttyKit has no way to insert history above what a surface already shows, so older rows can't be fetched as the user scrolls up in the pane itself.

That leaves a separate app-side history view (#470's re-scoped form): a panel or overlay that fetches older rows from the agent in pages, muxy-style. It would need a new history-page request and reply in the agent protocol, the agent serving row ranges, and a whole new view in the app. The user would scroll to the top of the pane and then switch to a second, lesser view of the same terminal. That's a large feature with second-class UX, to cover a gap only dense output ever reaches.

## If this comes back

If GhosttyKit gains a way to insert history above a surface's top row, paging in the pane itself becomes possible, with no second view: fetch older rows from the agent as the user scrolls past the top of the repainted tail. `format_tail`'s row selection is the natural place to serve a range of rows.

## Prior requests

- #470: "wr-agent: page scrollback to reattaching clients instead of repainting it whole"
