# Terminal events reach the app through one synchronous typed sink, not an AsyncStream

Status: accepted, not yet built. `TerminalSessions` reports to the app through separate closures today. They are to become one `onEvent` callback carrying a `TerminalSessions.Event` enum, delivered on the main actor in the same order as the closures, with no `AsyncStream`. Navigation replay suppresses history recording only within a synchronous scope, and `select` must fire the surface-focused event before the focus change so history records against the right workroom; an asynchronous stream would deliver replay events after the suppression scope closes. The existing `TerminalSessionsTests`, `DetachedPaneTests` and `AppStoreCloseTabsTests` assertions are the regression contract.

Source: the maintainer's architecture cleanup plan (a private planning document, not in this repository), engineering review decision D8 (2026-10-10).
