# Inspector rows stay store-free and Equatable

Rows such as `HistoryRow`, `ChangedFileRow` and `FileTreeRowView` observe nothing: they take plain values and closures. The panel observes `TerminalSessions` once and resolves the focused tab once (`FocusedTabSelection`). `TerminalSessions` republishes as fast as an agent writes output, and with every row holding the store and the sessions, each publish rebuilt every row, a 2000 ms main-thread hang (WORKROOM-2B). Equatable rows mean a title or activity pulse rebuilds none. Invalidation tests pin the rule.

Source: [`macapp/WorkroomApp/Core/FocusedTabSelection.swift`](../../macapp/WorkroomApp/Core/FocusedTabSelection.swift) (header comment), `HistoryRowInvalidationTests`, `ChangedFileRowInvalidationTests` and `FilesPanelInvalidationTests` in `macapp/WorkroomAppTests`.
