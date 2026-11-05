# Architecture review and cleanup plan (November 2026)

Status: accepted, 2026-11-05 (decisions D1–D8 below). Reviewed at `65f01f1fa`. Nothing here is built yet.

Since the last cleanup (2026-10-10, Lanes A–C, Go and Rust lanes), 686 commits have added 48k lines and removed 22k. This review asks what a top-tier Swift, Rust and Go architect would complain about, with the goal that people can work on separate parts of the app in parallel.

**The thesis.** The domain model is already good. `CONTEXT.md` names seven contexts, there are 65 ADRs, and the "why" comments are excellent. The physical code does not follow that model. The plan does not invent a new architecture: it makes folders, types, packages and modules match the contexts `CONTEXT.md` already documents, and gives every context an owner who can build and test it without the others.

Evidence for every claim below is in the six area reports in [`architecture-cleanup-2026-11/`](architecture-cleanup-2026-11/): app shell, terminal, VCS and remote, views, Rust, and Go and cross-cutting. Each claim there names a `file:line`, a count or command output, and each report ends with its own open questions. The load-bearing claims were re-checked by hand before this was written: the fixture strings in both installed binaries, `Bundle.main` in `HostDriver.swift:107`, 6e17146de editing both split copies, the three files that assign `onChildExited`, `SWIFT_VERSION "5.0"` on the test targets, zero `.pty()` callers, and the 19 driver downcasts.

## What a top-1% reviewer would say first

1. **"Your god object grew back."** The `AppStore` type spans 13 files and 9,210 lines, with 214 properties and 312 non-private funcs. Its total grew 16% since the cleanup: `AppStore.swift` shrank, but the extensions grew. The extensions are file splits, not boundaries; their own headers say "moved out as is, state stays on `AppStore`". 131 of the 478 macapp commits since 2026-10-10 touched an AppStore file. Creation, run commands and workroom status cannot be worked on in parallel.
2. **"You extracted owners and then hid them."** `ProjectStore`, `ModalState` and `RunCommandController` exist, but `AppStore` re-exposes 53 of their fields as forwarding proxies, and views only ever use the proxies.
3. **"Test scaffolding ships to users."** ADR 0022 says the fixture is wrapped in `#if DEBUG`; it is not. `strings` on the installed stable 2.1.0 binary finds `FixtureVCSWriter` and `uitest-created` strings, and so does the Nightly. Production code holds 54 `isFixture` branches, including 8 in views.
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
9. **"There is no composition root."** Dependencies arrive five ways: init parameters, about 10 settable closures, 11 `*ForTesting` vars, `nonisolated(unsafe)` static seams, and 41 singletons. Cross-window behaviour is one window's store looping over its siblings (`affectedStores`, used at 8 or more sites). Eight process-wide `static var`s hang off the per-window type.
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

- **D1. App-scoped owner: yes.** Workroom create and delete, the VCS status sweep and run-command ownership move out of the per-window `AppStore` into one app-scoped `@MainActor` model. Windows subscribe to its events (`targetRemoved`, `paneReplaced`) instead of being iterated, and the 8 process-wide statics move into it. No ADR forbids this; ADR 0064's rejection was about the Quick Terminal joining `allStores`. Steps 2.4 and 2.5; record it as an ADR.
- **D2. One app-wide pane store keyed by target, after step 3.5.** A workroom lives in one window at a time, so windows hold only which targets they show and their layout. The #444 and #577 hand-off code (`WorkroomHandOff`, `TargetHandOff`, `RunCommandController.HandOff`, `WorkroomHandOffs`) goes. It waits for `TargetPanes` (3.1) and per-target `@Observable` (3.5), so that one shared store does not republish every window on every title change (the WORKROOM-2B class). Step 3.9; record it as an ADR.
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
| 0.6 | Make modules `pub(crate)` with a `#[doc(hidden)] pub mod testing` re-export, so rustc reports dead code again. Delete `Session::pty()`. Make `account` and `run` private. Gate the test-only methods behind `cfg(test)`. | D | S | imports |
| 0.7 | Split Go `workroom.go` into `create.go`, `delete.go` and `listing.go` (methods stay on `Service`) | G | S | none |
| 0.8 | Fix the stale docs: ADR 0020 (Project and Workroom have moved), ADR 0022 and 0023 status lines, the `SessionSnapshot.swift:36-42` header (contradicts ADR 0058), the `wr-vcs-git/Cargo.toml:2` comment, `lib.rs`'s "Phase 1/2" text, the `gitHardening` "every invocation" comment, the jj-field comment in `DaemonVCSReader.swift:119`, and `curate-release`'s "three in lockstep" | all | S | none |
| 0.9 | Remove the leftovers: the untracked `vcs/crates/wr-agent/`; the test-only `workroomSplitActive` and `createStep(for:)`; and the five jj-era fields the app decodes but never reads (`DaemonVCSReader.swift:144-158`). Dropping those fields is the app-side half of `TODOS.md:376` and the precondition ADR 0007 waits on. It is safe against every daemon, because `JSONDecoder` ignores unknown keys. | R, A | S | small |
| 0.10 | Saved-layout renames per D3, with the `CONTEXT.md` entry first | T | S | renames only |

### Phase 1: seams (small, unblock everything after)

| # | Step | WS | Size | ADR |
|---|---|---|---|---|
| 1.1 | `AppServices` (cli, VCS writer, history resolver, remote-create services, trasher, notifier, host-layout store, host sessions, clock), built once in `WorkroomApp.init` as `.live`, with `.fixture` and `UITestFixture.swift` under `#if DEBUG`. The 54 `isFixture` branches collapse into the choice of services. Verify with `strings` on a Release build. | A | M | finish 0022 |
| 1.2 | `HostKind` value in `WorkroomDomain` replaces `Place`, `DriverKey`, `CreationKind` and `HostProvider`; `Runtime` and `Dialect` merge. `HostDescriptor` gets typed read views (`kind`, `lifecycle`) over the lenient strings, following ADR 0014's pattern on the Swift side. | R | M | new |
| 1.3 | Capability protocols in `HostDrivers` (`HostPresenceReporting`, `StartableHostDriver`, `ReconnectingHostDriver`, `OptionedProvisioning`, `RepositoryGranting`) remove the 19 downcasts. One `HostDriverRegistry` becomes the only constructor, replacing six sites with two different `directory:` values. Check that mismatch for a real bug first. | R | M–L | new (provider behaviour through capabilities) |
| 1.4 | One `SurfaceEvent` sink on `GhosttySurfaceView`, set once by `TerminalSessions`. Run-tab child exit becomes a `TerminalSessions.Event`. `AppStore` never touches `surface?.on…`. | T | M | extends 0021 |
| 1.5 | `PaneSplitGroups<Leaf>`, `PaneTreeLayout` and `PaneMetrics` move into `WorkroomDomain`, used by both splits. Merge the two test suites' rule tests into one package suite that runs under `swift test`. Share `SplitDivider`, `DropAccent` (whose accent colour has already drifted) and the tab-strip chrome. | T | M | — |
| 1.6 | Typed `TargetID` (encode and decode in `WorkroomDomain`) replaces the pipe string and its four resolvers | T | M | — |
| 1.7 | workroomd `exec` module: git env scrub and pins, bounded capture, `end_tree`, fd flags. `wr-vcs-git` uses it or a shared `git_command`, so `run_bounded` gets the `setsid`-escape kill. Login environment moves from `cli/run_script` to `shell.rs`. | D | M | — |
| 1.8 | Write the lock order (the graph in the Rust report) as one doc block on the store, recover from poisoning everywhere through one `lock_or_recover` helper that logs once (D5), and document any exception | D | S–M | — |
| 1.9 | Go typed payload structs replace the `map[string]any` literals in 24 `cmd` files; the goldens stay the oracle. `workroom` returns its own result types, so `cmd` stops importing `vcs`. | G | M | 0013 unchanged |

### Phase 2: give state an owner (the parallel-work unlock)

| # | Step | WS | Size | Test refs to redirect |
|---|---|---|---|---|
| 2.1 | Delete the 53 forwarding proxies, one owner per commit (modals, run, project store). Inject the owners into the environment. | A | S–M | 100 / 52 / 111 |
| 2.2 | `ActiveModal` enum replaces about 30 `pending*` optionals and the hand-maintained `hasModalPresentation` OR (#451 class) | A, V | M | ModalState tests |
| 2.3 | `RunCommands` aggregate (`RunCommandController` plus `AppStore+RunCommand`), with its own stored state. Base-branch settings move to Workroom management and `branchName` to Version control. | A | M | 52 / 4 files |
| 2.4 | App-scoped `VCSStatusService` (`AppStore+WorkroomStatus`, ProjectStore's status fields, the sweep). Split `WorkroomStatusResolver` into working status, GitHub (gh) and a git probe. | A, R | M | 111 / 14 files |
| 2.5 | App-scoped `WorkroomLifecycle` (create and delete, `CreationRun`, `RemoteCreateServices` without `AppStore` in its signature). Windows apply its events, `affectedStores` goes, and the 8 statics move here (D1). | A | L | 179 / 7 files |
| 2.6 | The remote lifecycle runs over a `Placement` protocol (provisioned host or SSH folder, per ADR 0056), with one shared `cloneAndCheckOut` and one `runTeardown`. The delete flow takes an `onForgotten` callback instead of calling `PortForwardingModel` and `ProgramStatusMonitor` singletons. The `RemoteHosts.shared` seam leak at `:723` goes. | R | M | setup code only |
| 2.7 | Split `RemoteHosts` into `HostDriverRegistry` and `HostReachability` (connect, backoff, relay) | R | M | RemoteHostsTests splits |
| 2.8 | workroomd: `terminal/dispatch.rs` comes out of `serve.rs`. `runs`, `screens` and `program_status` observe the store through one hook surface instead of being fields on it. Terminal codecs move to `wr-protocol`. One `RpcClient` for the five copy-pasted test clients. | D | L | low |

After phase 2, creation, run commands, VCS status, remote lifecycle, terminal and daemon each have their own files, stored state and tests. Six people can work in parallel without meeting in `AppStore.swift`.

### Phase 3: break up the terminal hub

| # | Step | WS | Size |
|---|---|---|---|
| 3.1 | `TargetPanes` value (tabs, order, groups, focus, counter; ids only) replaces the 8 parallel dictionaries, so `reap`, hand-off and capture each become one line | T | M |
| 3.2 | `TerminalTab` without the `NSView`: session id, cwd and the run flag become stored facts (this ends the `state.x ?? state.view.x` idiom), and a `SurfaceRegistry` owns the views. A new `TerminalModel` package holds `TargetPanes`, the tab model and capture mapping, tested with `swift test`. | T | L |
| 3.3 | Pull `PaneLiveState` (cwd, branch, title, tool and agent observers), `ProgramStatusBinding` and `RemotePaneLinks` out of `TerminalSessions` | T | M |
| 3.4 | `PaneSessionAttachment` out of `GhosttySurfaceView` (attach command and env, reconnect backoff, network re-attach) behind the injected service. The view keeps FFI, input, render and accessibility only. | T | M |
| 3.5 | Move `TerminalSessions` to `@Observable`, per `TargetPanes`, after first replacing the `objectWillChange` dirty hook (`AppStore.swift:996`). The terminal divider gets the workroom divider's live and commit pattern (#139), measured with Instruments before and after. | T | M |
| 3.6 | One Control codec in `DaemonConnection` (the local and remote clients each have their own today). Rename `DaemonVCSConnection` to `DaemonClient`. VCS reply DTOs move beside the request. `HostID` moves to `WorkroomDomain`. | T, R | S–M |
| 3.7 | When the shim retires (TODOS:148), split `PersistentSessionService` into `LocalSessionControl` and `RemoteSessionRegistry` | T | M |
| 3.8 | Optional: a `crates/ghostty-vt` sys and safe-wrapper crate, so `terminal.rs` holds no `unsafe` (95 of the 229 `unsafe` uses in production code) | D | M |
| 3.9 | App-wide pane store keyed by target (D2): windows keep only selection and layout, the hand-off structs go, and `TerminalSessions` is renamed `TerminalPanes` (D3). Needs the adversarial review. | T | L |

### Phase 4: packages and the view layer

| # | Step | WS | Size |
|---|---|---|---|
| 4.1 | `Packages/WorkroomGit`: the four libgit2 files (ADR 0002 keeps its rule; only the paths change), `GitProvider`, `UnifiedDiff` and diff algorithms, `CLIVCSWriter`, `RepositoryWriteGate`, and `GitCommand` (hardening). `VCSProviding`, `VCSWriting` and `RepositoryLocation` move to `WorkroomVCS`. | R | M |
| 4.2 | `Packages/DevContainer` (config, features, setup) | R | S–M |
| 4.3 | `HostDrivers` host-setup scripts as `Bundle.module` resources; the boxd and exe.dev driver tests move into the package | R | S |
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
- **Test churn** is the main cost of every rename. The 82k test lines are sized per step above. #514 already audited test value, so this plan does not re-audit.

## Not verified

- **Swift dead code is grep-only.** `periphery` is not installed, and running it builds the app (which re-signs the running Dev app). Run it once before 0.9 if you want proof rather than candidates.
- **Go `deadcode` was not run.** The sandbox blocked the toolchain download, and the unsandboxed run was denied. `golangci-lint unused` reports 0.
- **The Rust results use Homebrew cargo 1.99.1, not CI's 1.96.1.** The Linux build was not checked.
- **The `directory:` mismatch** between driver constructors (1.3), and whether the terminal divider's per-tick store write costs anything measurable (3.5), are open until checked.
- **The Swift 6 error count for the test targets** is unknown until a build.
