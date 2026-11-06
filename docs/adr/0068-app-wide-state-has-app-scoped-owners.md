# What is the same in every window has one app-scoped owner, and a window keeps only what is its own

Decided 2026-11-05 (owner, architecture cleanup plan, decision D1). Recorded with step 2.4; steps 2.3 and 2.5 build the rest.

`AppStore` is one window's state: its selection, terminals, splits, history and modals. What every window shows the same way, and the work that keeps it current, belongs to one `@MainActor` owner for the whole app, which each window's store is handed when it is made (`.shared` in production; a test's `AppStore()` gets a fresh one). Views take an owner from the environment like any other environment object. An owner holds no `AppStore`. Where it needs a window to do something (bring a run's window forward, settle what the window caches from a status), the window registers a closure with it, and the owner calls those closures synchronously on the main actor, so no window can miss one.

The owners:

- `ProjectStore`: the project list, the creates and deletes in flight, and the saved session (issue #70).
- `RunCommands` (step 2.3): each project's run config, which window runs a workroom's command, and the quit and delete checks that span every window. A run itself stays in the window whose tab it is in, because two windows can show one workroom with tabs of their own (#444 Q12).
- `VCSStatusService` (step 2.4): every workroom's VCS and CI status, the sweep that refreshes it, `gh`'s availability, and the commits and writes in flight against each project. Only one sweep runs in the app: a sweep started from any window replaces the one in flight, as one started in the same window always did. The probes that follow a window's selection (the debounced selection refresh, the selected workroom's file watch) stay with the window. Every merged result settles every window's caches, not just the window whose lane produced it.
- `WorkroomLifecycle` (step 2.5): creating and deleting workrooms, whose effects reach each window as events instead of one window's store looping over its siblings (`affectedStores`), with the process-wide statics that hang off `AppStore` today.

Rejected: keeping that state per window and fanning changes out over a notification bus. Every rule about what spans windows would live in each subscriber, which is the split ownership this replaces. Rejected: adding these to `ProjectStore`. It would grow back into the object `AppStore` was, with four contexts in one type. Rejected: registering the Quick Terminal's store with the owners' window lists. ADR 0064's reasons still hold; the Quick Terminal builds its own store with its own owners, as before.

Source: [`docs/designs/architecture-cleanup-2026-11.md`](../designs/architecture-cleanup-2026-11.md) (decision D1, steps 2.3 to 2.5), [`docs/designs/architecture-cleanup-2026-11/review-appshell.md`](../designs/architecture-cleanup-2026-11/review-appshell.md) (C3), [`macapp/WorkroomApp/Core/Terminal/RunCommands.swift`](../../macapp/WorkroomApp/Core/Terminal/RunCommands.swift), [`macapp/WorkroomApp/Core/VersionControl/VCSStatusService.swift`](../../macapp/WorkroomApp/Core/VersionControl/VCSStatusService.swift).
