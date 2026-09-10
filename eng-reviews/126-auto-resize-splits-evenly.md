---
type: concept
title: 'Eng Review: auto-resize splits evenly (workroom #126)'
ingested_via: put_page
ingested_at: '2026-09-10T20:16:05.341Z'
source_kind: put_page
tags:
  - '126'
  - eng-review
  - splits
  - workroom
---

Plan reviewed 2026-09-10. Verdict ENG CLEARED, 0 unresolved.

Key calls:
- Gate auto-even by INTENT at the semantic entry points (splitFocusedPane, closeTab,
  extractFromSplit, removeWorkroomSplitMember, prune sweep, and the two insert sites behind their
  existing addsAMember / workroomSplitWouldAddMember predicates). A leaf-count delta was the first
  design and is wrong: insertWorkroomSplit:197 calls detachFromSplitGroup before its own insert, so
  hooking that helper double-evens a same-group rearrange.
- Restore stays unhooked. SessionSnapshot.materializeNode:280-281 collapses a dead leaf keeping the
  survivor's ratios, so a workroom deleted while the app was closed can restore lopsided. Accepted:
  persisted layout is sacred.
- Prune-then-even shared with the View menu action, at the insert site only: removeWorkroomSplitMember
  reads its survivor before the edit, so a pruning dissolve there could orphan the selection.
- Three adjacent fixes pulled in: group-aware split floor (fits/canInsertWorkroomSplit ask about the
  anchor pane, wrong once space is redistributed), skip evening when PaneTreeView.lengths' per-axis
  clamp would defeat it (measured: 800pt usable, root 1/3, A clamps 300 vs B/C 496), and divider
  re-latch (both dividers latch startRatio and equalized() preserves node ids).
- Pref kept as the issue asks (Appearance toggle, default on), read through an injected closure per
  store rather than Defaults, because parallel test workers wipe the domain cross-process.

Outside voice: codex aborted on an account usage limit mid-pass; Claude subagent fallback produced
9 findings, 3 folded into the plan and 3 promoted to build-now work.
