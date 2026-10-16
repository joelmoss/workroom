# Scrollback size setting

Workroom has no setting for how much terminal history a pane keeps. App panes keep GhosttyKit's default, 50 MB with no line limit, and wr-agent's shadow terminal keeps the same (`SCROLLBACK_MAX_BYTES`, ADR 0051). Changing it is a code change in both places.

## Why this is out of scope

The setting was proposed to fix a mismatch: the shadow kept less history than the app's pane, so a pane lost history on a relaunch, reconnect or hand-off. That mismatch is gone. The shadow now keeps exactly what the pane keeps, and what it sends back is bounded separately: every repaint, record and hand-off carries the newest history that fits its own budget (`format_tail`). The size of the history no longer decides whether a screen can be sent, so a larger limit can't break a reattach.

What remains is tuning for its own sake, and nobody has asked for it. 50 MB is Ghostty's own default. The one cost ADR 0051 records is memory in an unusual case: history that compresses badly (random base64) keeps about 17 MB per full session in the agent, so about 340 MB for twenty such panes on one host.

A setting is a permanent cost for that: an item in Settings, a new field in the attach request, the value carried through a hand-off so an upgraded agent doesn't reset it, a fallback for older agents that ignore the field, and the rule that a change applies only to new terminals.

## If this comes back

Reopen it on evidence: a user report of memory pressure from terminal history, or of history running out on a pane. The shape agreed in triage was presets (for example 10, 50 and 200 MB, with 50 MB the default), applying to new terminals only, sent to wr-agent per session in the attach request so local and remote hosts behave the same, and an agent that doesn't know the field keeping 50 MB. The app side is GhosttyKit's scrollback limit in the config `GhosttyApp.loadConfig` builds. Unknown attach keys are already ignored by `AttachRequest::decode`.

## Prior requests

- #471: "One scrollback setting for app panes and the wr-agent shadow"
