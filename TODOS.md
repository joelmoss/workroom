# TODOs

> Grouped by priority, then by area. Within a group, cheaper/higher-leverage first. Each entry states
> what it is, why, how to start, what it depends on, and its priority. Completed work is summarised in
> [`docs/recently-done.md`](docs/recently-done.md), including the traps found while doing it, which
> are the parts worth reading before touching the same code. Full write-ups live in git history.

## P0 — before the next release

None open. The crossing-`keep` flake entry went with the test, `keep` and the prompt card in #380.

## P1 — before GA

### Finish removing base machines (codaset, Go, macapp) — #395 follow-ups

**What:** What is left of the remove-bases plan once the app retires older builds' bases at launch
(`BaseRetirement`, which also records each derived workroom's repository on its own descriptor
first, so PR and CI status no longer read a base).

- **Codaset (claim 4.0):** remove the `base_clone_token` route
  (`app/controllers/broker/grants_controller.rb`), with the rest of the broker, which ADR 0049
  retired. Only Nightly and Dev builds call any of it; no stable release does (v2.1.0 has no remote
  workrooms), so it can go now.
- **The legacy field:** `HostDescriptor.bases` and `BaseRetirement` itself, once no build that made
  bases is in use; with them, the Go side's base handling (`internal/config/claim.go`'s bases,
  `cmd/claim.go`, `refuseRemoteProject`'s project-host case) and the Delete Project sheet's "base
  machine" text.
- **Release note (claim 3.2):** the first release with #395 says new remote workrooms clone their own
  repository, and that the app removes old base machines at launch.

**Effort:** S
**Priority:** P1
**Depends on:** nothing for Codaset; the legacy field waits for Nightly users to have launched a build
with `BaseRetirement`.

### Test a config-only project delete's remote teardown (macapp) — deferred from plan: docs/designs/scripts-on-every-workroom.md

**What:** A test that a config-only project delete with a remote workroom runs that workroom's
teardown before its machine is destroyed (R2), and keeps a log for it. The behaviour is built
(`AppStore.deleteProject`'s loop over `remoteWorkrooms`, `remoteTeardown(of:in:log:skip:)`), and
`RemoteTeardownTests` pins `RemoteWorkrooms.delete`'s side, but nothing pins that the app's
config-only path reaches it.

**Why:** a config-only delete keeps local worktrees, so a later change could reasonably make it skip
teardowns everywhere; for a remote workroom that destroys the host without its teardown, which can
leave the script's external resources running.

**How to start:** `AppStore.deleteProject` builds each workroom's `RemoteWorkrooms.Teardown` with
`remoteTeardown(of:in:log:skip:)`, whose `run` is always the live `RemoteWorkrooms.runScript`, and
takes its hosts' environment from `RemoteHosts.Deletion`. Give `AppStore` a seam for the teardown's
`run` (and a fake `Deletion`), then assert the teardown runs and the log exists for `.configOnly`.

**Effort:** S
**Priority:** P1
**Depends on:** nothing.

## P2 — perf, correctness, and the next VCS phase

### UI tests: session-isolation wiring check, close-the-right-pane (macapp) — UI-test-merge review follow-up

**What:** Two items left from the pre-landing review of the UI-test merge branch.

- **Session-isolation wiring.** A fixture-launch UI check that pins the session-isolation launch
  wiring in the routine run. Today only `SessionRestoreUITests` exercises that wiring, and the
  Makefile skips it by default. The `APP_UITEST_FLAGS` comment states that gap.
- **`PaneTitleBarUITests` passes on wrong behaviour.** It closes a pane and checks only that the
  count drops, so closing the wrong pane passes (the doc comment names that defect). Split Down is
  checked by count only. Assert which pane survived.

**How to start:** Each file you touch needs its class re-run with
`make app-uitest APP_UITEST_FLAGS="-only-testing:…"`.

**Depends on:** nothing.

**Priority:** P3 (deferred in /ship review, 2026-10-06).

### Tell a Mac its pane is sized for another Mac (wr-agent, macapp) — #255 follow-up

**What:** When another client owns a session's size, tell every attached client who owns it, and
show a quiet "sized for another Mac, type to take over" marker on the non-owner's pane (or
letterbox it to the owner's grid).

**Why:** Two Macs on one session share one pty size, owned by whichever Mac the user last typed or
clicked in (`session.rs` `Attached::claim`, gated on `InputClassifier::is_user_input`). The other
Mac's pane gets output drawn for the owner's grid, so Vim or htop look broken there with no hint
why until the user types.

**How to start:** Send a control frame to every attached client when `Attached::claim` changes
the owner; have the pane show the marker while it is not the owner. Design follow-up in
`docs/designs/oq8-cross-machine-reattach.md`.

**Depends on:** #255 (cross-machine reattach).

**Priority:** P2 (chosen in the #255 eng review, 2026-10-05)

### Remote workroom layouts: the review's deferred edge cases (macapp, wr-agent) — #255 review follow-up

**What:** Two cases the pre-landing `/review` of `feat/255-cross-machine-reattach` found and
deferred (2026-10-05). Neither loses data from a single window.

1. **A sibling window never takes over writing.** When two windows on this Mac show one remote
   workroom and the window that owns its layout (`HostLayoutOwners`, D10) closes, the other one
   keeps its tabs but never claims the workroom: `fetchHostLayoutIfNeeded` claims only for a window
   opening the workroom with no tabs. Its changes stop reaching the host for the rest of the launch.
   Fix: on the owner's close or emptying, let a window already showing the workroom claim it and
   write with no retry past `stale`, as an unanswered fetch does.
2. **One session as a pane in two windows.** In that same case the second window restores its own
   `session.json` copy while the owner's `HostLayoutSync.appending` adds the second window's
   sessions (same `sessionWorkroomKey`) as tabs, so one agent session is attached twice on one Mac
   and the two panes fight over its size. Fix: append only sessions no window on this Mac shows.

**Why:** Each is rare (two windows on one remote workroom), and the PR was already 4.2k lines.

**Depends on:** #255.

**Priority:** P2 (deferred in the #255 `/review`, D3, 2026-10-05)

### Retire the attach-only `workroom-session` shim (macapp) — issue #154 follow-up

**What:** Delete the remaining `macapp/WorkroomSession/` client, its pinned v2.0.0 binary fixture
(`macapp/WorkroomAppTests/Fixtures/workroom-session-v2.0.0`, 464KB), `SessionShimCompatibilityTests`,
and the freeze on `WorkroomSessionProtocol` — once no user can still be running a v2.0.0 daemon.

**Why:** The shim is deliberately temporary. It exists only to reattach terminals held by a daemon
process started by an app version older than the agent. That population shrinks with every reboot,
every logout, and every closed pane, and eventually reaches zero — at which point the client, its
fixture and its tests are pure carrying cost.

**Pros:** Removes the last of two pty client implementations, drops a binary from git, and frees
`WorkroomSessionProtocol` to change again (it is frozen today because its only real peer — a shipped
v2.0.0 binary — can never be recompiled to match).

**Cons:** Nothing signals when the population hits zero. It is a judgement call on elapsed time and
release adoption, so this will sit open for a while. Deleting it early strands exactly the users it
was added for.

**How to start:** Check whether any reattach-from-old-daemon has been reported since the shim landed.
Then delete the directory, the fixture, the compatibility tests, and the freeze comment together —
they are one unit, and leaving the fixture behind without its tests is worse than leaving all of it.

**Depends on / blocked by:** The shim landing first, then elapsed time plus release adoption. No hard
gate.

**Priority:** P2, not before 2027.

### Automate the rest of §N's IO-layer checklist (macapp) — libghostty-bump follow-up, filed 2026-08-13

**What:** the 1.3.2 bump added exactly one automated tripwire
(`GhosttyOrphanShellUITests.testNormalQuitLeavesNoOrphanedShell`) for `QA-libghostty.md` §N's
IO-layer subsection. Everything else in §N — surface/split churn volume, workroom switch, workroom
delete, force-quit variant, the scrollbar overlay — is still manual-only, exactly as it was before
this bump. That gap isn't new; it's just now visible with a name, having been walked end-to-end this
session rather than assumed.

**Two concrete blockers surfaced while running the manual retest, worth fixing before the next
attempt at automating this, not just re-discovering them again:**
- **Workroom-tab chips and the run-command button (`workroom.tab.*`, `runCommand.run`) didn't respond
  to synthetic `AXPress` or a raw `click at {x,y}` from an external AppleScript-driven session** —
  0 observable effect despite the action reporting success and the on-screen bounds being correct.
  Real keyboard shortcuts (⌘R/⇧⌘R) and raw `keystroke` text input worked fine throughout, which is
  how the QA results file's Run-tab and behavioral checks actually got driven. `GhosttyOrphanShellUITests`
  and `GhosttyActionDispatchUITests` prove an actual XCUITest host process (not external AppleScript)
  CAN drive these controls — `focusTerminal`'s tab-chip click works there. So the fix for
  workroom-switch/delete/OSC-7 automation is likely "write it as a real XCUITest," not "find the
  right AppleScript incantation."
- **`Process()` spawning `/bin/ps` (or presumably anything) throws `NSPOSIXErrorDomain Code=1
  "Operation not permitted"` from inside an XCUITest runner** (`WorkroomAppUITests`'s auto-generated
  `XCTRunner` host is sandboxed against subprocess spawning; the app under test itself is not — two
  different sandbox realms). `GhosttyOrphanShellUITests` worked around this with a heartbeat FILE
  (`/tmp`, not `NSTemporaryDirectory()` — see that file's doc comment for why `NSTemporaryDirectory()`
  resolves to a different, container-private path in the runner vs. the app) instead of polling `ps`.
  Any future XCUITest needing to observe OS-level process state should reuse that pattern rather than
  rediscovering the `ps` restriction.

**Also unverified, not automated, and not re-attempted manually either — flag before assuming
fine:** the terminfo `Se` capability's cursor-style-reset behavior change (`\E[2 q` → `\E[0 q`, found
during the bump's resource regen) has never been visually confirmed. A `screencapture -x` attempt at
this was abandoned mid-session when it turned out to capture the whole display rather than the
target window (see `macapp/QA-libghostty-results/2026-08-12-libghostty-1.3.2-bump.md`) — needs either a window-scoped capture API or a human at
the keyboard, not screen-wide automation.

**Sharper target for whoever runs this, found while surveying the wider `332b2aef...35e1a016`
upstream range (not just the diff of the terminfo file itself):** the `Se` change isn't a one-time
fixed-escape swap. It was refined again after `\E[2 q`→`\E[0 q` — `Se` now restores whatever cursor
style/blink the engine is *configured* with, paired with new default-cursor-style/blink options
(ghostty `c19ce03b`, `42fcd58d`; both confirmed ancestors of our pinned `35e1a016`). So the right
check is "does resetting after a TUI exit return to Workroom's actual configured default," not
merely "does it emit `\E[0 q`" — a literal-escape assertion could pass while the dynamic-default
behavior is still unverified.

**Depends on:** nothing blocking — can start anytime. The two platform-constraint findings above
mean whoever picks this up should design as a real XCUITest from the start, not attempt external
AppleScript driving again.

**Priority:** P3 — the manual checklist still covers this; nothing is unguarded, just unautomated.

### Finish the action-dispatch UI coverage (macapp) — search counters

**What:** add the `SEARCH_TOTAL` / `SEARCH_SELECTED` case to
`WorkroomAppUITests/GhosttyActionDispatchUITests.swift`. The other two visible tags (`SET_TITLE`,
`PROGRESS_REPORT`) are covered and green; this one was attempted, hit a wall, and was parked rather
than left as a failing test.

**Why:** the scrollback find bar's "n/N" counter is the only surface for those two actions, so
without it they have no automated detector — the same gap the rest of that file exists to close, and
it matters most when the engine is bumped.

**It is also the pin bump's missing tripwire.** `TerminalSearch.navigationPlan` encodes three
*engine* assumptions — `navigate_search:next` steps newest→oldest, the engine never wraps, and index
0 is the bottom-most match — and none is observable without driving a real search. If any moved
upstream, ⌘G becomes silently **wrong** (walks the wrong way, or stops dead at an end) rather than
merely redundant, and `TerminalSearchTests` cannot see it: those cover the pure fold, which stays
self-consistent against a changed engine. Until this lands, the only detector is manual —
`QA-libghostty.md` §N, "⌘F wrap + ordering". Once the fixture seam below exists, assert direction and
wrap against a seeded scrollback and the tripwire is automatic.

**What is already known (do not re-derive):**
- The bar DOES open under XCUITest from **`Edit ▸ Find…`** (`app.menuBars.menuBarItems["Edit"]
  .menuItems["Find…"].click()`). The menu item is `exists=true enabled=true hittable=true` while a
  terminal is focused — measured. `app.typeKey("f", modifierFlags: .command)` does NOT work: the
  focused terminal consumes the keystroke, exactly as `RunStatusUITests` documents for the Run button.
- Assert bar-open on the **text field** (`app.textFields.firstMatch`), NOT on the match summary:
  `TerminalSearchModel.matchSummary` is `""` until a needle is set, and an empty SwiftUI `Text`
  produces no accessibility element at all, so waiting on it waits forever while the bar is up.
- **The wall:** the needle never reaches the field. Both `app.typeText` and element-scoped
  `field.typeText` leave the summary at its empty-needle state (`""` — distinguishable from a real
  no-match, which renders "No results"). So `model.needle` is not being set. The field is a SwiftUI
  `TextField` with `.focused($fieldFocused)` and a deferred `onAppear` focus grab
  (`TerminalSearchBar.swift`), and `TerminalContainerView.applyFocus` yields to it — that interaction
  is the place to look.
- `terminal.search.summary` (the a11y identifier on the summary `Text`) already exists for whoever
  picks this up.

**How to start:** dump the accessibility tree with the find bar open
(`app.debugDescription` written to a file from inside the test) and confirm what the field element
actually is and whether it reports keyboard focus. If SwiftUI focus proves undrivable here, the
fallback is to drive `TerminalSearchModel.setNeedle` through a `UITestFixture` seam and assert the
counter, which still exercises the two engine actions end-to-end.

**Depends on:** nothing. `TerminalSearchTests` already covers the pure state folding, so this is
purely about the engine→UI leg.

**Priority:** P3 — two of the three visible tags are covered, and the search path has unit coverage
for everything except the engine round-trip.

### VCS write actions — Phase 2 (macapp) — roadmap pointer

**What:** The next VCS phase: turn the read-only foundation into a full in-app VCS UI. **Fetch, push
and pull-with-rebase have SHIPPED** (the VCS toolbar), and so have **commit + message-only amend/describe**
(the Changes inspector's commit dialog). What remains: selection-aware amend (needs a temp index)
and branch management.

**Where the write seam actually is — this changed.** The original plan put write methods on
`VCSProviding` with a `CLIVCSProvider` fallback. That is **not** what shipped, and new work should not
follow it. Writes live behind a **separate**, context-bound `VCSWriting` protocol
(`Core/RepositoryServices.swift`), constructed by `RepositoryRouter.writer(for:)`. Its local adapter
delegates to `CLIVCSWriter`, which implements `LocalVCSWriting`. Three properties hold it there:

- **Context binding.** `RepositoryRouter.reader(for:)` and `writer(for:)` each capture one
  `RepositoryContext` (host, path, shared ownership), and the returned `BoundLocalReader` /
  `BoundLocalWriter` take no path from the caller, so a service cannot be pointed at a
  different repository after it is built.
- **Write authorization.** `writer(for:)` requires a registered context with shared ownership
  (`registeredContext(for:)` + `requireOwnership()`) and throws `registrationRequired` otherwise. An
  unknown local repository can still be read, but it cannot be written to or snapshotted.
  `VCSProviding` stays read-only: it has no `fetch` or other network mutation.

So: add commit/amend and the rest as `VCSWriting` members, and they inherit the write gate, the network
environment hardening and the failure taxonomy for free.

**Which backend each op uses — decided, don't re-litigate.** `VCSWriting` says *where* writes live,
not *how* they run. The split:

| Ops | Backend | Why |
|---|---|---|
| commit/amend — **CLI, decided against this table's original answer** | **CLI** (`CLIVCSWriter.commit`, shipped) | This row used to say "native", and that was wrong on two counts it never weighed. **libgit2 runs no hooks** ([#964](https://github.com/libgit2/libgit2/issues/964)) — a `pre-commit`/`commit-msg` that the user's terminal honours would be silently skipped, which is worse than not offering commit at all. **libgit2 cannot sign**, so `commit.gpgsign = true` would produce unsigned commits. |
| branch management | **native** (libgit2/SwiftGitX) — provisional | Local, typed APIs, no output to parse, no tool-version floor, no locale exposure. Still the default answer, but **not "don't re-litigate"**: commit was re-litigated on measurement and moved. Check each op for hooks and signing before assuming native. |
| fetch, push, pull | **CLI** — permanently, not a stopgap | Two independent blockers, both verified from checked-out sources: SwiftGitX passes NULL options (`git_remote_fetch(remotePointer, nil, nil, nil)`, and `pull` is a `// TODO`), so it has no credential callback at all; **libgit2 implements no `credential.helper` protocol** — nothing in its `src` reads that config key, so native auth means reimplementing helper invocation ourselves. |

**Non-goal: Workroom does not store credentials for local workrooms.** No OAuth client, no keychain
writes, no auth prompt, no account concept for git in a local workroom. (Remote workrooms are no
exception: a provider's host uses the provider's own GitHub credentials, ADR 0049, and a local
container's git asks the Mac's own `gh` through a relay, ADR 0039.) The user's own helpers (`osxkeychain`, GCM, `!gh auth git-credential`,
anything corporate) are the correct answer, and shelling out gets every host — including ones we've
never heard of — for free, with the same credentials their terminal uses. GitHub Desktop is the
instructive counterexample: it also shells out (via `dugite`, which bundles its own git), but blanks
your helpers and registers itself as `credential.helper=desktop` because being *the GitHub client* is
its product. The cost of that choice is `app/src/lib/generic-git-auth.ts` — a second credential store,
with its own prompt UI, keychain keys and invalidation, for every non-GitHub host. We are not that
product, and the app's one GitHub dependency (PR status) already rides `gh`'s own token.

**When you do shell out, never parse prose.** `--porcelain`, `-z`, `%(…)`, `-T`, exit codes. Measured:
`Updates were rejected` becomes `Les mises à jour ont été rejetées` under `fr_FR.UTF-8`, so a prose
match loses the whole failure taxonomy for a non-English user. `StatusCommandRunner` pins `LC_ALL=C`
as a backstop; it is not the plan.

*Filed, not planned:* bundling our own `git` the way `dugite` does would delete all of
`Core/VCSToolVersions.swift` — floor, probe, notification, per-VCS scoping. Real cost (universal
binary, notarization, ~40MB, and the Go CLI would want the same binary), so revisit only if the
version floor actually bites a user.

**Why:** This is a roadmap phase, not a tactical follow-up. The authoritative scope + sequencing live
in the issue #59 plan; this entry is the pointer that makes it discoverable.

**How to start:** Read `Core/VCSWriting.swift` — its doc comment carries the routing diagram, the
per-backend command table and the placement rules (fetch always runs at the project root). The read
layer blocks nothing. What's left of the error taxonomy is that git still flattens to `.io`.

**Depends on:** the VCS read foundation (shipped, Phase 1) and the write seam (shipped with the
toolbar). Spans `Core/VCSWriting.swift`, possibly `vcs/` (Rust), and new write-flow UI.

**Priority:** P2 (the product direction; large — see the plan for the real breakdown).

### "New workroom from branch…" (macapp) — the successor to branch switching

**What:** Pick a local or remote branch and create a workroom for it, from the VCS toolbar's branch
segment or the ⌘O picker.

**Why:** Branch *switching* was deliberately cut from the VCS toolbar. A workroom's identity IS its
branch — `internal/vcs/git.go` creates it with `git worktree add -b`, and there is no `branch` field
anywhere in `internal/config` — so switching a workroom's branch makes its directory name permanently
wrong, with nothing to reconcile the two.

But the underlying need — "I want to work on that other branch" — is real, and creating a workroom is
the answer the product model actually supports. The toolbar's branch segment is **display only** — it
briefly routed to ⌘O, which was dropped because ⌘O lists only workrooms that already exist, so the
click promised more than it delivered. That leaves the segment with no action at all, which is the
honest state until this lands and gives it one worth having.

**Pros:** gives the cut affordance a correct home; makes an existing remote branch a first-class
starting point instead of requiring a manual create-then-checkout.

**Cons:** needs a branch list (the toolbar deliberately stopped enumerating refs when the picker was
cut), and a naming policy for the new workroom.

**Context / how to start:** `Views/OpenWorkroomDialog.swift` is the searchable, project-grouped picker
to clone; the Go CLI's `create` already accepts a branch. `CLIVCSWriter.gitRemoteRefsArgs` shows how to
enumerate remote refs cheaply, and its doc explains why the symref row must be dropped.

**Depends on:** the VCS toolbar (shipped).

**Priority:** P3 (a real gap, but ⌘O plus a terminal covers it today).

## P3 — VCS engine, diffs, and status

### Remove the jj-era wire fields (macapp, wr-agent, wr-vcs-model) — #266 follow-up

**What:** Remove the jj-era wire fields once no supported app or agent still sends or expects them:
`shared_root`, `barrier_root` and `backend` on wr-agent VCS/File/exec requests; `Commit.change_id`,
`is_working_copy`, `is_root`, `change_offset`, `divergent_siblings` and `RefKind::Ancestor` in
wr-vcs-model and the app's `AgentCommit`/ref decoding.

**Why:** They carry nothing after #266; they exist only so an older app and a newer agent (or the
reverse) keep decoding each other.

**Pros:** A smaller protocol and model, and no jj-shaped fields to confuse readers.

**Cons:** A wire change — it needs an agent protocol bump/gate, or proof that the launch-time hand-off
to the bundled agent (on for Nightly and Dev only, commit 26b9d881) is on for stable.

**Context / how to start:** #266 kept them deliberately (`Request`/`ExecRequest` are
`deny_unknown_fields`; older apps decode the Commit fields non-optionally); each is marked with a
`ponytail:` comment. Start at `vcs/crates/wr-agent/src/vcs.rs` `Request`/`ExecRequest`,
`vcs/crates/wr-agent/src/file.rs` `Request`, `macapp/WorkroomApp/Core/AgentVCSReader.swift`
`AgentCommit`, and `vcs/crates/wr-vcs-model/src/lib.rs` `Commit`.

**Depends on / blocked by:** #266 landing; stable hand-off or a protocol version gate.

**Priority:** P3 — cleanup, no user-visible effect.

### One OS watcher per subscription duplicates watches across windows (wr-agent) — #211 accepted shortcut

**What:** share one OS watcher per canonical root across subscriptions and connections, fanning events
into per-subscription coalescers.

**Why:** #211 creates one `notify` watcher per subscription. `AppStore` is per window, so N windows on
the same workroom, plus one `.git` watch per project per window, duplicate identical recursive
watches. Cheap on macOS FSEvents; on Linux inotify needs one watch per directory per watcher and
duplicates multiply toward `fs.inotify.max_user_watches`.

**Pros:** correct on both platforms with one OS watch per tree. **Cons:** a cross-connection registry
(refcounts, canonical-path keys, start/stop races) in the daemon that owns terminals, and a
shutdown-ordering case against per-connection teardown.

**How to start:** find the `gstack-shortcut(dec-8742d8a5-42ac-4348-827b-9c15d9330f5a)` marker at the
watcher creation site. Measure FSEvents duplication first; build the shared registry when the Linux
agent lands.

**Depends on:** Phase 3 Linux agent, or a measured FSEvents problem.

**Priority:** P3 — no cost on the only platform it ships on today.

### Listings above the 4 MiB capture ceiling fail instead of paginating (macapp + wr-agent) — #211 follow-up

**What:** raise the listing-specific cap (the reply ceiling is 16 MiB) or paginate `list`, so very
large repositories get a tree instead of a "too many files to list" failure.

**Why:** #211 makes an over-cap listing an explicit typed failure on both paths. Before, both paths
silently returned a stdout cut at an arbitrary byte, possibly mid-filename. A repository above about 70k
paths now sees an error where it used to see a truncated tree with a bogus last entry.

**Pros:** big monorepos get a usable Files panel. **Cons:** more memory per listing on the agent
(bounded by the shared `ACTIVE` pool) and, for pagination, a stateful protocol.

**How to start:** confirm users actually hit the error, then raise the cap for `list` only, keeping the
16 MiB `MAX_RESPONSE` as the hard bound and re-running the differential and boundary tests.

**Depends on:** #211 merged; evidence that the cap is reached.

**Priority:** P3.

### `XDG_CONFIG_HOME` never reaches the `gh` auth probe (macapp) — gh-flap eng-review follow-up

**What:** decide whether `XDG_CONFIG_HOME` (or another way of resolving gh's config dir) should reach
the NON-network `run` path that `WorkroomStatusResolver.resolveGitHubCLI` uses.

**Why:** `XDG_CONFIG_HOME` *is* in `StatusCommandRunner.forwardedAuthKeys`, but that allowlist is only
applied by `networkEnvironment`, i.e. behind `if network` in `run`. The gh auth probe is a plain `run`,
and the comment justifying the split says gh "carries its own token" — true, but gh FINDS that token via
its config dir. A user who sets `XDG_CONFIG_HOME` in `.zshrc` and launches from Finder therefore hands
gh a different config root than their terminal uses. Measured: an empty gh config dir returns
`{"hosts":{}}` on stdout with exit 0, which classifies as `.notAuthenticated` — a permanent false
"GitHub CLI not signed in" for someone who is signed in everywhere else. Same false claim the
cancelled-probe fix removed, reached by a completely different route.

**Pros:** closes the last known cause of a false "not signed in". **Cons:** widening the environment on
an automatic path is a deliberate, documented narrowness (`StatusCommandRunner` explains why a
wholesale transplant is refused for anything that runs without the user asking) — this is a security
posture question, not a one-line fix. A third allowlist ("non-secret, both paths") is probably the right
shape, and `GH_CONFIG_DIR` deserves the same thought.

**How to start:** `StatusCommandRunner.run`, where `if network` selects the environment. Decide the
allowlist question first, then apply to both paths.

**Depends on:** nothing.

**Priority:** P3 — real and measured, but it needs a policy decision, and the affected configuration is
uncommon.

### Deterministic tab lookup for content panes (macapp) — nav-history follow-up

**What:** `TerminalSessions.contentTab(matching:)` and `previewTabID(in:)` both resolve with
`.first { … }` over `tabsByTarget`, which is a **Dictionary** — unordered, so which tab they return is
not deterministic when two match. Resolve through `orderByTarget` (the strip order) instead, so "first"
means leftmost.

**Why:** `newPaneTab` deliberately bypasses the same-file dedup ("so the same-file dedup doesn't
collapse it back onto the anchor"), so ⌘D on a diff or changeset pane genuinely creates two tabs with
identical content identity. Back/forward replay now resolves through these lookups, which makes the coin
flip user-visible: replay could focus the pinned twin instead of the pane you were browsing in. Today
only two things hide it — replay prefers the tab the location was recorded in (step 1 of
`AppStore.applyLocation`), and the ≤1-preview invariant keeps `previewTabID` incidentally unique.

**How to start:** `previewTabID` and `contentTab(matching:)` in `Core/TerminalSessions.swift`; both have
`orderByTarget` to hand. Pin it with a test that builds twins via `splitFocusedPane` on a diff pane and
asserts *which* tab a lookup returns.

**Depends on:** nothing. Independent of the nav-history fix, which is what made it matter.

**Priority:** P3 (latent; replay's prefer-the-recorded-tab step shields the common path, and
`AppStoreContentNavigationTests.testReplayPrefersTheRecordedTab` pins that shielding).

### Structured diff model (`FileDiff` hunks) for the diff viewer (macapp) — 47b / VCS-foundation follow-up

**What:** Give `VCSProviding` a structured per-file diff (a `FileDiff` of hunks/lines) instead of the
current git-format unified-diff **text**, and rewrite `DiffViewer` to consume it — unlocking
ignore-whitespace, word/intra-line diff, per-hunk/line staging, and diff-edit (the jayjay feature set).

**Why:** The diff viewer today parses git-format text (`UnifiedDiff.parse`) fed by `GitProvider`
(SwiftGitX `Patch` → text). That's the deliberate
Option-1 first cut — it works and keeps one renderer — but text is a lossy intermediate for the
features above. libgit2 already exposes structured diffs natively (hunk callbacks), so a structured
model would be lib-native end-to-end. Deferred because no shipped feature needs it yet, and the
rewrite touches the whole diff UI (regression surface).

> Note: the earlier "evaluate libgit2 for git diffs" framing is obsolete — git already reads through
> SwiftGitX/libgit2 (status, changeset, working + commit diff, `fileContent`). The open question is no
> longer *which* git library, but *text vs structured hunks* at the `VCSProviding` seam.

**How to start:** Add a structured `FileDiff`/`Hunk`/`Line` model + a `VCSProviding.structuredDiff`
(or evolve `fileDiff`/`workingFileDiff` to return it); via `git_diff`/`git_patch` hunk callbacks. Reuse the existing `DiffCache` +
`maxDiffBytes` gate. Rewrite `DiffViewer` (and `IntraLineDiff`/side-by-side pairing) to consume hunks.

**Depends on:** the shipped Option-1 diff pipeline (`VCSProviding.fileDiff`/`workingFileDiff` +
`DiffResolver` + `DiffViewer`). Touches `VCSProviding` (`Core/RepositoryServices.swift`),
`LocalVCSProviding` (`Packages/WorkroomVCS`), `GitProvider`,
`Core/DiffResolver.swift`, `Views/DiffViewer.swift`.

**Priority:** P3 (build when a feature — ignore-whitespace / word-diff / staging / diff-edit — needs it).

### Three independent change-badge palettes (macapp) — conflict-status follow-up

**What:** the same change-kind badge is coloured by three separate mappings: `ChangeBadge`
(`Core/ChangeBadge.swift`, theme tokens — extracted from `ChangesPanel` when the conflict badge was
fixed), `ChangesetDetailView.badgeColor` (hardcoded `.green`/`.yellow`/`.red`/`.orange`), and
`DiffViewer.changeColor` (same hardcoded set).

**Why:** this split is *why* the conflict badge diverged in the first place — the panel had no orange
to reach for, so `.conflicted` borrowed deletion's red and a conflict read as a removal. Two of the
three mappings also ignore the active theme entirely.

**How to start:** have `ChangesetDetailView` and `DiffViewer` adopt `ChangeBadge.letter`/`.color` (and
the `tokens.conflict` colour) instead of their own switches. Note this restyles *every* kind in both
views, so it wants a deliberate visual pass rather than a drive-by change.

**Depends on:** `ChangeBadge` (shipped). Touches `ChangesetDetailView.swift`, `DiffViewer.swift`.

**Priority:** P3 (consistency + theme correctness; no functional bug).

## P3 — Terminal, panes, and focus

### Hand-off by snapshot when both agents share an engine sha (wr-agent) — #462/#463 follow-up

**What:** Carry each session through a hand-off as a libghostty snapshot instead of VT when the new
binary reports the same engine sha, falling back to VT otherwise.

**Why:** Since #462/#463 the hand-off sends each session only the newest history that fits its
share of 16 MiB, so coloured history is trimmed at every agent upgrade. A snapshot keeps all of it,
compressed.

**How to start:** `handoff.rs` (a table version carrying the snapshot and the sender's engine sha)
and `session.rs` `frozen`. ADR 0031 forbids snapshots across revisions; the same-sha check keeps
that rule.

**Priority:** P3, effort M. **Depends on:** #462/#463 landing (ADR 0051).

### Shell integration for macOS's built-in `/bin/bash` (wr-agent, macapp)

**What:** give Apple's `/bin/bash` (3.2) Ghostty's shell integration: OSC 133 command marks and
OSC 7 cwd, so the inline agent, the command-end title reset and cwd tracking work there.

**Why:** today it gets none, in persistent panes and in libghostty's own. Apple's bash ignores the
`ENV` startup path the integration uses, so `wr-agent` now starts it as a plain login shell, as
Ghostty does (`detectShell` in `src/termio/shell_integration.zig`). Homebrew bash 4.4+ is
unaffected.

**Context:** `--rcfile` does not apply to a login shell, so a fix needs another way in, such as a
`PROMPT_COMMAND` hook set from the environment. Probed 2026-10-14: `ghostty.bash` sourced from an
rcfile under bash 3.2 does report correct `133;D` exit codes, so the script itself works there.
Start at `vcs/crates/wr-agent/src/shell.rs` (`bash_integration`). Upstream declines it, so the
libghostty path would stay without it.

**Priority:** P3, effort M.

### Agent bootstrap (#231): two review findings the /ship pass deferred (macapp, wr-agent)

**What:** Two items the #231 review raised and the branch did not take.
1. `wr-agent hand-off` exit 92 covers both "nothing listening" and "accepted but did not greet in
   5 s"; `install.sh` and `AgentBootstrap` tell them apart by the CLI's stderr wording
   (`no agent listening`). Give did-not-greet its own exit code in `run_hand_off` and branch on it.
2. `ContainerHostDriver.shellQuoted` is a one-line forwarder to `PosixShell.quoted` (~14 call
   sites, plus `PersistentSessionService`); two older copies exist in `CommandLineInstaller` and
   `GhosttySurfaceView`. Point everything at `PosixShell.quoted`.

**Why:** 1 changes behaviour (a CLI wording change would silently read a dead socket as a live
agent); 2 is duplication.

**How to start:** 1 in `vcs/crates/wr-agent/src/cli/hand_off.rs` (`run_hand_off`, the 92 arms) with the
fixture's `over_ssh_the_bootstrap_*` test; 2 is mechanical.

**Priority:** P3, effort S each.

### The tab chip's ✕ close button is unreachable to accessibility (macapp)

**Why:** the tab chip carries its own `.accessibilityLabel`, which collapses the whole chip into ONE
accessibility element and makes every nested control unreachable (`TerminalTabStrip`'s own comment
says so). The ✦ diagnosis badge was fixed by announcing it in the chip's label and adding
`.accessibilityActions { Button("Show diagnosis") … }`. The nested ✕ carries its own
`.accessibilityLabel("Close <title>")` and is swallowed identically, so it is presumably also
unreachable to assistive technology. No UI test exercises it via accessibility, so this is inferred
from the documented behaviour rather than measured.

**What:** add a `Button("Close") { onClose() }` to the same `.accessibilityActions` block. The chip
already has a close affordance in its context menu, so this is politeness rather than a blocker.

**Priority:** P3, effort S.

### `Defaults` keys with dots in their names cannot be observed (macapp) — measured, NOT fixed (2026-09-03)

**What:** twelve `Defaults.Key`s use dotted `UserDefaults` names (`"sidebar.visible"`,
`"inspector.width"`, `"sidebar.width"`, `"sidebar.selectionTargetID"`, `"sidebar.collapsedProjects"`,
`"settings.selectedPane"`, `"onboarding.hasCompleted"`, `"vcs.lastFetch"`, `"app.lastSeenVersion"`,
`"app.whatsNewAttemptVersion"`, `"app.whatsNewAttempts"`, `"workroomsView.tabOrder"`), which is why
every launch logs a dozen `[Defaults] The key name must be ASCII…` faults.

**The warning is real, and measured — not inferred.** `Defaults` observes via raw KVO
(`suite.addObserver(self, forKeyPath: name, …)`, `Observation.swift:177`), and `UserDefaults` KVO
reads a dot as a key-path separator. A standalone probe on this OS: writing a flat key notified its
observer, writing a dotted key notified **nothing**, and both values read back correctly. Storage
works, notification does not.

**No live bug, which is why it is not fixed.** Audited `Views/` and `Core/`: none of the twelve is
observed — no `@Default`, no `Defaults.observe`, no `Defaults.publisher`. All are read/written
imperatively, which is unaffected.

**What was done instead:** a rule at the top of `Core/DefaultsKeys.swift` — never attach `@Default`,
`observe` or `publisher` to a dotted key; it compiles, runs, and silently never updates. Rename plus
a stored-value migration first, or the user loses that setting on upgrade.

**If it is ever fixed:** rename all twelve to dot-free names with a one-time migration (old key
present and new one absent ⇒ copy across, remove old). Deliberately NOT done before a release —
rewriting persisted user state to remove log noise and a latent trap is the wrong trade at that
moment.

**Priority:** P3, and arguably "leave it". Revisit only when someone actually needs to observe one of
these keys, or alongside an unrelated settings migration.

### Workroom split: ⌥⌘-arrow focus between workroom panes (macapp) — #23

**What:** `PaneTreeLayout.adjacentPane` is already generic and ready; only the key-monitor wiring is
missing for workroom panes. Deferred to avoid clashing with the terminal-level ⌥⌘arrows (which
navigate the focused workroom's *terminal* split), so it needs a precedence decision.

**Priority:** P3 (polish on a shipped feature).

### Quick-switcher deferrals (macapp) — #132 follow-ups

**What:** Two things the ⌥Tab / ⌃Tab switcher shipped without, deliberately. Independent of each
other.

- **MRU order in the ⌘O Open Workroom picker.** `SwitcherRecency` already answers "what did I use
  last", so `OpenPickerModel` could rank by it instead of alphabetically. Cheap, but it reorders a
  shipped, tested surface (`OpenPickerModelTests`) — hence deferred until we've lived with MRU in the
  switcher and know it feels right there first.
- **⌃-click on the pane rail is unverified.** ⌃-click is a secondary click, and the rail panel is never
  key, so it may not deliver a `.onTapGesture` at all. Needs a **real mouse** — this repo has twice
  been lied to by synthetic input (`macapp-textselection-swallows-taps`,
  `macapp-hover-slide-release-only`), so an XCUITest pass here would prove nothing.

**Why:** each of these was written down in the #132 plan's out-of-scope table and would otherwise be
lost with it.

**Depends on:** nothing.

**Priority:** P3 for both.

### Unify foreground-process detection onto argv0 (macapp) — issue #141 eng-review follow-up, filed 2026-08-17

**What:** `CodingAgentProcessRecognition.backend(forPID:)` (`CodingAgentUsage.swift`, backs the issue #49 inline
diagnosis badge) and the new `GhosttySurfaceView.foregroundExecutableName` (issue #141 favicon) both
resolve a live pane's foreground process via `proc_name`. Port the
argv0/`KERN_PROCARGS2` logic of the retired daemon's `SessionPTY.executableName(processID:)` (already
correct; the original is `git show 9ce6201f^:macapp/WorkroomSession/SessionPTY.swift`, and the Rust
agent has its own port, `87dcb476`) into a shared app-side helper, and use it from both call sites in
place of `proc_name`.

**Why:** `proc_name` is defeated by any CLI that renames its own process title post-launch — confirmed
case: Claude Code, whose `p_comm` reads as a version string ("2.1.232"), not "claude". No known live
bug today: both features have a title-based fallback (`CodingAgentTitleRecognition`/
`ToolLogoRegistry.tool(forTitle:)`) that catches Claude regardless. But every tool added to the
favicon registry is one more surface where this could matter if it also self-renames, and the daemon
side already proves the fix works.

**How to start:** Add a `ProcessArgv0` helper under `WorkroomApp/Core/`, ported from the retired
`SessionPTY.executableName(processID:)`. Replace `CodingAgentProcessRecognition.backend(forPID:)`'s
`proc_name`/`MAXPATHLEN` body with a call through the shared helper. Replace
`GhosttySurfaceView.foregroundExecutableName`'s inlined `proc_name` block the same way.

**Depends on:** nothing. Scoped out of the issue #141 PR deliberately (D1, plan-eng-review
scope-reduction) to keep that PR single-purpose; this session's review confirmed the trade-off
(3-file/2-target diff for a bug with no live symptom).

**Priority:** P3 — no known bug today; worth doing next time either recognizer needs to get sturdier.

## P3 — Inspector, window layout, and theming

### Search section for the right activity bar (macapp) — activity-bar follow-up

**What:** A functional Search pane (find in files / content) as a new right-activity-bar section.

**Why:** The activity bar (`ActivitySection` + per-section `subSections`) is built to grow; Search
was the first candidate but has no functionality yet, so it was dropped from the initial bar (v1
shipped Changes + Files) to avoid a visibly-empty icon reading as unfinished.

**How to start:** Add a `.search` case to `Core/ActivitySection.swift` (label +
`systemImage: "magnifyingglass"` + its `subSections`) and a real Search pane body, wired into
`RightInspector.sectionBody(for:)`. A new `InspectorSectionKind` may be needed for the sub-section
identity. The DEBUG-only feature-flag staging pattern (considered and rejected for v1) is one option
to ship the scaffold before the search is real.

**Depends on:** the right activity bar (shipped). Touches `Core/ActivitySection.swift`,
`Views/ChangesPanel.swift` (`RightInspector`), a new `Views/SearchPanel.swift`.

**Priority:** P3 (new feature; not blocking).

### Raise the inspector's 520pt width cap (macapp) — column-layout follow-up

**What:** Decide whether `InspectorColumn`'s `maxWidth = 520` (and `SidebarColumn`'s 240-360) is still
the bound we want, now that the layout no longer forces the trade-off.

**Why:** 520 was inherited from the `NavigationSplitView` era, where it was a *safety* ceiling, not a
design choice: the native split shrank the `sidebar | detail` columns **proportionally** as the
inspector grew, so a wide inspector clipped the sidebar's labels even at a 1900px window, and the
private `NSSplitView` subclass refused `setDelegate:`/`setHoldingPriority:`. That machinery is gone —
`RootView.splitView` lays the three columns out itself (`SidebarColumn` | detail | `InspectorColumn` +
`ActivityBar`, inside a detail-only `NavigationSplitView` kept purely for the toolbar/hover context),
each column with its own min/max and its own persisted `Defaults` width. The sidebar holds its floor
and only the detail yields, so a wider inspector is now a one-constant change.

**How to start:** raise or drop `maxWidth` (`Views/InspectorColumn.swift:23`) and check the widest
panes at the new size (`DiffViewer` side-by-side, `ChangesetDetailView`, `HistoryPanel`) against the
detail column's own floor — a usable terminal width is the real constraint now, not the sidebar.

**Depends on:** the hand-rolled column layout (shipped: `RootView.splitView`, `SidebarColumn`,
`InspectorColumn`, `Defaults.sidebarWidth`/`inspectorWidth`).

**Priority:** P3 (only worth changing if a wide inspector is a real workflow need; 520 is a fine
default and the squeeze that made it load-bearing is fixed).

### Keyboard + VoiceOver parity for the edge-hover reveal (macapp) — #56 follow-up

**What:** Make the edge-hover sidebar reveal (issue #56) first-class for keyboard / VoiceOver users:
move keyboard focus into the panel when it reveals, restore focus when it hides, and post a
VoiceOver announcement on reveal/hide.

**Current state:** The reveal ships pointer-first (`Views/EdgeRevealSidebar.swift`). Escape-to-dismiss
is wired (`.onExitCommand`) and the panels carry `sidebar.reveal.{leading,trailing}` accessibility
identifiers, but there's no focus management or VO announce. Persistent keyboard/AX access already
exists via the View-menu toggles (`View ▸ Projects`, `View ▸ Notifications`) and the toolbar
sidebar/inspector buttons, so the docked sidebars remain fully reachable without a pointer — this is
polish, not an accessibility blocker.

**Why:** a hover-only affordance is invisible to keyboard-only and VoiceOver users; focus + announce
make the transient panel behave like a real sidebar for them too.

**How to start:** drive first-responder when `EdgeRevealReducer.revealed` flips (focus the panel's
list, restore the prior responder on hide); post `NSAccessibility.post(element:notification:)` on
reveal/hide. Focus management in a transient overlay is finicky (focus stealing, restore-on-hide
races) — prototype carefully and test with VoiceOver on.

**Depends on:** the #56 reveal panel (shipped).

**Priority:** P3 (polish; persistent keyboard/AX access already exists via the menu/toolbar toggles).

### Theming: auto-pair user `~/.config` themes into families (macapp) — #36 follow-up

**What:** Let loose theme files a user drops into `~/.config/ghostty/themes` surface as first-class
theme *families* (a light + dark pair) in the picker.

**Why:** #36 ships a curated set of pair-complete bundled families only — the picker lists those.
A user with their own theme files in `~/.config/ghostty/themes` currently has no way to pick them
from the picker (ghostty still resolves them for the *terminal* when a bundled name collides, since
`themePreview`/resolution favour `~/.config`, but they aren't selectable). Inferring families from
user files would make them first-class.

**How to start:** In `Core/ThemeService.swift`, add discovery of `~/.config/ghostty/themes` and
infer families from loose user files — e.g. name-suffix heuristics (`X` / `X Light`, `X Dark` /
`X Light`), or read an optional user manifest. Merge inferred families into the picker's family
list. Handle the ambiguous cases: a single-variant user theme (no obvious partner); a name that
collides with a bundled family.

**Depends on:** the #36 families model shipping first (done).

**Priority:** P3 (bundled families cover the common case; this is for users with custom schemes).

**Prior art (2026-08-06):** the 27→58 family expansion built and threw away exactly this heuristic
offline — suffix pairing (`X Dark`/`X Light`, `X`/`X Light`, `X Night`/`X Day`) over 604 candidate
files, plus dark/light classification by `perceivedBrightness(background) > 0.5`. It found 58 pair-
complete clusters. It also showed what a naive version adopts: another product's brand pair (`Muxy`),
a theme that fails the rail's contrast floor (`Violet Dark`, 3.94:1), six stock black-on-white
terminal defaults, and a byte-identical duplicate (`Zenbones` ≡ `Zenbones Light`). So the heuristic is
the easy half; the deny-list and a contrast gate are the real work.

### Ship the remaining vetted theme families (macapp)

**What:** Three accessibility families — `GitHub Colorblind`, `Pierre`, `Adwaita` — and ten
same-family shade variants: Catppuccin Frappé + Macchiato, Tokyo Night Storm + Moon, Rosé Pine Moon,
Kanagawa Dragon, Gruvbox Hard, Modus Tinted, GitHub Dimmed, Nord Wave.

**Why:** all were swept against the real contrast floors during the 2026-08-06 expansion and came back
clean, so the measurement work is already done. The ten variants need only **one** new file each — the
light side already ships.

**Pros:** near-zero cost per family; accessibility is the one need in the recorded inclusion criterion
(`Resources/ghostty/themes/SOURCE.md`) that stays thinly served even after `GitHub High Contrast` and
`Xcode High Contrast` landed.

**Cons:** criterion rule 3 (distinct palette, not a shade of one we ship) argues *against* the ten
variants — they are exactly what that rule was written to exclude. Record that tension rather than
pretending the criterion endorses them. The a11y families' light sides are plain `#ffffff`.

**How to start:** re-run the sweep before shipping — upstream theme files move, and `themes/CHECKSUMS`
pins only what we already vendored.

**Priority:** P3.

## P3 — Pull requests and GitHub

### At-a-glance review status in the sidebar / collapsed PR header (macapp) — #52 follow-up

**What:** Surface a compact review-status glyph (the aggregate `reviewDecision` — approved /
changes-requested / review-required) on the sidebar workroom row or the collapsed "Pull Request"
section header, next to the existing CI glyph — so review state is visible without expanding the
panel. Directly serves issue #52's framing ("so we can go visit the PR when needed").

**Current state (re-verified 2026-07-25):** still expanded-panel only. `#77` added a PR-state badge to
the PR header (`ChangesPanel.swift` `prNumberLink`) and the `reviewDecision` aggregate label sits above
the reviewer rows in the inspector (`PullRequestPanel.swift` `PRPresentation.reviewLabel`) — but the
sidebar workroom row still shows dirty/CI only (`ProjectSidebar.swift`, via `VCSStatusPresentation`),
and the background sweep still skips PR resolution (`resolvePRRaw` is called only from
`scheduleSelectedStatusRefresh`; `refreshWorkroomStatuses` runs local + CI). The aggregate is the
natural feed for a glyph.

**Why:** a glance from the sidebar beats expanding the panel per workroom; matches how CI status
already reads at a glance.

**How to start:** the blocker is data freshness — the PR (and thus `reviewDecision`) is resolved
**only on selection** (`scheduleSelectedStatusRefresh`), not in the bounded background sweep
(`refreshWorkroomStatuses` / `runCISweep` in `Core/AppStore+WorkroomStatus.swift`). A sidebar glyph
needs PR resolution added to the sweep (a third probe stage, bounded like CI, with its own TTL), then
a `VCSStatusPresentation`-style mapper for the review glyph reused by the sidebar row + collapsed
header (`ChangesPanel.prIndicator`).

**Depends on:** the #52 `reviewDecision` aggregate (shipped). Bigger than a UI tweak — it adds a PR
sweep stage.

**Priority:** P3 (strong UX win, but the background-sweep work makes it its own chunk, not part of #52).

## P3 — Notifications and run commands

### Program status for non-daemon panes (macapp, upstream Ghostty) — #358 deferral

**What:** An upstream GhosttyKit apprt program-status action. The app's own terminal ignores
`.program_status`, so non-daemon panes (run commands, fixture panes, and every pane while the agent
is unavailable and panes fall back to a plain shell) never get OSC 7501. An upstream
apprt action would cover them; daemon-backed panes still need wr-agent for reattach and remote.

**Why:** #358 shows "needs you" only for daemon-backed panes.

**How to start:** Check whether Ghostty's `src/termio/stream_handler.zig` still ignores
`.program_status` at the pinned engine; if so, propose an apprt action upstream and feed it into
`ProgramStatusMonitor`'s rollup for non-daemon panes.

**Depends on:** #358 landing.

**Priority:** P3 (deferred in /autoplan, 2026-10-14).

### Auto-emit OSC notifications on command completion (macapp)

**What:** An opt-in shell hook (zsh `precmd`/`preexec`, or OSC 133 prompt markers) that emits
`printf '\e]9;<cmd> finished\a'` after a command that ran longer than N seconds, so notifications
fire automatically without the user wrapping commands.

**Why:** Notification detection is explicit-only (issue #10 review, decision 1.1b): we notify on
OSC 9/99/777 + bell, not raw output. That's precise but silent for a bare `make test` that emits
nothing. A shell hook closes that gap so the common "my build finished" case just works.

**How to start:** Source a hook into the login shell launched by
`TerminalSessions.makeTerminal` (`-l`), or document it for the user to add. Decide OSC 133 vs a
`precmd` that emits OSC 9. Keep it opt-in (injecting into the user's shell is invasive). Note the
OSC 133 *command-finished* marker is already parsed app-side
(`GhosttyRuntimeAdapter` handles `GHOSTTY_ACTION_COMMAND_FINISHED`, used today to clear the
running-command title) — so this task is about *emitting* OSC 9 on completion, not parsing it.

**Depends on:** the notifications feature (#10) — **now landed**; the OSC 9 desktop-notification
handler exists to receive it (`GhosttyRuntimeAdapter` `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` →
`AppStore.handleActivity`).

**Priority:** P3 (amplifies the shipped feature; the feature is useful without it for tools that
already emit OSC/bell).

### Notification preferences (macapp)

**What:** Per-workroom (or per-terminal) mute, a notification-sound toggle, and respecting macOS
Focus / Do-Not-Disturb.

**Why:** Now that notifications exist, a noisy cooperating tool (a watcher firing OSC on every
rebuild) will need silencing without losing notifications from other terminals. Focus/DND respect is
largely automatic via `UNUserNotificationCenter` (the system honors Focus at delivery time);
per-workroom mute is app logic.

**How to start:** A mute set keyed on `TerminalTarget.ID`, checked in
`NotificationCenterStore.record(...)` before creating an item / posting. Persist with a
`Defaults.Keys` entry in `Core/DefaultsKeys.swift` (the app uses `sindresorhus/Defaults` now —
consistent with `theme` / `copyOnSelect`, not `@AppStorage`). A sound toggle gates `content.sound`
in `SystemNotifier.post()` (today hardcoded to `.default`).

**Depends on:** the notifications feature (#10) — **now landed**
(`macapp/WorkroomApp/Core/NotificationCenterStore.swift`, `Core/SystemNotifier.swift`).

**Priority:** P3 (the feature is usable without it; add when a real terminal proves too chatty).

### Run-terminal persistence / auto-restart across relaunch (macapp) — #7 follow-up

**What:** Restore (or auto-restart) a workroom's run command when the app relaunches, rather than
losing it. Optionally remember which workroom had a running run command and offer/auto-run it on next
launch.

**Why:** The run-command feature (#7) keeps run terminals in-memory (consistent with all terminals —
`TerminalSessions` is session-only), and auto-run fires only at workroom *creation*. So quitting the
app with a dev server running loses it, and there's no auto-restart on launch. For a long-lived
"always have my dev server up" workflow that's a gap.

**How to start:** Persist a small per-target marker (e.g. `Defaults` set of target ids that had a
running run command), and on launch — after the project list loads and a workroom is selected — offer
or auto-start its run command. Decide the policy (auto vs prompt) and how it interacts with the
existing creation-time auto-run. Reuse `AppStore.startRunCommand(for:)` and the run-state model
(`runTabIDByTarget` / `runningTargets`).

**Depends on:** the #7 run-command feature shipping first (`macapp/WorkroomApp/Core/AppStore.swift`
run-command actions, `Core/TerminalSessions.swift` `addRunTab`).

**Priority:** P3 (deferred from #7 — the feature is useful without it; surfaced by the eng-review).

## P3 — Performance and diagnostics (WORKROOM-2B follow-ups)

### Main-thread timing from a real hang (macapp) — WORKROOM-2B follow-up

**What:** a bounded way to learn *how long* the main thread was held, and by what, from a hang report on
a user's machine. Three candidates: Sentry profiling started and stopped around suspect windows,
`os_signpost` intervals around panel body passes, or a watchdog breadcrumb capturing what the app was
doing when the stall began.

**Why:** WORKROOM-2B cost a full session of inference because the report was a single unsymbolicated
main-thread sample. The dSYM upload fix (`.github/workflows/nightly.yml` + `Scripts/release.sh`) closes
the *naming* half — frames will have function names now. Nothing tells us the duration or the shape of
the stall.

**Verify FIRST, before implementing anything:** whether Sentry's continuous profile chunks actually
attach to macOS **app-hang** events. If they don't, profiling buys nothing for this use case and the
signpost/breadcrumb options win. `Core/SentryConfig.swift` already configures profiling with
`.trace` lifecycle and `sessionSampleRate = 1.0`, but the app opens no transactions, so it never runs —
that is why the option looked free and isn't.

**Known caveat (from the eng review):** sentry-cocoa 9.19's manual lifecycle requires an explicit
`SentrySDK.stopProfiler()`. A launch-start-never-stop profiler is outside documented usage, costs CPU
and upload volume continuously, and could itself stall — which is why it was cut from the fix rather
than shipped on nightly.

**Depends on:** the dSYM upload landing (symbols are a prerequisite for any of this being readable).

**Priority:** P3 — until the next hang report, symbols alone may be enough.

## P3 — Remote workrooms

### Ask boxd for a non-interactive account check (macapp) — boxd first-time setup follow-up

**What:** Ask boxd for a documented way to ask "who is signed in" that fails instead of starting the
browser login, such as `boxd auth --json --non-interactive`. Once it exists, drop Workroom's read of
boxd's private `credentials.json`.

**Why:** boxd 0.2.23 starts its browser login from any account command when signed out, even with
no terminal (measured 2026-10-13). Workroom avoids that by running boxd only when the private
credentials file holds a token (never passing it as `BOXD_TOKEN`, which stops boxd writing ssh
details). If boxd renames the file's `token` key, boxd creates are blocked with "Workroom needs an
update" until Workroom follows. If boxd moves the file, deletes fail with "not signed in to boxd"
too, and signing in again doesn't help.

**Pros:** Removes the design's only deliberate lock-out case and its dependency on a private file.

**Cons:** Depends on boxd shipping it; nothing to do in this repo until then.

**Context / how to start:** `docs/designs/boxd-first-time-setup.md`, section 1 (the guard in
`BoxdHostDriver.cli(...)`) and Open Question 3. Ask boxd; when the flag ships, make `account()` call
it and delete the credentials-file read.

**Depends on / blocked by:** boxd shipping the flag; the boxd first-time setup work landing first.
