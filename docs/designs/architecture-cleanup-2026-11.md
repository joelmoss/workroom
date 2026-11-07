# Architecture review and cleanup plan (November 2026)

Status: accepted, 2026-11-05 (decisions D1–D8 below). Reviewed at `65f01f1fa`. Phases 0–3 are built (rows with a "Landed shape" note record where the built code differs from the row), except 3.7, which waits for the shim to retire, and 3.9's `RunCommands` part; Phases 4 and 5 are not.

Since the last cleanup (2026-10-10, Lanes A–C, Go and Rust lanes), 686 commits have added 48k lines and removed 22k. This review asks what a top-tier Swift, Rust and Go architect would complain about, with the goal that people can work on separate parts of the app in parallel.

**The thesis.** The domain model is already good. `CONTEXT.md` names seven contexts, there are 65 ADRs, and the "why" comments are excellent. The physical code does not follow that model. The plan does not invent a new architecture: it makes folders, types, packages and modules match the contexts `CONTEXT.md` already documents, and gives every context an owner who can build and test it without the others.

Evidence for every claim below is in the six area reports in [`architecture-cleanup-2026-11/`](architecture-cleanup-2026-11/): app shell, terminal, VCS and remote, views, Rust, and Go and cross-cutting. Each claim there names a `file:line`, a count or command output, and each report ends with its own open questions. The load-bearing claims were re-checked by hand before this was written: the fixture strings in both installed binaries, `Bundle.main` in `HostDriver.swift:107`, 6e17146de editing both split copies, the three files that assign `onChildExited`, `SWIFT_VERSION "5.0"` on the test targets, zero `.pty()` callers, and the 19 driver downcasts.

## What a top-1% reviewer would say first

1. **"Your god object grew back."** The `AppStore` type spans 13 files and 9,210 lines, with 214 properties and 312 non-private funcs. Its total grew 16% since the cleanup: `AppStore.swift` shrank, but the extensions grew. The extensions are file splits, not boundaries; their own headers say "moved out as is, state stays on `AppStore`". 131 of the 478 macapp commits since 2026-10-10 touched an AppStore file. Creation, run commands and workroom status cannot be worked on in parallel.
2. **"You extracted owners and then hid them."** `ProjectStore`, `ModalState` and `RunCommandController` exist, but `AppStore` re-exposes 53 of their fields as forwarding proxies, and views only ever use the proxies.
3. **"Test scaffolding ships to users."** ADR 0022 says the fixture is wrapped in `#if DEBUG`; it is not. `strings` on the installed stable 2.1.0 binary finds `FixtureVCSWriter` and `uitest-created` strings, and so does the Nightly. Production code holds 52 `isFixture` reads in 17 files outside the fixture itself, and 8 of those files are views.
4. **"The same rule is written twice, and the history proves it."**
   - Split groups live in both `AppStore+WorkroomSplit` and `TerminalSessions` (six pairs of sites). Commits 6e17146de, 856b43f0b and b1ecb7ac8 each edited both copies and both test suites, and the copies have already drifted.
   - SSH create and delete are a fork of the provider path: clone, checkout, rollback and teardown are each written twice.
   - workroomd kills a process tree in four places across two crates. The `wr-vcs-git` copy misses the `setsid` escaper that `vcs.rs` handles.
   - The git environment scrub has 7 keys in one copy and 6 in the other.
5. **"Your plugin architecture is a lie."** The `HostDrivers` capability protocols are good, but the app goes around them: 19 casts to concrete drivers (one in a SwiftUI view), and four parallel provider enums (`Place`, `DriverKey`, `CreationKind`, `HostProvider`). `HostDescriptor.driver` and `.state` are strings, with 13 state literals across 4 files. Adding a provider touches about 12 sites in 6 files, while the code comment says it takes one.
6. **"Hub files absorb every feature."**
   - `TerminalSessions` has 3,211 lines and at least nine jobs, with 8 parallel per-target dictionaries.
   - `GhosttySurfaceView` has 2,412 lines: FFI plus session-attach policy plus reconnect backoff, through 12 `PersistentSessionService.shared` calls.
   - In workroomd, `SessionStore` has 1,150 lines and 51 public fns, and `serve.rs::dispatch` routes all six services.
   - `WorkroomApp.swift` has 1,842 lines, really three files.
   - `RemoteWorkrooms.swift` has 1,719 lines holding two unrelated types.
   - In Go, `workroom.go` has a 976-line `Service`.
7. **"Callbacks fight each other."** The surface has 13 single-slot `on…` closures. `onChildExited` is assigned from `AppStore+RunCommand` (3 sites), `AppStore+WindowMove` (2) and the surface itself, so run commands and window moves overwrite each other's wiring. ADR 0021's single typed sink stops one layer too high.
8. **"Half your tests can't run without the GUI."**
   - The tab model embeds an `NSView` (`TerminalState.view`), and tests build `GhosttySurfaceView` 109 times.
   - About 5k lines of pure code sit in the app target and could be packages today: the local git engine, devcontainer parsing and the port-forward pumps. Their roughly 7k test lines need `make app-test` and the GUI lock.
   - `HostDrivers` reads `Bundle.main`, which pins its boxd and exe.dev tests (1.7k lines) to the app.
   - The app's test targets build in Swift 5 mode (`project.yml:374,395,437`), while the app builds in Swift 6.
9. **"There is no composition root."** Dependencies arrive five ways: init parameters, about 10 settable closures, 11 `*ForTesting` vars, `nonisolated(unsafe)` static seams, and 41 singletons. Cross-window behaviour is one window's store looping over its siblings (`affectedStores`, used at 8 or more sites). Seven process-wide mutable `static var`s hang off the per-window type.
10. **"Your design system is a colour palette."** It has 704 lines, and 11 of 97 view files import it. Views hard-code 267 `.padding` numbers, 103 corner radii and 97 `.font(.system(size:))` calls. `ThemeService.shared` is read 170 times in 63 files. There are 0 `#Preview`s, so no view can be seen without launching the app.
11. **"Flat folders hide the model."** `Core/` holds 156 files and `Views/` holds 97, with no grouping, so none of `CONTEXT.md`'s seven contexts is visible in the tree. "Session" means four different things: daemon pty, saved layout, tab model and detached list.
12. **"Module boundaries in the daemon point the wrong way."** `vcs.rs` calls a CLI subcommand for the login environment, `file.rs` uses `vcs.rs` as its exec library, and `images.rs` borrows `file::base64`. `rpc.rs`'s own rule says services never depend on each other. `pub mod` exists for the integration tests, which turns off rustc's dead-code detection.

What they would praise, and the plan keeps:
- `PaneLayout<Leaf>` and the `HostDriver` capability split.
- `RepositoryLocation` and `RepositoryContext`.
- ADR 0021's typed sink, the `--json` contract goldens and the shared `channel_cases.tsv`.
- The `unsafe` lint floor, `terminal-state` containment, `docs/remote-host-states.md`, and the presenter and model-enum views (`CreationPanePresentation`, `BoxdSetupSheet`).
- The ADR habit.
- Dead code is very rare. Go `unused` reports 0; Rust has one dead method (`Session::pty()`); Swift has two test-only helpers (grep only).

## Decisions (made by the owner, 2026-11-05)

- **D1. App-scoped owner: yes.** Workroom create and delete, the VCS status sweep and run-command ownership move out of the per-window `AppStore` into one app-scoped `@MainActor` model. Windows subscribe to its events (`targetRemoved`, `paneReplaced`) instead of being iterated, and the 7 process-wide mutable statics move into it. No ADR forbids this; ADR 0064's rejection was about the Quick Terminal joining `allStores`. Steps 2.4 and 2.5; record it as an ADR.
- **D2. Tabs app-wide by tab id, layouts per window, after step 3.5** (as revised by eng review D4). Two windows can show the same workroom with separate tabs, and a move into a window that already shows it merges them (#444 Q12, `WorkroomHandOverTests.swift:170`). So the app-wide `TerminalPanes` owns tabs by id (surface, session, live and agent state), and each window keeps its own per-target layout over those ids. A move or merge shifts ids between layouts; per-tab state never travels, and the #444 and #577 hand-off structs shrink to layouts. It waits for `TargetPanes` (3.1) and per-layout `@Observable` (3.5), so that one shared store does not republish every window on every title change (the WORKROOM-2B class). Step 3.9; record it as an ADR.
- **D3. "Saved layout": glossary first, renames staged.** Add **Saved layout** to `CONTEXT.md`: the tabs, splits and windows a Mac restores, kept in `session.json` locally and as the host layout remotely. In Phase 0 (step 0.10), rename `SessionSnapshot` to `SavedLayout`, `SessionStore` to `SavedLayoutStore`, `SessionCoordinator` to `SavedLayoutCoordinator`, `AppStore+Session` to `AppStore+SavedLayout` and `TerminalSessionsStore` to `DetachedSessionList`. `TerminalSessions` becomes `TerminalPanes` when it turns into the app-wide store (D2), so it is renamed only once. `session.json` and its keys keep their names, because they are a stored contract.
- **D4. Withdrawn.** `CONTEXT.md` already has a "Coding agents" context (line 159); the review brief miscounted six.
- **D5. Lock poison: recover everywhere.** One `lock_or_recover` helper recovers (`into_inner`) and logs the poisoning once. The daemon holds live shells, so a panic under a lock must not stop a session draining (see `session.rs:913-920`). A lock whose fields must change together becomes a documented exception, found during the work. Step 1.8.
- **D6. Folders plus a fuller `DesignSystem` now.** Revisit a `WorkroomViews` package after the leaf views take value inputs (4.9).
- **D7. Docs: status lines, plus a split `CONTRIBUTING.md`.** Each design doc gets a status line at the top: live, shipped in #N, or research. `remote-workrooms.md` (41 references, edited 2026-11-04) and `oq8-cross-machine-reattach.md` (13, edited 2026-11-05) are live and stay put. Only the three unreferenced finished docs move to `docs/archive/`: `jev-opportunities.md`, `v3-screencast.md` and `performance-534.md`. `CONTRIBUTING.md`'s Architecture Overview (`:131-401`) and Deployment & Releases (`:539-780`) move to `docs/contributing/architecture.md` and `releasing.md`, and inbound links, including `macapp/AGENTS.md`'s release anchor, are updated in the same commit. `TODOS.md` stays.
- **D8. This plan and its reports are committed** in `docs/designs/`, so that everyone working a step reads the same decisions.

## The plan

There are five phases. Each step is one commit; related steps batch into one PR per workstream. Within a phase the workstreams (**A** app shell, **T** terminal, **R** remote and VCS, **V** views, **D** daemon, **G** Go and repo) do not touch the same files, so they can run in parallel.

Phase 0 is moves only, with no logic change, and every later phase depends on it. Land it in one short, quiet window so in-flight branches rebase once.

### Phase 0: moves and dead code (no behaviour change)

| # | Step | WS | Size | Test churn |
|---|---|---|---|---|
| 0.1 | One shape for both trees: `Core/<Context>/` and `Views/<Context>/`, with contexts `AppShell`, `WorkroomManagement`, `VersionControl`, `Terminal` (today's `Core/Session/` becomes `Core/Terminal/Session/`), `RemoteHosts`, `DaemonConnection`, `CodingAgents` and `Testing`. Keeping model and view apart preserves the layering. An ownership table can name both trees. `project.yml` sources the whole `WorkroomApp` folder (`:99-100`), so the build needs no change. Paths that do need updating: the `Core/Session/` adversarial-review rule in `macapp/AGENTS.md`; `AGENTS.md`; the `docs/macapp/*.md` references; 32 ADRs (ADR 0002 names its four files); `CONTRIBUTING.md`; `curate-release`; the path excludes in `macapp/Scripts/daemon-name_test.sh:32-34`; and 5 `project.yml` comments. Get the list from `grep -rlE 'Core/\|Views/'`. Leave `daemon-protocol_test.sh:26`'s old path alone, because it deliberately looks up a release tag's layout. `Core/SyntaxHighlighting/` splits too: the pure diff files go to `Core/VersionControl/`, the mappers to `Views/VersionControl/`. | A | S | none |
| 0.2 | Split `WorkroomApp.swift` into `App/WorkroomApp.swift`, `AppDelegate.swift`, `KeyEventRouter.swift`, `FocusedValues.swift` and `Menus/WorkroomCommands.swift` | A | S | none |
| 0.3 | Split `RemoteWorkrooms.swift` into `RemoteWorkroomLifecycle.swift` and `RemoteHosts.swift`; split `DaemonPortForwarding.swift` into pumps and `PortForwardingModel` | R | S | none |
| 0.4 | Rename the mis-named files: `ChangesPanel.swift` (which holds `RightInspector`), `TabReorderMath.swift` (five namespaces), and the `WorkroomStatus.swift` basename collision | V | S | none |
| 0.5 | workroomd module tree: `daemon/`, `terminal/` (`session/` split into store, attached, reader, terminate, freeze and refusals), `vcs/`, `host/`, `exec.rs`, `cli/`. Inline `mod tests` become sibling `tests.rs` files, which covers 11.6k of the 29.4k lines. `lib.rs` gets a service-to-module map. Moves only, one PR. | D | M | imports only |
| 0.6 | Make modules `pub(crate)` with a `#[doc(hidden)] pub mod testing` re-export, so rustc reports dead code again. Delete `Session::pty()`. Make `account` and `run` private. Gate the test-only methods behind a `test-support` cargo feature, not `cfg(test)`: integration tests link the library without its `cfg(test)` items, and they call `SessionStore::create` and `replay_bytes` (`tests/program_status.rs:114,284`). Enable the feature through workroomd's own dev-dependency on itself, so `cargo test` and `make vcs-test` need no flag, and check that both feature builds still lint (outside voice OV2). | D | S | imports |
| 0.7 | Split Go `workroom.go` into `create.go`, `delete.go` and `listing.go` (methods stay on `Service`) | G | S | none |
| 0.8 | Fix the stale docs: ADR 0020 (Project and Workroom have moved), ADR 0022 and 0023 status lines, the `SessionSnapshot.swift:36-42` header (contradicts ADR 0058), the `wr-vcs-git/Cargo.toml:2` comment, `lib.rs`'s "Phase 1/2" text, the `gitHardening` "every invocation" comment, the jj-field comment in `DaemonVCSReader.swift:119`, and `curate-release`'s "three in lockstep" | all | S | none |
| 0.9 | Remove the leftovers: the untracked `vcs/crates/wr-agent/`; the test-only `workroomSplitActive` and `createStep(for:)`; and the five jj-era fields the app decodes but never reads (`DaemonVCSReader.swift:144-158`). Dropping those fields is the app-side half of `TODOS.md:376` and the precondition ADR 0007 waits on. It is safe against every daemon, because `JSONDecoder` ignores unknown keys. A decode test pins that: a reply from an older daemon that still carries the fields decodes. | R, A | S | small |
| 0.10 | Saved-layout renames per D3, with the `CONTEXT.md` entry first, after 0.1's moves and in their own commits, so `git log --follow` sees a move and a rename separately | T | S | renames only |

### Phase 1: seams (small, unblock everything after)

| # | Step | WS | Size | ADR |
|---|---|---|---|---|
| 1.1 | `AppServices` (cli, VCS writer, history resolver, remote-create services, trasher, notifier, host-layout store, host sessions, clock), built once in `WorkroomApp.init` as `.live`, with `.fixture` and `UITestFixture.swift` under `#if DEBUG`. The 52 `isFixture` reads collapse into the choice of services. Verify with `strings` on a Release build. | A | M | finish 0022 |
| 1.2 | `HostKind` value in `WorkroomDomain` replaces `Place`, `DriverKey`, `CreationKind` and `HostProvider`; `Runtime` and `Dialect` merge. `HostDescriptor` gets typed read views (`kind`, `lifecycle`) over the lenient strings, following ADR 0014's pattern on the Swift side. | R | M | new |
| 1.3 | Capability protocols in `HostDrivers` (`HostPresenceReporting`, `StartableHostDriver`, `ReconnectingHostDriver`, `OptionedProvisioning`, `RepositoryGranting`) remove the 19 downcasts. One `HostDriverRegistry` becomes the only constructor, replacing six sites with two different `directory:` values. Check that mismatch for a real bug first. | R | M–L | new (provider behaviour through capabilities) |
| 1.4 | One `SurfaceEvent` sink on `GhosttySurfaceView`, set once by `TerminalSessions`. Run-tab child exit becomes a `TerminalSessions.Event`. `AppStore` never touches `surface?.on…`. Regression test: a run tab moved to another window whose child then exits still reports its run status. Today that wiring is the one window moves overwrite. | T | M | extends 0021 |
| 1.5 | `PaneSplitGroups<Leaf>`, `PaneTreeLayout` and `PaneMetrics` move into `WorkroomDomain`, used by both splits. Merge the two test suites' rule tests into one package suite that runs under `swift test`. Share `SplitDivider`, `DropAccent` (whose accent colour has already drifted) and the tab-strip chrome. | T | M | — |
| 1.6 | Typed `TargetID` (encode and decode in `WorkroomDomain`) replaces the pipe string and its four resolvers | T | M | — |
| 1.7 | workroomd `exec` module: git env scrub and pins, bounded capture, `end_tree`, fd flags. `wr-vcs-git` uses it or a shared `git_command`, so `run_bounded` gets the `setsid`-escape kill, with a test like `vcs.rs`'s `exec_kills_a_descendant_that_escaped_the_process_group` for that path. Login environment moves from `cli/run_script` to `shell.rs`. | D | M | — |
| 1.8 | Write the lock order (the graph in the Rust report) as one doc block on the store, recover from poisoning everywhere through one `lock_or_recover` helper that logs once (D5), and document any exception. Poison sticks, so once recovered every later lock sees it again; "logs once" needs a flag (one `AtomicBool` per lock site or a global one), or the log floods. |  D | S–M | — |
| 1.9 | Go typed payload structs replace the `map[string]any` literals in 24 `cmd` files; the goldens stay the oracle. `workroom` returns its own result types, so `cmd` stops importing `vcs`. | G | M | 0013 unchanged |
| 1.10 | `crates/ghostty-vt`: the libghostty sys bindings, a safe wrapper and the bindgen `build.rs`, out of `terminal.rs`. workroomd depends on it optionally, under `terminal-state` (ADR 0010 unchanged). Being a workspace member, it is built by CI's `cargo clippy --workspace` (`ci.yml:155`) and by the workspace docs and tests. Its `build.rs`, bindings and wrapper therefore sit behind the crate's own off-by-default `link` feature, exactly as workroomd's `build.rs` gates `link_ghostty_vt` on `terminal-state` today. Without that feature the crate compiles to nothing and needs no Zig, and `terminal-state` turns on `ghostty-vt/link` (outside voice OV3). `terminal.rs` keeps the shadow policy and holds no `unsafe`; that is 95 of the 229 `unsafe` uses in production code. Comes after the 0.5 module tree, while that code is already moving (eng review D1). `vcs/scripts/build-ghostty-vt.sh`, the `ghostty-vt` CI cache keys (`ci.yml:206,265`) and the `daemon-terminal-state` and Linux musl jobs keep building it; the Linux side is checked with `make vcs-lint-linux`. | D | M | — |

### Phase 2: give state an owner (the parallel-work unlock)

| # | Step | WS | Size | Test refs to redirect |
|---|---|---|---|---|
| 2.1 | Delete the run and project-store forwarding proxies, one owner per commit, and inject the owners into the environment. The 25 modal proxies go in 2.2 instead, so their 100 test references change once, not twice. | A | S–M | 52 / 111 |
| 2.2 | `ActiveModal` enum replaces about 30 `pending*` optionals, their 25 forwarding proxies and the hand-maintained `hasModalPresentation` OR (#451 class) | A, V | M | 100 / 20 files |
| 2.3 | App-scoped `RunCommands` aggregate (D1: run-command ownership is app-wide), made from `RunCommandController` plus `AppStore+RunCommand`, with its own stored state. `RunCommandController.HandOff` goes with it. Base-branch settings move to Workroom management and `branchName` to Version control. Landed shape: `RunCommands` holds the run config, the owner lookup across windows, `HandOff` and the run sessions; per-tab run state stays on each window's `RunCommandController` until 3.9 makes tabs app-wide (two windows on one workroom each hold a run today, #444 Q12, #70). | A | M | 52 / 4 files |
| 2.4 | App-scoped `VCSStatusService` (`AppStore+WorkroomStatus`, ProjectStore's status fields, the sweep). Split `WorkroomStatusResolver` into working status, GitHub (gh) and a git probe. | A, R | M | 111 / 14 files |
| 2.5 | App-scoped `WorkroomLifecycle` (create and delete, `CreationRun`, `RemoteCreateServices` without `AppStore` in its signature). Windows apply its events, `affectedStores` goes, and the 7 statics move here (D1). The per-window `rootBranchWatchers` (`AppStore.swift:914`, one `.git` watch per project per window) move here too, as one per project app-wide. That removes the app half of `TODOS.md:401`; update that entry so it names only the daemon's shared-registry half. Events reach windows as plain synchronous main-actor calls, in ADR 0021's style, so a window cannot miss one. First commit: a characterization test that registers two windows, deletes and creates a workroom in one, and asserts the other window's selection, splits and run state. `MultiWindowTests` has none today, and in tests `affectedStores` is just `[self]`. Landed shape: the flows are `WorkroomLifecycle+Create` and `WorkroomLifecycle+Delete`, each taking the window it was asked from as a `LifecycleWindow` (a protocol `AppStore` conforms to: only that window's services, modals, selection, reload, pane placement, auto-run and local removal); the shared state, the run registry and the events are on `WorkroomLifecycle`. | A | L | 179 / 7 files |
| 2.6 | The remote lifecycle runs over a `Placement` protocol (provisioned host or SSH folder, per ADR 0056), with one shared `cloneAndCheckOut` and one `runTeardown`. The delete flow takes an `onForgotten` callback instead of calling `PortForwardingModel` and `ProgramStatusMonitor` singletons. The `RemoteHosts.shared` seam leak at `:723` goes. Landed shape: a `Placement` (`ProvisionedHostPlacement`, `SSHFolderPlacement`) is what a create makes and undoes (`make`, `unmake`, the clone's `credentialHint`), and `RemoteProvisioning.place` runs make, checkpoint, connect, `cloneAndCheckOut` and the last record over either, undoing the placement on failure; `provision` and `createSSH` are the two ways in, each keeping its own reserve and rollback records. The two deletes keep their own bodies (ADR 0056's folder guard, session ending and last-workroom rule) and share `runTeardown`. `onForgotten` takes a `RemoteWorkrooms.Forgotten` (`.host`, `.workroom`, `.lastWorkroom`) that `WorkroomLifecycle.forgetRemote` hands to the two models. | R | M | setup code only |
| 2.7 | Split `RemoteHosts` into `HostDriverRegistry` and `HostReachability` (connect, backoff, relay). Landed shape: `HostDriverRegistry` took the host records (`keys`), `adopt`, the sweep, `key(for:)`, `environment`, `environment(toDelete:)` with `Deletion` and `deletionKey`, `existingDriver`, `runtimeIsMissing` and `boxdConfiguration`. `HostReachability` took the connect, `ensureConnected` and its backoff, wake, start and selection state, the credential relay, the wake/network link check and a `disconnect` the deletes use. `RemoteHosts` stays as the app-wide root that makes the two together (`shared`, its `registry` and `reachability`), with `adopt` (the registry's, telling reachability which hosts are relayed), `DriverKey` and the folder and CLI statics. The remote deletes and script run take `reachability:`, and a teardown with no fake `run` runs over the delete's own. | R | M | RemoteHostsTests splits |
| 2.8 | workroomd: `terminal/dispatch.rs` comes out of `serve.rs`. `runs`, `screens` and `program_status` observe the store through one hook surface instead of being fields on it. The hooks run synchronously on the session's read thread, never through a queue. Only that thread knows where the client's stream stands, and bytes injected between pty reads must wait for parser ground (learning `pty-reads-split-sequences`, `session.rs` `read_session`). Terminal codecs move to `wr-protocol`. One `RpcClient` for the five copy-pasted test clients. | D | L | low |

After phase 2, creation, run commands, VCS status, remote lifecycle, terminal and daemon each have their own files, stored state and tests. Six people can work in parallel without meeting in `AppStore.swift`.

### Phase 3: break up the terminal hub

| # | Step | WS | Size |
|---|---|---|---|
| 3.1 | A pure `PaneState` value (tabs, order, groups, focus, counter; ids only), held by one `@Observable` `TargetPanes` object per window and target (eng review D4), replaces the 8 parallel dictionaries, so `reap`, hand-off and capture each become one line. The store's target dictionary changes only when a target is added or removed, so views redraw per workroom (eng review D3). Landed shape: 5 of the 8 dictionaries moved (tabs, order, splits, focus, counter). The window measurement caches (`paneRects`, `paneSpace`), `announcedShownSlots` and the tab-keyed activity pulses and detached set stay on the store, since absorbing them would change behaviour. | T | M |
| 3.2 | `TerminalTab` without the `NSView`: session id, cwd and the run flag become stored facts (this ends the `state.x ?? state.view.x` idiom), and a `SurfaceRegistry` owns the views. A new `TerminalModel` package holds `PaneState` and its rules, the `TargetPanes` observable that wraps it, the tab model and capture mapping, tested with `swift test`. Landed shape: `TerminalTab`, `TabContent` and `TerminalState` stay in the app, because they depend on diff, coding-agent and program-status types from other contexts. Only the capture mapping's pure rule moved, as `TerminalLaunch`. A detached pane's status bar keeps its live surface fallback for the cwd. | T | L |
| 3.3 | Pull `PaneLiveState` (cwd, branch, title, tool and agent observers), `ProgramStatusBinding` and `RemotePaneLinks` out of `TerminalSessions`. Landed shape: the three reach tabs through `TerminalTabAccess`, a struct of closures, not a reference to the store. `PaneLiveState` is one object per window keyed by tab. Session restore's coding-agent recovery stays in the store. | T | M |
| 3.4 | `PaneSessionAttachment` out of `GhosttySurfaceView` (attach command and env, reconnect backoff, network re-attach) behind the injected service. The view keeps FFI, input, render and accessibility only. Landed shape: one attachment per surface, owned by the view, with the service injected from the window's store. The cwd, run-surface kind and run refusal stay on the view. The context-menu `keyStore` sends are left for #583. | T | M |
| 3.5 | Move `TerminalSessions` to `@Observable`, per `TargetPanes`, after first replacing the `objectWillChange` dirty hook (`AppStore.swift:996`). The terminal divider gets the workroom divider's live and commit pattern (#139), measured with Instruments before and after. Landed shape: the dirty hook is a `paneWillChange` subject with two listeners (saved layout and the coding-agent recompute). The sessions left the SwiftUI environment; views read `store.terminals`. Both dividers share `PaneLayout.showingDrag`. Hosted invalidation tests (`PaneInvalidationTests`) stand in for the Instruments pass, which is the owner's to run. | T | M |
| 3.6 | One Control codec in `DaemonConnection` (the local and remote clients each have their own today). Rename `DaemonVCSConnection` to `DaemonClient`. VCS reply DTOs move beside the request. `HostID` moves to `WorkroomDomain`. Landed shape: the codec is `DaemonService`, `DaemonEnvelope` and `DaemonControl`, pinned byte for byte against both former encoders. `DaemonControlClient` stays the app's blocking transport. The DTOs live in `DaemonVCSWire.swift`. `HostDrivers` drops its direct `WorkroomVCS` dependency but still reaches it through `DaemonConnection`. | T, R | S–M |
| 3.7 | When the shim retires (TODOS:148), split `PersistentSessionService` into `LocalSessionControl` and `RemoteSessionRegistry` | T | M |
| 3.9 | App-wide tab registry (D2 as revised by eng review D4): `TerminalPanes` owns every tab by id, and each window keeps a per-target `TargetPanes` layout over tab ids. Moves and Q12 merges shift ids between layouts, so `TargetHandOff` shrinks to the layout. `testIntoAWindowShowingTheWorkroomTheTabsJoinItsOwn` and the run-command move tests stay green unchanged. `TerminalSessions` is renamed `TerminalPanes` (D3). `RunCommands` absorbs the per-window run state left on each `RunCommandController` by 2.3. Needs the adversarial review. Landed shape (ADR 0069): the app-wide registry is `TerminalTabs` over `TabRecords`; the per-window store, renamed `TerminalPanes`, keeps window state. The Quick Terminal's tabs join the registry. `TargetHandOff` keeps the detached windows' frames and the coding-agent banners, which belong to the window. Not done: `RunCommands` absorbing the per-window run state. A Q12 merge can briefly hold two run tabs for one target, so that needs a per-(window, target) current-run pointer that moves on a hand-off, and `.tabsRemoved` cannot yet tell a move from a close. | T | L |

### Phase 4: packages and the view layer

| # | Step | WS | Size |
|---|---|---|---|
| 4.1 | `Packages/WorkroomGit`: the four libgit2 files (ADR 0002 keeps its rule; only the paths change), `GitProvider`, `UnifiedDiff` and diff algorithms, `CLIVCSWriter`, `RepositoryWriteGate`, and `GitCommand` (hardening). `VCSProviding`, `VCSWriting` and `RepositoryLocation` move to `WorkroomVCS`. The direct `libgit2` pin moves into this package's `Package.swift` with the same URL and version as SwiftGitX's own dependency, so SwiftPM still sees one package identity (ADR 0002). | R | M |
| 4.2 | `Packages/DevContainer` (config, features, setup), its own package (eng review D2), layered above `HostDrivers`: setup builds `HostDrivers`' `ContainerSpec`, `ImageConfig` and `Mount`. It also depends on `WorkroomVCS` (`FileServiceError`) and `WorkroomSystem`, and the app's `FileProviding` protocol (`Core/FileServices.swift:19`) moves to `WorkroomVCS` first. | R | S–M |
| 4.3 | `HostDrivers` host-setup scripts as `Bundle.module` resources; the boxd and exe.dev driver tests move into the package. Prove that a signed Release `.app` finds the scripts: `Bundle.module` lookups are a known failure in packaged apps. | R | S |
| 4.4 | Port-forward pumps into `DaemonConnection`; `DaemonBootstrap` into `HostDrivers` or `DaemonConnection` | R, T | S |
| 4.5 | `WorkroomCLIError` mapping into `WorkroomDomain`, so `CLIContractTests` runs under `swift test` | R | S |
| 4.6 | `DesignSystem`: `Spacing`, `Radius` and `FontRole` tokens, plus `MessageState`, `WarningHeader`, `Notice`, `SheetFooter` and the row style (24 warning sites, 5 message copies, 11 sheet footers). Add tokens to `docs/macapp/ui.md`. | V | M |
| 4.7 | Theme through `@Environment(\.themeTokens)` instead of 170 `ThemeService.shared` reads. Check the `themeTick` leftovers by running the app before deleting them. | V | M |
| 4.8 | Loaders out of views: `DiffLoader` and `FileContentLoader` (one `LoadState<Content>` instead of three) and `CommitFlow` (`CommitSheet`'s phase machine). Settings stops calling `WorkroomCLI.shared`. | V | M–L |
| 4.9 | Narrow view inputs (read model plus `Actions` struct), leaf views first, each with `#Preview`. A `PaneHost` slice lets the Quick Terminal stop building a whole `AppStore`. | V, A | L, incremental |
| 4.10 | `WorkroomAppTests` to Swift 6 mode; replace the `NSLock` boxes with `Mutex` and the three `onMain` copies with one helper | A | M (error count unmeasured) |

### Phase 5: repo and process

| # | Step | WS | Size |
|---|---|---|---|
| 5.1 | Shared fixture tables for the cross-language twins: login-shell invocation (Go, Swift, Rust), channel raw names (Swift against `channel_cases.tsv`), and the base-branch split (Go and Swift). Do not unify the code (ADR 0005's spirit). | G | S |
| 5.2 | The app stops hard-coding the config path and the `.worktreeinclude` check: `list --json` reports `has_include`, and the path lives in one place | G, R | S |
| 5.3 | `Makefile` uses `include mk/*.mk`; the `_test.sh` invocations become a glob; the CLI builds to `bin/` | G | S–M |
| 5.4 | CI: composite actions for build-app and build-daemon shared by `ci`, `nightly` and `release`; split `ci.yml` (795 lines) by language with path filters | G | M |
| 5.5 | Docs per D7: design-doc status lines, three docs to `docs/archive/`, the `CONTRIBUTING.md` split. Add a `CODEOWNERS`-style ownership table keyed to the new folders, which is what makes the parallel-work goal enforceable. | G | M |

## Order of attack and risk

- **Phase 0 first and fast.** It is mechanical, but it conflicts with every open branch, so pick a quiet day. Moves keep `git log --follow` working; make each one a pure-rename commit.
- **The best payoff early is 1.1, 1.4, 1.5 and 2.1.** Each is small, and each removes a whole bug class: test code in Release, callbacks overwriting each other, split rules drifting, and modals missed by Escape.
- **Steps 2.5, 3.2 and 3.9 are the L steps** with real regression risk: cross-window creation and deletion, tab restore, and window moves. Both touch `Core/Session/` or the routing rules in `macapp/AGENTS.md`, so each needs the independent adversarial reviewer that file requires.
- **New packages** (3.2 `TerminalModel`, 4.1 `WorkroomGit`, 4.2 `DevContainer`) are picked up by `make app-package-test`'s `Packages/*/` glob and CI's `Packages/*/Package.swift` cache key. `macapp/project.yml` lists packages by hand (`:37-51`), though, so each new package adds its entry there in the same commit.
- **Test churn** is the main cost of every rename. The 82k test lines are sized per step above. #514 already audited test value, so this plan does not re-audit.

## Not verified

- **Swift dead code is grep-only.** `periphery` is not installed, and running it builds the app (which re-signs the running Dev app). Run it once before 0.9 if you want proof rather than candidates.
- **Go `deadcode` was not run.** The sandbox blocked the toolchain download, and the unsandboxed run was denied. `golangci-lint unused` reports 0.
- **The Rust results use Homebrew cargo 1.99.1, not CI's 1.96.1.** The Linux build was not checked.
- **The `directory:` mismatch** between driver constructors (1.3), and whether the terminal divider's per-tick store write costs anything measurable (3.5), are open until checked.
- **The Swift 6 error count for the test targets** is unknown until a build.

## Eng review (/plan-eng-review, 2026-11-05)

Target: this file, reviewed at `c1ad66aa4`. The six area reports are its evidence.

### Scope record

Feature answers: D1 kept the ghostty-vt crate and moved it to step 1.10, after the 0.5 module tree ("Keep, move to 1.10"). A proposed lighter review of phases 2–5 was withdrawn and never asked, so every phase gets the full review. Structure: D2, A (original arrangement), reopened once after a false premise was found (DevContainer depends on `HostDrivers`, not only `WorkroomDomain`) and answered A again ("Own package"). Accepted scope: the whole plan, with 1.10 added and 3.8 removed, and three new Swift packages (`WorkroomGit`, `DevContainer`, `TerminalModel`) plus one crate (`ghostty-vt`). Pending remedies: S1.

### Scope Challenge findings

1. S1 [INFORMATIONAL] (confidence: 9/10) plan 3.1 / 3.5. `TargetPanes` is planned as a value in `[TargetID: TargetPanes]` on an `@Observable` store. Observation tracks a stored property as a whole, so reading one target's entry subscribes to the whole dictionary. "`@Observable` per `TargetPanes`" (3.5) then cannot happen as written, and D2's precondition (no republishing every window) would fail. Pending: D3.
2. S2 [INFORMATIONAL] (confidence: 9/10) plan 2.8. The new hook surface must run synchronously on the read thread, because injected bytes must wait for parser ground. Prior learning applied: `pty-reads-split-sequences` (confidence 10/10, from 2026-10-31). Auto-decided under the owner's 10/10 rule: the constraint is added to 2.8.
3. S3 [INFORMATIONAL] (confidence: 7/10) plan 4.3. `Bundle.module` resource lookups fail in some packaged apps (forum and release-note reports). Auto-decided: 4.3 now requires proof in a signed Release `.app`.
4. S4 [INFORMATIONAL] (confidence: 9/10) `AppStore.swift:914` `rootBranchWatchers` is per window. This is the app half of `TODOS.md:401`. Auto-decided: 2.5 moves the watchers to the app-scoped owner, and the TODO is narrowed to the daemon's half.
5. S5 [INFORMATIONAL] (confidence: 9/10) plan 4.1. ADR 0002 requires the direct `libgit2` pin to match SwiftGitX's URL and version. Auto-decided: stated in 4.1.
6. S6 [INFORMATIONAL] (confidence: 10/10) `macapp/project.yml:37-51` lists packages by hand. Auto-decided: noted under "Order of attack".
7. S7 factual corrections (no behaviour change):
   - 52 `isFixture` reads in 17 files, not 54 in 18.
   - 7 mutable statics, not 8.
   - DevContainer's dependencies (D2 reopened).
8. S8 [INFORMATIONAL] (confidence: 9/10) plan 1.8. Poison sticks after recovery, so "logs once" needs a flag. Auto-decided: stated in 1.8.

Reality rows:
- REALITY: premise-table finding 7 premises re-verified by hand; S7 corrected 3 numbers; unverified=4 (the "Not verified" list) plan:9, plan:156
- REALITY: already-done pass `git log 65f01f1fa..origin/master` is empty after fetch
- REALITY: surface-check pass all 10 named `make` targets exist (e.g. Makefile:231 `app-test`, Makefile:78 `vcs-lint`); `include-archive` is cmd/include_archive.go:21
- REALITY: binding-decisions pass no branch decisions recorded; D1–D8 plus eng D1 and D2 bind this plan (plan:48)
- REALITY: numbers finding isFixture 54→52, statics 8→7, re-measured by grep (plan:15, plan:50)
- REALITY: deferred-asks pass no linked issue; the plan's header names none (docs/designs/architecture-cleanup-2026-11.md:3)
- REALITY: pr-count pass no `.gstack/ship-policy.json`; the plan batches one PR per workstream per phase (plan:63)

## Decision ledger

### S1: per-target observation shape for the pane store
Finding: S1, INFORMATIONAL, confidence 9/10, plan 3.1/3.5, reviewer: Claude (eng review)
Plan baseline: 3.1 "`TargetPanes` value … replaces the 8 parallel dictionaries"; 3.5 "Move `TerminalSessions` to `@Observable`, per `TargetPanes`"; D2 depends on it (owner answer, 2026-11-05).
Runtime evidence: today `TerminalSessions` is an `ObservableObject` with seven `@Published` dictionaries (`TerminalSessions.swift:485-507`). Dictionary invalidation under `@Observable` was not measured here; it follows from Observation tracking per stored property (SE-0395).
Comparison grid:

| Choice | Current | A | B | C |
|---|---|---|---|---|
| S1 observation shape | value `TargetPanes` in a dictionary on an `@Observable` store | pure `PaneState` value in `TerminalModel`, wrapped by one `@Observable` `TargetPanes` object per target; the store's dictionary changes only on add and remove | keep the value in the dictionary; per-store invalidation; keep ADR 0018 view fixes | measure dictionary invalidation first, bounded to one probe, then choose A or B; nothing else approved |
| D2 app-wide store after 3.5 | approved | unchanged | unchanged | unchanged |

Question D3:
D3 — How should each workroom's panes be observed? <gstack-qid:plan-eng-review-per-target-observation>
Project/branch/task: docs/architecture-cleanup-plan, eng review of the cleanup plan.
ELI10: Step 3.1 bundles each workroom's tabs and splits into one value, kept in a dictionary on the pane store. Step 3.5 moves that store to Swift's `@Observable` so that a title change in one workroom only redraws views of that workroom. But `@Observable` watches whole properties, and reading one entry of a dictionary watches the whole dictionary. As planned, every workroom's change would still redraw every window, which is the WORKROOM-2B hang class that D2 must avoid.
Stakes if we pick wrong: D2's app-wide store would republish every window on every title tick; hangs come back.
Recommendation: A because it keeps the split and focus rules a pure, package-tested value while giving each workroom its own observable object, so views redraw per workroom.
Completeness: A=10/10, B=6/10, C=8/10
Pros / cons:
A) Per-target observable object (recommended)
  ✅ A title change in one workroom redraws only that workroom's views
  ✅ The rules stay a pure value in TerminalModel, tested with swift test
  ❌ One small wrapper class per target to create, hand off and release
B) Keep the value in a dictionary
  ✅ Simplest code: one dictionary, no wrapper objects to manage
  ✅ Matches 3.1 as written, with no change to the plan's steps
  ❌ Every change redraws every reader; D2's app-wide store makes it worse
C) Measure first
  ✅ Settles the invalidation question with a probe, not reasoning
  ✅ Costs about an hour before 3.1 starts (human: ~2 h / CC: ~20 min)
  ❌ Defers the design; A is very likely the outcome anyway
Net: a small wrapper per workroom buys per-workroom redraws, which D2 depends on.
Header: Observation
Options:
A) Per-target observable (recommended)
Pure `PaneState` value in TerminalModel; one `@Observable` `TargetPanes` per target; the dictionary changes only on add and remove (human: ~1 day / CC: ~30 min extra in 3.1/3.5).
B) Value in dictionary
Keep 3.1 as written; accept per-store invalidation and keep the ADR 0018 view-by-view fixes.
C) Measure first
One bounded probe of dictionary invalidation under `@Observable` before 3.1, then decide A or B; approves no design change.

State: approved
Actual answer: A) Per-target observable (owner, D3, 2026-11-05)
Accepted scope: 3.1 builds a pure `PaneState` value in `TerminalModel` (tabs, order, split groups, focus, counter; ids only) and one `@Observable` `TargetPanes` object per target that holds it. The store's target dictionary changes only when a target is added or removed. 3.5 observes per `TargetPanes`. D2 unchanged.
History: none

### R-D2: the owner's D2, reopened by the outside voice
Finding: OV1, High (Codex), confidence 10/10 after verification. `AppStore+WindowMove.swift:340-343` ("Into a window that already shows the workroom, its terminals join this window's own … (#444 Q12)") and `WorkroomHandOverTests.swift:170` (`testIntoAWindowShowingTheWorkroomTheTabsJoinItsOwn`).
Plan baseline: D2 (owner, 2026-11-05): "One app-wide pane store keyed by target, after step 3.5. A workroom lives in one window at a time". That premise is false.
Runtime evidence: two windows can show the same workroom with independent tabs, splits and focus; a move into such a window appends the moved tabs after its own and keeps its layout.
Comparison grid:

| Choice | Current | A | B | C |
|---|---|---|---|---|
| R-D2 pane ownership | D2 approved on a false premise: one store keyed by target | tabs app-wide by tab id (surface, session, live and agent state); each window keeps a per-target layout over tab ids | per-window `TerminalSessions` stays; hand-off code stays; D2 withdrawn | one window per workroom: Q12 merge removed, behaviour change |
| D3 per-target observable | approved | per window and target layout object | per window, as today's split | per target |
| #444 Q12 merge behaviour | supported, tested | kept | kept | removed |

Question D4:
D4 — Panes app-wide by tab, or per window? (D2 reopened) <gstack-qid:plan-eng-review-pane-ownership>
Project/branch/task: docs/architecture-cleanup-plan, eng review of the cleanup plan.
ELI10: You chose D2 because I told you a workroom lives in one window at a time. That is wrong. Two windows can show the same workroom with separate tabs, and moving one into the other merges them (#444 Q12, pinned by a test). So "one store keyed by workroom" cannot hold two windows' different tabs. The useful part of D2 survives: tabs can live app-wide by tab id, with each window keeping only its own arrangement of them.
Stakes if we pick wrong: Built as D2 says, two-window workrooms break; kept per window, new per-tab state keeps getting dropped on moves.
Recommendation: A because it keeps Q12 and still ends the hand-off of per-tab state: a move or merge only shifts tab ids between two windows' layouts.
Completeness: A=10/10, B=7/10, C=5/10
Pros / cons:
A) Tabs app-wide, layouts per window (recommended)
  ✅ Per-tab state never travels, so a new field can't be dropped by a move
  ✅ Keeps Q12: two windows show one workroom, each with its own layout
  ❌ L step: the registry must track which window's layout holds each tab
B) Keep per window, withdraw D2
  ✅ No ownership change; today's tested hand-off paths stay as they are
  ✅ Lowest risk of the three for restore and window-move regressions
  ❌ TargetHandOff keeps hand-copying per-tab state, the drift D2 targeted
C) One window per workroom
  ✅ Simplest model: one target, one layout, one store entry
  ✅ Removes the merge rules in adoptWorkroom entirely
  ❌ Removes a shipped, tested behaviour (#444 Q12) that users may rely on
Net: A keeps today's behaviour and still deletes the per-tab hand-off.
Header: Pane store
Options:
A) Tabs app-wide (recommended)
App-wide `TerminalPanes` owns every tab by id (surface, session, live and agent state); each window keeps a per-target `TargetPanes` layout (D3) over tab ids; moves and Q12 merges shift ids between layouts (step 3.9, L).
B) Keep per window
Withdraw D2: per-window `TerminalSessions` stays, `TargetHandOff` stays; D3 applies per window.
C) One window per workroom
Behaviour change: a workroom opens in one window only and the Q12 merge goes; needs your product call and docs-site change.

State: approved
Actual answer: A) Tabs app-wide (owner, D4, 2026-11-05)
Accepted scope: D2 is replaced. An app-wide `TerminalPanes` owns every tab by id: its surface, session, live and agent state. Each window keeps, for each target it shows, a `TargetPanes` layout (D3) of order, splits and focus over tab ids. A window move or a Q12 merge shifts tab ids between two windows' layouts. Per-tab state never travels, and `TargetHandOff` shrinks to the layout. Q12 behaviour and its test are kept. Step 3.9, L.
History: D2 answered "App-wide, after 3.5 (Recommended)" on 2026-11-05, on the false premise above.

Auto-decided under the owner's standing rule ("don't ask me about questions you have a 10/10 confidence in"): S2–S6 and S8 (Scope Challenge); A1, A2, A5, A6, Q2 and T1–T4 (below); OV2 and OV3 (outside voice). Each is recorded with the step it amended.

Approval readiness: PASS. Checked: eng D1 (crate 3.8 → 1.10, answer D1), D2 (own DevContainer package, answers D2 and D2 reopened), S1 (answer D3), R-D2 (answer D4), and the auto-decisions listed above.

### Section 1: Architecture

Design twice. Shape 1 (chosen) has one app-scoped `AppModel` (D1) and per-window models that apply its events, with tabs app-wide by id (D4). Shape 2 would keep per-window stores and make cross-window effects travel over a notification bus. Shape 1 hides the cross-window rules behind one owner and a small event surface. Shape 2 spreads them across every subscriber (split ownership, red flag 5). Red flags screened:
- hand-synced lists: providers (1.2), `project.yml` packages (S6), channel names (5.1)
- split ownership: split groups (1.5), session id and cwd stored twice (3.2)
- two ways to do one task: the Control codecs (3.6)
- importable internals: the Rust `pub mod` (0.6)

Findings:
- [INFORMATIONAL] (confidence: 9/10) plan 2.1/2.2. A1: removing the modal proxies in 2.1 and then replacing modals in 2.2 rewrites 100 test references twice. Auto-decided: the modal proxies move to 2.2.
- [INFORMATIONAL] (confidence: 10/10) plan 2.3. A2: `RunCommands` was not marked app-scoped, though D1 makes run ownership app-wide. Auto-decided: marked.
- [INFORMATIONAL] (confidence: 9/10) plan 2.5. A5: AppModel events must be synchronous main-actor calls, in ADR 0021's style, so a window cannot miss one. Auto-decided.
- [INFORMATIONAL] (confidence: 9/10) plan 1.10. A6: the crate's CI paths (`build-ghostty-vt.sh`, the cache keys at `ci.yml:206,265`, the musl job). Auto-decided.

Dispositions: A1, A2, A5 and A6 accepted (auto).

### Section 2: Code quality

Shared code: `PaneSplitGroups` (1.5) has two verified callers that have drifted (`AppStore+WorkroomSplit.swift:28-30` and `TerminalSessions.swift:947-950`, plus five more pairs). The `exec` module (1.7) has four (`vcs.rs:592`, `run_script.rs:170`, `session.rs:2400`, `diff.rs:165`). The differences each caller needs (dead-leaf pruning, leaf weights, HUP first) stay as injected policy.
- [INFORMATIONAL] (confidence: 9/10) plan 0.10. Q2: renames in the same commit as 0.1's moves make `git log --follow` lose them. Auto-decided: separate commits, renames after moves.

Dispositions: Q2 accepted (auto).

### Section 3: Tests

Framework: XCTest (app), `swift test` (packages), `cargo test` (Rust), `go test` (Go); see `AGENTS.md` Build commands.

```
CODE PATHS (plan steps with regression risk)            USER FLOWS
[+] 1.1 AppServices + #if DEBUG fixture                  [+] Two windows on one project
  ├── [★★ TESTED] UI-test launch flags (UI suite)          ├── [GAP→T1] delete/create in one window (2.5 first commit)
  └── compile-time: Release cannot reference fixture       └── [★★★ TESTED] Q12 merge — WorkroomHandOverTests:170
[+] 1.4 SurfaceEvent sink                                [+] Run command
  └── [GAP→T2] moved run tab's child exit                  ├── [★★★ TESTED] running run moves — WorkroomHandOverTests:~190
[+] 1.5 PaneSplitGroups                                    └── [GAP→T2] exit after move
  └── [★★★ TESTED] 102 + 134 rule tests, moved to package [+] Restore after relaunch
[+] 1.7 exec module                                        └── [★★ TESTED] SessionRestoreTests (renames keep session.json)
  ├── [★★★ TESTED] vcs.rs setsid escape — vcs.rs:1781
  └── [GAP→T3] run_bounded setsid escape
[+] 0.9 jj-field removal
  └── [GAP→T4] old daemon reply still decodes
[+] 1.8 lock_or_recover        [★ none today] → Test Plan edge case
[+] 3.9 tab registry           [★★★] Q12 + run-move tests are the contract, unchanged

COVERAGE: 7/11 paths tested before amendments; 11/11 with T1–T4 and the Test Plan cases
```

Gaps, all auto-decided into their steps:
- T1: two-window characterization test (2.5).
- T2: moved run tab exit (1.4).
- T3: `run_bounded` escape (1.7).
- T4: old-reply decode (0.9).

Regression contract for every rewrite step: existing suites stay green with unchanged assertions; tests move with their code, but their assertions do not change. Test Plan: `~/.gstack/projects/joelmoss-workroom/joelmoss-docs-architecture-cleanup-plan-eng-review-test-plan-20261105-213728.md`.

Dispositions: T1–T4 accepted (auto).

### Section 4: Performance

No new issues. Step 3.5 already measures the terminal divider with Instruments before and after. D3 makes redraws per layout. Moving the root-branch watchers app-wide (2.5) removes the N-window duplicates.

### Outside voice (Codex, gpt-6-astra, completed)

- OV1 High, verified: D2's "one window per workroom" premise is false (Q12). Resolved by D4, answer A.
- OV2 Medium, verified: `cfg(test)` gating breaks the integration tests. Auto-decided: a `test-support` feature (0.6).
- OV3 Medium, verified: a workspace member is built by `clippy --workspace`. Auto-decided: the crate's own `link` feature (1.10).

Cross-model: Codex found the one premise error that the native review and the six area reports all missed. Agreement elsewhere: none were contradicted.

### NOT in scope

- **The daemon's shared watcher registry** (`TODOS.md:401`, narrowed): needs the cross-connection refcount design; the app half is in 2.5.
- **Retiring the legacy session shim** (`TODOS.md:148`, ADR 0006): its own timeline, not before 2027; 3.7 waits for it.
- **Moving `TODOS.md` to GitHub issues:** declined in D7.

### What already exists

The plan reuses, rather than rebuilds:
- `PaneLayout<Leaf>` (`WorkroomDomain`)
- `TabReorderMath` (extended for the tab-strip chrome)
- the `HostDriver` capability pattern (`DaemonPlacingDriver`)
- `RemoteCreateServices` (the seam shape for `AppServices`)
- `RemoteStateModel`'s closure wiring (the template for new owners)
- the `--json` goldens
- `channel_cases.tsv` (the pattern for 5.1)
- `vcs.rs`'s escape test (the pattern for T3)

### Failure modes

| New path | Realistic failure | Covered by | User sees |
|---|---|---|---|
| AppModel events (2.5) | a window misses a delete | T1, synchronous delivery | stale row (caught by T1) |
| SurfaceEvent (1.4) | moved run tab's exit lost | T2 | run shown running forever (caught) |
| tab registry (3.9) | merge loses a window's layout | Q12 test | layout reset (caught) |
| `Bundle.module` scripts (4.3) | Release `.app` cannot find scripts | Release proof | clear "no host-setup script" error, `HostDriver.swift:108` |
| `lock_or_recover` (1.8) | poison log floods | Test Plan edge case | nothing visible |

Critical gaps: 0.

### Worktree parallelization

| Step | Modules touched | Depends on |
|---|---|---|
| Phase 0 app moves (0.1–0.4, 0.9–0.10) | `macapp/WorkroomApp`, docs | — |
| Phase 0 Rust (0.5, 0.6) | `vcs/crates/workroomd` | — |
| Phase 0 Go (0.7) | `internal/workroom` | — |
| 1.1 AppServices | `WorkroomApp/Core/AppShell`, `Testing` | 0.1 |
| 1.2, 1.3 host kinds and capabilities | `Packages/WorkroomDomain`, `Packages/HostDrivers`, `Core/RemoteHosts` | 0.1 |
| 1.4–1.6 terminal seams | `Core/Terminal`, `Packages/WorkroomDomain` | 0.1 |
| 1.7, 1.8, 1.10 daemon | `vcs/crates` | 0.5 |
| 1.9 Go payloads | `cmd` | 0.7 |
| Phase 2 app owners (2.1–2.5) | `Core/AppShell`, `WorkroomManagement`, `VersionControl` | 1.1 |
| 2.6, 2.7 remote lifecycle | `Core/RemoteHosts` | 1.3 |
| 2.8 daemon | `vcs/crates/workroomd` | 1.7, 1.8 |
| Phase 3 | `Core/Terminal`, `Packages/TerminalModel` | 1.4–1.6, 2.3 |
| Phase 4 packages | `Packages/*` | 1.2, 2.6 |
| Phase 4 views | `Views/*`, `Packages/DesignSystem` | 2.2 |

Lanes:
- Lane A: app shell (1.1 → 2.1 → 2.2 → 2.3 → 2.4 → 2.5)
- Lane R: remote (1.2 → 1.3 → 2.6 → 2.7 → 4.2, 4.3)
- Lane T: terminal (1.4 → 1.5 → 1.6 → phase 3)
- Lane D: daemon (0.5 → 0.6 → 1.7 → 1.8 → 1.10 → 2.8)
- Lane G: Go (0.7 → 1.9 → 5.x)
- Lane V: views (4.6 → 4.7 → 4.8 → 4.9, after 2.2)

Execution order: land the app half of Phase 0 alone, then launch A, R, T, D and G. Lane V starts after A reaches 2.2.

Conflict flags:
- Lanes A and T both touch `AppStore+RunCommand` (2.3 against 1.4): land 1.4 first.
- Lanes A and V both touch `ModalState` (2.2).

### Implementation Tasks

Synthesized from this review's findings. Each task derives from a specific finding above. Ratio assumption: architecture work about 5x, tests about 50x.

- [ ] **T1 (P1, human: ~3h / CC: ~10min)** — macapp — Write the two-window create/delete characterization test before 2.5
  - Surfaced by: Section 3 — no cross-window create or delete test (`MultiWindowTests`)
  - Files: `macapp/WorkroomAppTests/MultiWindowTests.swift`
  - Verify: `make app-test`, and it goes red if the sibling loop is skipped
- [ ] **T2 (P1, human: ~2h / CC: ~10min)** — macapp — Add the moved-run-tab exit regression test in 1.4
  - Surfaced by: Section 3 — `onChildExited` is overwritten by window moves
  - Files: `macapp/WorkroomAppTests/WorkroomHandOverTests.swift`
  - Verify: `make app-test`
- [ ] **T3 (P2, human: ~2h / CC: ~10min)** — vcs — Add a `run_bounded` setsid-escape test with 1.7
  - Surfaced by: Section 3 — only `vcs.rs` exec is tested for escapes
  - Files: `vcs/crates/wr-vcs-git/src/diff.rs`
  - Verify: `make vcs-test`
- [ ] **T4 (P2, human: ~1h / CC: ~5min)** — macapp — Old-daemon reply decode test with 0.9
  - Surfaced by: Section 3 — removing jj fields has no decode test
  - Files: `macapp/WorkroomAppTests/DaemonVCSProtocolTests.swift`
  - Verify: `make app-test`
- [ ] **T5 (P1, human: ~2h / CC: ~15min)** — vcs — Use a `test-support` feature, not `cfg(test)`, in 0.6
  - Surfaced by: Outside voice OV2
  - Files: `vcs/crates/workroomd/Cargo.toml`, `src/session.rs`
  - Verify: `make vcs-test` and `make vcs-lint`
- [ ] **T6 (P1, human: ~2h / CC: ~15min)** — vcs — Gate ghostty-vt behind its own `link` feature in 1.10
  - Surfaced by: Outside voice OV3
  - Files: `vcs/crates/ghostty-vt/Cargo.toml`, `build.rs`, `vcs/Cargo.toml`
  - Verify: `cargo clippy --workspace` with no Zig on PATH, and the `terminal-state` CI job
- [ ] **T7 (P1, human: ~1 day / CC: ~1h)** — macapp — Build 3.9 as tabs app-wide with per-window layouts (D4)
  - Surfaced by: Outside voice OV1
  - Files: `Core/Terminal/*`, `Packages/TerminalModel`
  - Verify: `testIntoAWindowShowingTheWorkroomTheTabsJoinItsOwn` green unchanged
- [ ] **T8 (P2, human: ~1h / CC: ~10min)** — macapp — Prove a Release `.app` finds the host-setup scripts in 4.3
  - Surfaced by: Scope Challenge S3
  - Files: `macapp/Packages/HostDrivers`
  - Verify: create a boxd workroom from a Release build

_No new tasks from Performance._

### Unresolved decisions

None.

### Completion summary

- Step 0: Scope Challenge — scope accepted as-is (3.8 kept and moved to 1.10)
- Reality rows: 7/7 applicable rows emitted (`PLAN_REALITY: phase=eng rows=7/7 missing=none unverified=4 verdict=complete`), 4 unverified premises
- Architecture Review: 4 issues found
- Code Quality Review: 1 issue found
- Test Review: diagram produced, 4 gaps identified
- Performance Review: 0 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 0 items proposed (2.5 narrows `TODOS.md:401` when it lands)
- Failure modes: 0 critical gaps flagged
- Unresolved decisions: 0 in this review
- Outside voice: Codex (gpt-6-astra), completed, 3 findings (1 High, 2 Medium), all resolved
- Parallelization: 6 lanes, 5 parallel / 1 sequential (V after A's 2.2)
- Lake Score: 3/3

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Outside Review | Codex via `/plan-eng-review` | Independent 2nd opinion | 1 | completed | 3 findings (1 High, 2 Medium), all resolved |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | issues_open | 9 issues, 0 critical gaps (all resolved in the plan) |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **OUTSIDE COVERAGE:** Codex, plan-review phase, completed; OV1–OV3 verified against code and resolved (D4, 0.6, 1.10).
- **CROSS-MODEL:** native review plus six area reports against Codex. Codex alone caught the Q12 premise error; no native finding was contradicted.
- **VERDICT:** ENG REVIEW done with every finding resolved in the plan. Status stays issues_open because issues were found (the rule counts resolved findings too). Ready to implement Phase 0.

NO UNRESOLVED DECISIONS
