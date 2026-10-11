# TODOs

> Grouped by priority, then by area. Within a group, cheaper/higher-leverage first. Each entry states
> what it is, why, how to start, what it depends on, and its priority. Completed work is summarised in
> **Recently done** at the bottom — including the traps found while doing it, which are the parts worth
> reading before touching the same code. Full write-ups for finished items live in git history.

## P0 — before the next release

None open. The crossing-`keep` flake entry went with the test, `keep` and the prompt card in #380.

## P1 — before GA

### Finish removing base machines (macapp, codaset) — #395 follow-ups

**What:** The rest of the remove-bases plan (claims 2, 2.1, 2.2, 3, 3.1, 3.2, 4.0). #395 made
every new remote workroom a fresh host with its own clone and took `deriveFromBase` out of every
driver. It did not touch the bases older builds already made.

**Why:** Each project that had a remote workroom still records a base per provider, and those
machines keep running. On exe.dev they never stop. On boxd they hibernate after four hours but keep
their disk. Nothing uses them now. Only Delete Project takes one down.

**Context:**
- **Retire at launch (claims 3, 3.1):** `RemoteHosts.adopt` destroys every base this build owns
  with `RemoteProvisioning.destroyBase`, then drops its record. A base it cannot remove (signed out
  of its provider) keeps its record, and the next launch tries again. Release and Nightly share one
  config (`cmd/claim.go:15`). A Release build without #395 would make a new base at its next create,
  and Nightly would retire it again. So ship #395 to stable first, or skip bases another build
  provisioned.
- **Drop the legacy model (claims 2, 2.1, 2.2):** once bases are retired, remove
  `HostDescriptor.bases`/`allBases`, `RemoteWorkrooms.base(in:for:)`, `removing`, `deleteBase`,
  `registrations`' fallback to a base's repository, and the Delete Project sheet's "base machine"
  text. Before the fallback goes, stamp each older workroom's descriptor with its base's
  `repository`, or those workrooms lose PR and CI status.
- **Codaset (claim 4.0):** remove the `base_clone_token` route (`app/controllers/broker/grants_controller.rb`)
  after the first stable release with #395. Older builds still call it until then.
- **Release note (claim 3.2):** the first release with #395 says new remote workrooms clone their own
  repository, and that the app removes old base machines (once claim 3 ships).

**Effort:** M
**Priority:** P1
**Depends on:** #395 merged. Deferred from plan: the remove-bases html-plan
(https://claude.ai/artifact/1tzAi15Cr1hGHV39UTSnny).

## P2 — perf, correctness, and the next VCS phase

### UI tests: stale skip entry, session-isolation wiring check, close-the-right-pane (macapp) — UI-test-merge review follow-up

**What:** Three items left from the pre-landing review of the UI-test merge branch.

- **Stale skip entry.** `APP_UITEST_FLAGS` still names `AgentResumeUITests`, which was deleted with
  the Resume feature in `67cb53ed`. Drop it from the Makefile and from `test-invariants_test.sh`
  (its `want_flags` string must change with the Makefile).
- **Session-isolation wiring.** A fixture-launch UI check that pins the session-isolation launch
  wiring in the routine run. Today only `SessionRestoreUITests` exercises that wiring, and the
  Makefile skips it by default. The `APP_UITEST_FLAGS` comment states that gap.
- **`PaneTitleBarUITests` passes on wrong behaviour.** It closes a pane and checks only that the
  count drops, so closing the wrong pane passes (the doc comment names that defect). Split Down is
  checked by count only. Assert which pane survived.

**How to start:** Each file you touch needs its class re-run with
`make app-uitest APP_UITEST_FLAGS="-only-testing:…"`.

**Depends on:** nothing.

**Priority:** P2 for the stale skip entry (two lines); P3 for the rest (deferred in /ship review,
2026-10-06).

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

### Credential broker clients: check the Keychain item's access (macapp) — #251 review follow-up

**What:** The real Keychain calls in `BrokerCredentials.SecretStore.keychain` are untested (tests use
the stand-in), and `kSecAttrAccessibleAfterFirstUnlock` on a login-keychain item was never measured.

**How to start:** Sign in on a Dev build and on a Developer ID Nightly once codaset.dev serves the
broker, and check the item's access list in Keychain Access. The question is whether each app
signature reads the item after login without an authorization prompt.

**Depends on / blocked by:** codaset#43 deployed.

**Priority:** P2, effort S.

### Ordinary connection failures blank the PR/CI badges (macapp) — #207 eng-review follow-up

**What:** Classify plain connection failures (`error connecting to api.github.com`, `dial tcp`,
`no such host`, `connection refused`) as `keepPrior` in `WorkroomStatusResolver.ghPreflight`, so the PR
panel, checks list and CI badge keep their last state when the Mac goes offline mid-session.

**Why:** `ghPreflight` returns `keepPrior` only for a timeout, a signal, or stderr containing
`rate limit`, `503` or `timeout`; every other non-zero exit is `.absent`. A fully offline `gh pr list`
therefore blanks the PR panel today. Found by the #207 outside voice while checking a claim in that
plan ("network off keeps the prior state") that the code does not support. It is old behaviour, not
something #207 introduced, and #207 deliberately leaves it alone.

**Pros:** One change in the shared classifier fixes every `gh` probe at once (PR, checks, CI, and the
repository lookup #207 added, which reuses `ghPreflight`).

**Cons:** It matches `gh`'s English error text, which varies by `gh` version and locale, and it decides
a product question: offline, is stale data better than a blank panel? `keepPrior` shows stale state as
if it were current.

**Also in `ghPreflight`:** the `503`/`timeout` rule is a bare substring match on stderr, and `gh`'s
stderr echoes repository names, so a repository called `timeout-lib` reads as a transient blip
instead of "absent". Match `HTTP 503` / `rate limit` instead when this is touched. (The repository
lookup #207 added is a new call site for the rule.)

**How to start:** Drive each error string through `classifyPR`, `classifyChecks`,
`classifyCheckRollup` and `resolveRepository` (all go through `ghPreflight`) before touching the
classifier. `gh` has no machine-readable offline code; `gh auth status --json hosts` already tells a
transport failure from a 401 (#86), so it may be a better signal than string matching.

**Depends on / blocked by:** None. Do it after #207 lands so the repository lookup exists to test.

**Priority:** P2, effort S.

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
writes, no auth prompt, no account concept for git in a local workroom. (Remote workrooms are the
exception: they get short-lived repository tokens from the credential broker, and the Mac signs in to
it with a Secure Enclave key; see `docs/designs/remote-workrooms.md` OQ20.) The user's own helpers (`osxkeychain`, GCM, `!gh auth git-credential`,
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
`DiffResolver` + `DiffViewer`). Touches `Core/VCSProviding.swift`, `GitProvider`,
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

## Recently done

Condensed from the long status notes this file used to carry at the top; the full write-ups are in git
history. Kept here for the parts that stay useful: what changed, and the traps found doing it.

**2026-10-06 — the never-built lifecycle shim's leftovers are out of the agent (#257 review, P1).**
The `<socket>.wake` verdict file (`write_verdict`, `retire_verdict`, `VERDICT_STOPPED`,
`verdict_path`), the `verdict_written` status field with the app's `verdictWritten`, and the
classifier's `net_masked` input with its self-call tests are gone. A slow disk can no longer hold
up the next heartbeat. `wakefulness::stop()` keeps what the retire did that still matters:
`running: false`, and a service thread that never comes back once `serve` has exited. The trap:
`wr-wakeshim` STAYS on `EXCLUDED_WITH_DESCENDANTS`. A code comment said the golden fixtures had no
such process, but every one of the ten traces runs the measurement shim under that name (304 to
1,055 mentions each), and dropping it made `1-detached-full-r0` replay BUSY where the fixture says
IDLE. The comment now says so. A box that ran an older agent keeps its last `<socket>.wake` (and
any `.tmp`) beside the socket for good, since only the removed retire step deleted it; nothing reads
it, so it is left there rather than cleaned up by new code.

**2026-10-05 — the wakefulness net filter holds on a real boxd box (#215 follow-up, checked during
#257).** A default-created boxd machine lists `eth0` with a `device` entry and no `brport`,
`docker0` as a `bridge` (link down, no container running) and `lo`, which is exactly the shape
`crosses_the_box` expects: eth0 counts, the bridge is internal. The boxd confirmation run did not
need repeating. The same probe found that boxd's idle meter ignores the box's own background chatter
(40-140 bytes per 10 s on eth0) but counts one UDP datagram to the default gateway, which is how
#257 keeps a busy box awake.

**2026-10-05 — `a_relay_with_no_agent_fails_fast_and_says_so` flaked because another test's child held its
"stale" socket open (#334 ship follow-up).** It once failed with the relay exiting 0 instead of 92 on
`stale.sock`, while `make app-test` loaded the machine. The relay was right: the socket was still
listening. On macOS, Rust std creates a socket with a plain `socket()` and marks it close-on-exec in a
separate call (`std/src/sys/net/connection/socket/unix.rs`, the non-`SOCK_CLOEXEC` arm), and its
`posix_spawn` path sets no `POSIX_SPAWN_CLOEXEC_DEFAULT`. A child that another test thread spawns in that
gap inherits the listener and keeps it listening after the test drops its copy. The relay connects,
the child exits, the queued connection is dropped, and the relay's read loop ends with exit 0. Load
widens the gap. Measured with a standalone probe that binds, drops and connects 20,000 times: 0
connects with no spawning, 396 and 371 with another thread spawning short-lived children. The test now
binds the stale socket in a forked child that `_exit`s at once (`stale_socket` in
`remote_transport.rs`). `a_stale_socket_stays_stale_while_children_are_spawned` makes 1,000 of them
while another thread spawns. It fails with an in-process bind (135 of 1,000 connected) and passes with
the helper in 1.9 s. Linux is unaffected: std uses `SOCK_CLOEXEC` there. **Trap: the agent has the same
gap.** `pty.rs`'s `forkpty` child calls `execve` without closing stray descriptors, so a session shell
spawned while the agent is mid-way through creating a socket (an accepted client, a forward's listener)
inherits it for the shell's lifetime. Fixed in #352: the child closes every descriptor but its terminal
and the exec-error pipe before `execve`.

**2026-10-05 — `ReverseForwardTests.testAReconnectWhileTheOldListenerHoldsThePortReopensOnceItLetsGo` is no
longer flaky, most likely fixed by the `EchoServer` double close (#350, entry below).** Before the fix it
failed 5 runs in 35 (3 of 15 on `workroom/cyan-brush` and 2 of 20 on a clean `origin/master`, 2026-10-04,
`-only-testing:WorkroomAppTests/ReverseForwardTests -test-iterations 10`), at three places: `roundTrip`
reading 0 bytes of 5, "the port was never contended", and "never reopened". After the fix it passed 40
of 40 with the same command (10, then 30 iterations). At the old rate, 40 straight passes would happen
about 1 time in 500 by chance. Why the double close fits: XCTest orders this class case-insensitively,
so the two tests that stopped an `EchoServer` twice (`testAnOpenAfterTheTargetMovesCarriesToTheNewTarget`,
`testAnUnreachableTargetEndsTheConnectionAtOnce`) run just before this one in every iteration. Their
stray close can land on a socket this test's forward or agent connection is using, and every failure
mode above is a socket that stops answering. The chain is inferred, not traced. The registry itself
(`BrokerReverseForwards`) was not changed. If the test fails again, reopen this, and start where the old
entry did: pin which step loses the race, the fixed 3 s sleep or the 5 s reopen deadline.

**2026-10-05 — the guarded-descriptor `EXC_GUARD` kills of test workers: a test fixture closed a
descriptor twice (#350).** Test workers were killed by `EXC_GUARD` (`GUARD_TYPE_FD`): once locally in
`VCSProviderConformanceTests` (2026-10-04) and once on CI in `VCSRemoteIntegrationTests` (run 37334065057,
PR #349). Each time, a `Pipe`'s `FileHandle` closed a number it believed it owned and found a guarded
descriptor there. Two `PortForwardingModelTests` "Host connection lost" failures on #349's CI had no
`EXC_GUARD` and are only suspected to be related. The cause: `ReverseForwardTests` stopped an
`EchoServer` by hand, and `tearDown` stopped it again. `EchoServer.stop()` was a bare `close(listener)`,
so the second call closed whatever had reused the number. Measured with `fcntl(F_GETPATH)` just before
the second close: it was `AgentHarness`'s `agent.err` file handle. That handle closes the number again
when it deallocates, so one extra close passes from owner to owner until it lands on a free number or
a guarded one. In all three failing CI runs, `ReverseForwardTests` ran earlier in the same worker. The
chain to each crash is inferred, not traced. `stop()` is now idempotent, like `TCPClient.close()`.
Closed after three clean serial `make app-test` runs (`-parallel-testing-enabled NO`, 3257 tests each),
with no Workroom crash report and no descriptor `EXC_GUARD` in the system log. That cannot rule out a
second, rarer double close, so reopen this if the kill comes back. **Traps.**
- A second `close` of a raw descriptor is not a harmless `EBADF`: the number is usually reused at once,
  so it closes someone else's file. Any fixture whose `stop()` is a raw `close` must be idempotent.
- On macOS, closing a descriptor wakes a thread blocked on it: `accept` fails `EINVAL` and `recv` fails
  `EBADF` (C probe). So `FakeAgent.stop()`, which closes while its threads may use the sockets, can only
  misbehave in the gap when a thread is between calls. It was not the cause.
- A `close()` interposer injected with `TEST_RUNNER_DYLD_INSERT_LIBRARIES` (and
  `ENABLE_HARDENED_RUNTIME=NO`, without which dyld ignores it) hangs the test host before it connects,
  even for one class. The same build without it runs. Cause unknown.
- To find what ran before a CI crash: `gh run download <run> -n xcresult-ci`, then
  `xcrun xcresulttool export diagnostics`. The diagnostics' `scheduling.log` lists each worker pid's
  classes in order, and its `.logarchive` holds ReportCrash's `EXC_GUARD` line.
- The system log is full of unrelated `EXC_GUARD`s: menu-bar apps, and WebKit's GPU and Networking
  helpers once per run. Those are `type=0x1` (Mach port). A descriptor guard is `GUARD_TYPE_FD`, `0x2`;
  filter for the test host's process.

**2026-09-22 — the wakefulness net signal no longer counts container bridges.** `parse_net_dev` took
every interface but `lo`, so a container's traffic was counted on its veth, its bridge, and again on the
uplink. Measured in Docker's VM: one `pg_isready` a second between two containers is 1804 B/s on their
veths, 3.6x the 500 B/s busy threshold with nothing leaving the box. The filter reads the kernel's own
classification, not interface names. It skips a bridge (`/sys/class/net/<if>/bridge`) that no default
route leaves by, and a device-less port (a veth or tap) whose `master` is such a bridge. **Two traps.**
"Physical devices only" is wrong: inside a container `eth0` has no `device`, so it zeroes the signal.
"Every bridge and device-less port" is wrong too: an LXC container that bridges its own veth `eth0` into
`br0` then loses its whole uplink. A byte-count fallback for that case failed review, because once a
tunnel (`tailscale0`, `wg0`) carries one byte the fallback switches off for good, and the box reads idle
under load. The default route is the uplink as the kernel routes it, so that bridge and everything on it
count. `procfs.py` mirrors the rule, so future recordings measure the signal that ships. The golden
fixtures carry pre-summed bytes and are unaffected.

**2026-09-22 — the #218 review's port-forwarding follow-ups.** The agent sets `TCP_NODELAY` on the
socket it connects to the target (`forward.rs`), matching the app's accepted socket. The forward's send
and drain timeouts are injectable through `AgentForwardService.listen` and each has a test that fails at
the 30 s default. A sub-second `SO_SNDTIMEO` puts its fraction in `tv_usec`, because `tv_sec: 0` means
no timeout. **Trap: on `EMFILE`, XNU has already dequeued and closed the connection.** The old comment
said it "stays in the backlog" and gets retried after the backoff. Measured: the client reads EOF, and
a retried `accept` returns `EWOULDBLOCK`. The listener did survive, but the lost connection went
unreported, so the row now says why. `testTheListenerSurvivesRunningOutOfDescriptors` lowers
`RLIMIT_NOFILE` to just above what the process holds, rather than exhausting the host's real limit.

**2026-09-03 — the 9 "Publishing changes from within view updates" faults per launch: found and
fixed. Both filed hypotheses were wrong, and so was the blocker.** The entry said Xcode's runtime-issue
breakpoint was the only way forward and "cannot be set from the CLI, which is the only reason this
entry is still open". No debugger was needed at all: `libsystem_trace` records a backtrace at
emission for every fault-type message, so

    log show --last 1m --predicate 'process == "Workroom Dev" AND eventMessage CONTAINS "Publishing changes"' --backtrace

hands over all 9 stacks with ZERO timing perturbation — which is what defeated the previous session's
`ObservableObjectPublisher.send()` breakpoint. App frames come back as image UUID + offset; the app's
own code is `Workroom Dev.debug.dylib` (`dwarfdump --uuid` to match it), symbolicated with
`atos -o <dylib> -arch arm64 -l 0 <offset>`. Reach for this FIRST for any SwiftUI runtime issue.

All 9 are one call path, not nine sources:

    WindowResolvingView.viewDidMoveToWindow()   WindowRegistry.swift
    closure #1 in RootWindow.body.getter        WorkroomApp.swift
    WindowRegistry.register(window:store:)
    WindowRegistry.assignWindowNumberIfNeeded
    AppStore.windowNumber.setter                @Published

`WindowAccessor` is an `NSViewRepresentable`, so SwiftUI runs `viewDidMoveToWindow` WHILE it installs
the representable's backing view — inside a view update. `register` then synchronously set
`AppStore.windowNumber` (`@Published`) and, via `recomputeBadge`, `aggregateUnread` (`@Published`).
Neither of the entry's two candidate mechanisms was involved: not `AppStore`'s 65 `@Published`
generally, and not `Defaults.Observable` (whose `objectWillChange.send()` runs from a `@MainActor`
Task, which cannot start until the main actor yields — i.e. never during a synchronous update).

**Fixed** by deferring those two writes with `Task { @MainActor in … }`, which for the same reason
cannot run until the update finishes. Measured with the same command both ways: **9 faults per launch
before, 0 after.**

**The trap, and why the obvious fix is wrong:** don't defer the `WindowAccessor` callback itself, and
don't defer `register` wholesale. `attachWindow` depends on running PRE-DISPLAY — it sets the window
frame (issue #70), hides the title bar before the open-time flash, and claims the saved session — and
the rest of `register` must stay synchronous too, because a window can become key immediately and
`didBecomeKeyNotification`'s handler bails when `store(for:)` can't find it yet. Only the window
number and the Dock badge are safe to slip: both are derived display state nothing reads that turn.

Pinned by `MultiWindowTests.testWindowNumberIsAssignedAfterRegisterReturnsNotDuringIt` (a SwiftUI
runtime issue can't be asserted from a unit test, so what it pins is the property that removes it:
nothing observable is written on `register`'s own turn). Red-checked — it fails with the deferral
reverted.

**This does NOT close WORKROOM-3A.** It removes 3A's last untested hypothesis, but nothing links the
hang to these faults; 3A stays open and dormant pending a second occurrence.

**2026-09-03 — OSC 52 / paste confirmation shipped, and the TODO entry's premise was wrong.**
The old entry ("writes are gated to `text/*` mime and reads use Ghostty's permissive default
(auto-allow); `confirmReadClipboard` is a stub") described a permissive pass-through. It wasn't one.
Read at the pinned ghostty ref (`35e1a016` — see `project.yml` for the pin): `apprt/embedded.zig`'s
`completeClipboardRequest` catches `error.UnsafePaste` / `error.UnauthorizedPaste` from
`Surface.completeClipboardRequest` and calls `confirm_read_clipboard` — so the empty stub meant BOTH
of these were **silently dropped**, not auto-allowed:

- **an unsafe paste never landed.** `clipboard-paste-protection` defaults on. In practice this bites
  a multi-line paste into a program with no bracketed-paste mode (`cat`, a raw `ssh` prompt), or any
  paste containing a bracketed-paste terminator — with bracketed paste on,
  `clipboard-paste-bracketed-safe` makes it safe, which is why it never showed up in normal use.
- **an OSC 52 read never got a reply.** `clipboard-read` defaults to `ask`, not `allow` — the entry
  had this backwards.

Each dropped request also leaked the engine's `ClipboardRequest` allocation, which
`completeClipboardRequest` deliberately does not free on the confirmation route precisely because
the apprt is supposed to answer it.

**Shipped:** `confirmReadClipboard` now presents an `NSAlert`, sheeted over the asking surface's own
window (so it's obvious WHICH terminal asked), with per-request wording — paste vs. "read your
clipboard" vs. "change your clipboard" are three different asks and must not be interchangeable.
`writeClipboard` honours the engine's `confirm` flag through the same prompt. The alert is always
presented via `DispatchQueue.main.async`: the clipboard callbacks can fire inside one of our own
`ghostty_surface_*` calls with the renderer mutex held (the `GHOSTTY_ACTION_SELECTION_CHANGED`
hazard), so running a modal — and completing the request from it — on that stack risks deadlocking
the main thread.

**Traps found doing it:**

- **The `content` pointer is our own `withCString` stack buffer.** It comes back out of
  `ghostty_surface_complete_clipboard_request`, so it's valid only for the duration of the callback
  and must be copied to a Swift `String` before anything defers.
- **So is `userdata`.** It only names a live `GhosttySurfaceView` during the call; resolving it
  after the async hop would be a `takeUnretainedValue()` on a possibly-freed pointer (close the tab
  while the prompt is up). The view is resolved synchronously and captured weakly.
- **Denying leaks, and there's no way around it at this pin.** The pinned engine has no
  `ghostty_surface_deny_clipboard_request` (it exists on `main`), and "completing" with
  `confirmed: false` re-enters the same error path and re-prompts forever. Upstream's own macOS app
  at this ref leaks it identically. Revisit when the pin bumps.
- **`WorkroomAppTests` doesn't link the GhosttyKit C module**, so a pure mapper taking
  `ghostty_clipboard_request_e` compiles in the app and not in the tests. The copy mapper takes an
  app-owned `ClipboardConfirmationKind` instead, mapped from the C enum at the callback boundary —
  where the `default: return nil` arm makes an unrecognised future request kind deny rather than
  auto-allow.

**Return does not approve.** The first `NSAlert` button is the default action, and this sheet lands
in front of someone who is TYPING — their next Return would authorize the access they were meant to
judge. `keyEquivalent` is cleared on allow and Escape is wired to deny (AppKit only binds Escape
automatically for a button titled "Cancel").

**Deliberately skipped:** no `Defaults` policy key (allow/ask/deny). The TODO proposed one for "a
security-minded user should be able to require confirmation" — but ghostty's `clipboard-read` default
IS `ask`, so implementing the prompt satisfies that with zero configuration. `clipboard-write` keeps
ghostty's `allow` default (matching upstream rather than inventing a stricter posture), which makes
`writeClipboard`'s confirm branch dead today; it's kept because it's the engine's security signal and
costs three lines. One prompt at a time is enforced, so an OSC 52 flood can't stack alerts.
**Red/green-verified against a real PTY.** `ClipboardConfirmationUITests` drives the two repros:
`printf '\033]52;c;?\007'` (OSC 52 read) and a multi-line ⌘V into `cat` (paste protection, which
needs `cat` rather than the shell prompt — zsh's line editor turns bracketed paste on, and
`clipboard-paste-bracketed-safe` then makes the paste safe). With the stub restored BOTH fail
exactly as the bug described — "produced no confirmation" — and with the fix both pass, the allowed
paste actually reaching the screen. The Return guard was red-checked separately: with the
`keyEquivalent` lines removed, the test's synthetic Return dismisses the sheet, i.e. approves the
clipboard read. Also unit-tested: `ClipboardConfirmationCopyTests` (per-kind copy, preview
truncation at 200 grapheme clusters).

A `screencapture` of the live alert wasn't possible (the shell has no Screen Recording permission),
so the two properties a screenshot would have judged are asserted in the UI test instead: Escape
dismisses, and Return does not.

**2026-08-16 — `make app-test` was silently reading and acting on the developer's real config.**
`WorkroomApp`'s top-level `WindowGroup` scene has no test-mode branch of its own — `WorkroomAppTests`
hosts the real app to get `@testable import Workroom`, so this real window rendered and its
`.task { await store.bootstrap(...) }` ran on every `make app-test`, against the SHARED `AppStore`
(production default `cli: WorkroomCLI.shared`, never a fake). Confirmed via the test log: an
`io_exec: started subcommand path=/usr/bin/login` line — a real terminal opened in a real project
directory — appeared on every run. Fixed with the same `XCTestConfigurationFilePath == nil` guard
`WorkroomApp.init` already uses for `ShellEnvironment.refresh()`; verified the fix by rerunning the
suite and confirming zero `io_exec`/`login` spawns. No unit test reads `ProjectStore.shared`
directly (grepped first), so nothing depended on this window having bootstrapped. Manual
`make app-run`/⌘R are unaffected by construction — `XCTestConfigurationFilePath` is set only by
`xcodebuild test`, never a normal launch — so no new flag is needed to keep testing against real
config by hand.

**2026-08-10 — the last two `## P1` entries shipped, so that section is now empty.** Both were filed
before GA and are fully landed; retired out of the priority sections per this file's own rule (open
work only lives there) rather than left to read as still-outstanding.

- **Terminal *content* accessibility (CMT-3).** `isAccessibilityElement()`/`accessibilityValue()` are
  real now (no longer gated behind the UI-test fixture); a new `accessibilitySelectedText()` reads
  the existing `readSelectionText()`; a 400ms `Timer` poll posts coalesced
  `.valueChanged`/`.selectedTextChanged` only when the read content actually changed, checking
  `NSWorkspace.shared.isVoiceOverEnabled` FIRST on every tick so the real cost (materializing the
  viewport into a `String`) is paid only while VoiceOver is actually listening. The no-password-leak
  safety property was verified empirically, not by reasoning about terminal semantics:
  `TerminalAccessibilityUITests.testPasswordPromptWithEchoDisabledRendersNoTypedCharacters` drives a
  real `stty -echo` + `read` prompt in a real pane and asserts the typed secret never appears in the
  read viewport.
- **Every shipped beta had an arm64-only CLI inside a universal app.** `ARCHS` is a space-separated
  list (`"arm64 x86_64"`), and `build-helper.sh` matched it as a single token, falling through to a
  `warn:`-and-default-to-arm64 branch — buried in xcodebuild output, and codesign/notarization/
  Gatekeeper are all happy with a thin nested binary. Present since `8bae1b2a` (beta.1 through
  beta.23); the standalone CLI's own `darwin_amd64` tarball was always fine, only the embedded copy
  was thin. Fixed in `build-helper.sh` (per-arch build + `lipo`), asserted at release time by
  `release.sh check_universal()`, and regression-tested by `build-helper_test.sh` (proven to fail
  against the old logic). Confirmed released: `ff7bbb7f` is an ancestor of the `v2.0.0-beta.24` tag.

**2026-08-05 — four caches and surfaces that asserted stale or wrong things.** The three user-noticed
findings from the VCS-toolbar review ((5), (6), (7) — see that entry) plus `DiffDescriptor.change` going
stale on an open tab. What each turned on:

- **A "freshest first" cache needs a way to be retracted.** `resolvedBranchNames` led `branchName(for:)`
  because the toolbar read is normally freshest, but only the FOCUSED target is ever written and only
  while the inspector shows Changes — so nothing could ever say "not any more", and `git switch` in a
  terminal left every surface on the old name indefinitely. Fix is one line at the sweep
  (`pruneResolvedBranchNameIfDrifted`): a lower source that disagrees retracts the higher one. An
  empty/absent swept branch is NOT a disagreement — a detached HEAD and an unbookmarked jj `@` both
  legitimately report none.
- **An identity guard that's right for rendering is wrong for reporting.** `finish` guards its published
  state on target identity because the toolbar renders whatever is selected NOW — correct — but the
  failure DIALOG was behind the same guard, so a push that failed after a workroom switch was reported
  nowhere at all. Raised ahead of the guard now, with the workroom named
  (`VCSFailureReport.workroom`) when it isn't the current selection.
- **A failure described into a `String` is a dead end.** `state.failed(String)` carried the read's
  failure but nothing rendered `state` and nothing could classify a description, so a read blocked by
  `packed-refs.lock` reached the bar as a nil snapshot and rendered "No repository" — a wrong diagnosis
  of a healthy repo. Publishing it typed (`readFailure`) is what let the presenter add tier [13b].
- **Refreshing content must not look like navigating to it.** `TerminalSessions.setContent` fires
  `onTabContentChange`, which RECORDS a back/forward entry — so refreshing an open diff tab's change kind
  through it would have logged a history step every time a file changed under the user. The refresher
  mutates in place, fires nothing, and returns `false` for an unchanged kind so a 15s sweep publishes
  nothing (WORKROOM-2B). Also: `DiffDescriptor.change` was KEPT, not removed as filed — `.commit` diffs
  need a kind that live status can't supply.

**2026-08-05 — the ⌥Tab / ⌃Tab quick switcher (#132), and the contrast metric it exposed.** ⌥Tab steps
open workrooms across every window by most-recent use, ⌃Tab steps the current workroom's panes; a tap
flips, a 250ms hold reveals a screen-centred rail of cards, release commits. `Core/SwitcherRecency.swift`
(pure `RecencyList` + `WindowToken`), `QuickSwitcher{,Reducer,Controller}.swift`, `SwitcherPanel.swift`,
`SwitcherRailLayout.swift`, `SwitcherMark.swift`, `Views/SwitcherRailView.swift`, plus Go-menu items and
two Keyboard Shortcuts rows. Deferrals are filed above ("Quick-switcher deferrals"). The traps:

- **`ThemeTokens.luminance` was never WCAG.** It weighted *gamma-encoded* sRGB instead of linearizing,
  so `contrastRatio` under-reported every dark colour (`#2E3440` read 0.20 against a true 0.033). Across
  the 56 bundled themes the rail's name text scored under 4.5:1 for **43** of them by that formula and
  **4** by real WCAG, and the "this theme is unreadable, drop the material" fallback was firing for 38
  legible themes. Fixed app-wide: `luminance` linearizes, the old formula survives as
  `perceivedBrightness` for light/dark classification only (WCAG luminance is not perceptual), and
  `contrastingForeground` picks ink by **measuring both candidates** instead of a luminance-0.6 switch —
  that threshold is what left a monogram at 1.77:1 where black gave 11.8:1.
- **Contrast tests must pin their theme, and then sweep the real ones.** Three "failures on untouched
  code" were tests reading the ambient theme via `ThemeTokens(preview: nil)`, which follows the machine's
  appearance. Pinning them to fixtures exposed two real bugs; sweeping all 56 bundled themes
  (`SwitcherThemeSweepTests`) exposed the metric. Two hand-made fixtures prove nothing about the
  fiftieth theme.
- **A borderless non-opaque `NSPanel` casts no shadow at all** (measured: zero darkening at 6/14/26/44pt
  out with `hasShadow = true` + `invalidateShadow()`). The rail draws its own — which needs the window
  padded by a halo (a drawn shadow clips at the window edge), the shadow in a *second* `.background`
  after `.clipShape` (a clip applies to a view's background), and the caster's own footprint punched out
  with `destinationOut`, because an opaque layer anywhere beneath a glass view annihilates the material
  (interior variation and backdrop correlation both fall to exactly 0).
- **Compacting a live item list silently retargets the commit.** `filter`ing dead items shifted every
  later index down one while the reducer only *clamped* the cursor, so losing an item before the cursor
  committed the highlighted card's neighbour — and the rail was never re-pushed, so a click indexed a
  stale array. `.itemsChanged` now carries a cursor remapped by item **identity**.
- **A commit must re-check `hasModalPresentation`.** It was enforced at open and in the liveness check,
  which only runs on a window *close* — a sheet going up posts no notification the session watches, so
  releasing over a window that had since become modal performed exactly the write the gate exists to
  prevent.
- **Raising a window fires the recency hook for the selection it's leaving**, so MRU[1] became somewhere
  the user had never been and the ⌥Tab⌥Tab ping-pong broke. `SwitcherRecency.suppressingRecord` wraps the
  raise.
- **There is no VoiceOver-status notification in AppKit.** `isVoiceOverEnabled` is KVO-only
  (`NSAccessibility.h`), which is how a live session now ends when VoiceOver arrives mid-gesture.
- **`UserDefaults` is not isolated by a throwaway `$HOME`** — cfprefsd resolves the login session's home,
  so QA can isolate `~/.config/workroom` but never `Defaults`-backed state (theme, inspector, channel).
  Use a `UITestFixture` flag instead.
- **Window captures were built (T12) and removed.** At card size an aspect-fit terminal thumbnail is a
  grey smudge that changes every time and looks like every other terminal — it carried the least
  information while being the loudest element. Replaced by a learnable per-workroom mark (hue + monogram,
  hues rotated so no two visible cards collide) and a per-pane type miniature. `Core/Snapshots/` is gone;
  own-process ScreenCaptureKit needing no TCC was proven on the way and is in git history if it's ever
  wanted again.

**2026-07-26 — the shared inspector prefs are out of the test suite, and the fix went one class further
than filed.** The entry this retires was about three classes writing `Defaults[.showInspector]` /
`inspector.activeSection` into a domain all the parallel workers share.

- **The two History classes now pin both halves of the gate per store** —
  `AppStore.inspectorVisibleOverrideForTesting` (routing the two `Defaults[.showInspector]` reads in
  `handleRootBranchChange` / `refreshHistoryIfActive` through `inspectorIsVisible`) and
  `isolatesInspectorSectionForTesting` (which suppresses the `activeInspectorSection` didSet's persist).
  `EmptiedWorkroomSelectionTests` was a fourth writer the entry hadn't spotted, and takes the same flag.
  Both hidden `Defaults` sides keep a test, for the reason `resolveConfirmOnClose` has one.
- **`HistoryLiveRefreshTests`' save/restore couldn't have worked anyway:** it restored
  `"activeInspectorSection"`, and the key is `"inspector.activeSection"`. A save/restore pair is only as
  good as its key string, and nothing type-checks that string.
- **The entry's carve-out was wrong.** It said the fixture class "should keep writing the real keys",
  which is fine in isolation but not while `ActivitySectionTests` also wrote
  `inspector.activeSection`: **two** legitimate writers race each other just as badly. That reproduced —
  a `.files` write landing between the fixture seam's write and its read failed
  `testUnknownSectionArgumentFallsBackToChanges` about once in five 8-iteration parallel batches. So the
  real invariant is *one* writer per key, and XCTest parallelises per **class**, which makes it
  structural rather than documentary: all of it now lives in `SharedPrefDefaultsTests` (the old
  `UITestFixtureDefaultsTests`, absorbing the visibility + persistence guards), and
  `ActivitySectionTests` asserts the raw-string round-trip and the unknown-value fallback against a
  private probe key — those are properties of the *type*, so a key nobody reads proves them identically.
- **The verification that matters** (the shape the diff-mode fix used): pin the Dev domain to the values
  the tests used to overwrite — `showNotificationsInspector=0`, `inspector.activeSection=files` — and run
  the affected classes 8× parallel. Green, and the two keys still read `0`/`files` afterwards, so the
  tests are hermetic *and* no longer leak. Full unit suite **1292 passed / 0 failed / 1 skipped**.

**2026-07-26 — the red tests were both a shared-state bug, not the bug they looked like.** Two entries
retired from *P3 — Tests and tooling*; the diagnosis in each was wrong, which is the part worth keeping.

- **Five diff UI tests were red because they read the developer's preferences.** The filed suspicion was
  an accessibility regression — `diff.line` leaves swallowed by a parent container. It wasn't: dumping
  `XCUIApplication.debugDescription` for an open diff showed a fully populated tree of
  `diff.side.left`/`diff.side.right` cells and `tab.toolbar.diffSideBySide` marked `Selected`. The app was
  simply **in side-by-side**, and `diff.line` is emitted only by the *unified* renderer. Cause:
  `Defaults[.diffViewMode]` is a Settings picker persisted in the app's real (Dev) UserDefaults domain,
  this machine's held `sideBySide`, and the tests asserted on "the global default" without pinning it.
  Fixed at the source — `UITestFixture.applyInspectorDefaults` (which already existed to stop exactly this
  leak for the inspector) is now `applyFixtureDefaults` and pins the diff layout too, defaulting to
  unified with a `-WorkroomUITestDiffViewMode` opt-out; `DiffViewerUITests` passes the layout on **every**
  launch, and `DiffHighlightUITests` pins unified. All 7 + 2 tests in the two classes pass.
  Verification that matters: set the Dev domain **back** to `sideBySide` and re-run — still green, so the
  tests are hermetic rather than merely agreeing with the machine. Trap: three of those tests were filed
  as red and the other two were never noticed, because the UI suite needs a GUI login session and is
  excluded from the `make app-test` gate — the exact way tests rot unseen. Cost of pinning: a fixture
  launch overwrites these keys in the **Dev** domain (the release app's are untouched), so a UI-test run
  resets the Dev app's inspector + diff-mode choices. Deliberate trade, documented on the seam.
- **The `confirmOnCloseTerminal` race is closed** by `AppStore.confirmOnCloseOverrideForTesting` — a
  per-store override the close-behaviour tests set instead of writing the shared key. `AppStoreCloseTabsTests`,
  `EmptiedWorkroomSelectionTests` and `RunCommandTests` no longer touch `Defaults` for it at all (both
  classes' save/restore `setUp`/`tearDown` pairs are gone; the value now lives in each `makeStore`), leaving
  `ConfirmOnCloseTerminalTests` — which legitimately asserts the shipped default — as the only writer. The
  four-class × 20-iteration `-run-tests-until-failure` repro that used to fail on a *different* test almost
  every run is now clean, and the mechanism is gone, not just quiet. The residual same-shape hazard on
  `showInspector` was filed as P3 and is now closed too — see the 2026-07-26 entry above it.

Full unit suite after both: **1279 passed / 0 failed / 1 skipped** (+3 tests — `UITestFixtureInspectorTests`
became `UITestFixtureDefaultsTests`, since renamed again to `SharedPrefDefaultsTests`, and covers the
diff-mode half of the seam, including the assertion that would have caught this: a persisted `sideBySide`
must not survive a fixture launch).

**2026-07-25 — two timing flakes killed (a unit one and a UI one).** Both were the same mistake in two
dialects: a *fixed* wait standing in for an event that has no fixed arrival time.

- **`RunCommandTests`' graceful-teardown tests** asserted "the tab closed" / "the completion ran" after a
  flat `settle(0.2)`, but `AppStore.pollUntilExited` only notices an exit on a 0.1s main-queue timer, and
  under the parallel suite that timer can slip past the sleep. A new `waitUntil` helper pumps the runloop
  until the outcome holds (5s ceiling), and all four positive assertions in the section now use it; the
  one *negative* assertion keeps its dwell, because showing nothing happened needs one. Also raised that
  test's `gracefullyStopAllRunCommands(timeout:)` from 2s to an unreachable 300s: the test is about the
  wait ending because the processes exited, so a slow machine hitting the fallback was a second way to
  fail (and, on the last assertion, a way to pass for the wrong reason). The timeout path has its own test.
- **`TabActionsUITests.openDiffPreview`** clicked the Changes row as soon as it *existed*, which isn't the
  same as being hit-testable — an early click is swallowed silently. It now waits for hittability
  (advisory), retries the click once if no diff tab appears, and allows the tab the same 10s as every
  other wait in the helper (6s was the tightest budget in the sequence and the first to give under load).

Traps worth keeping: **CPU starvation does not reproduce this class of flake** — 12 hogs × 25 iterations
left the *old* code green, because timer slippage here comes from main-queue coalescing in a
non-foreground test host, not from CPU pressure. What does verify the fix is a probe of the property
itself: schedule a flag 1.2s out, confirm `settle(0.2)` can't see it and `waitUntil` can. And once fixed,
the UI test held up in the exact three-class batch that had flaked it.

**2026-07-25 — git commit diffs detect renames.** `Core/GitCommitDiff.swift` builds a commit's diff on
raw libgit2 (`git_diff_tree_to_tree` + `git_diff_find_similar`, renames only, matching git's
`diff.renames=true` default) and `GitProvider.changeset`/`.fileDiff` both read through it, so History's
file list and its patch text can't disagree. The stated blocker in the old entry was stale — the
`libgit2` product was already linked directly for `GitGraph`; what's real is that a SwiftGitX `Diff`
can't be post-processed (deltas materialized in an `internal` init, the `git_diff` freed in a `defer`,
repo pointer `internal`). `Core/LibGit2.swift` now owns the single `git_libgit2_init` for both raw
readers. Two things fell out of replacing that call: a rename's `+N −M` shrinks to git's numbers, and
**root commits list their files at all** — SwiftGitX diffs a first commit against itself, so History had
been showing none. The cross-backend divergence test is now
`testColocatedCommitRenameMatchesAcrossBackends` (parity, both directions, patch text included).

**2026-07-25 — git working ± line counts moved off SwiftGitX.**
- The badge counts read `git_diff_get_stats` through raw libgit2 (`Core/GitDiffStats.swift`) instead of
  summing a SwiftGitX `Diff`. The cost wasn't the diff — that's irreducible, it's what
  `git diff --shortstat` costs too — it was that **SwiftGitX's `Diff.init` is eager**: it builds a
  `Patch` per delta and materializes every hunk line into a Swift `String` before the caller sees the
  value. So two integers cost one `String` + a `Line` struct per changed line of the whole worktree, on
  every status refresh (sweep/focus/appear). libgit2 counts in C and allocates nothing Swift-side.
  **Measured, don't estimate: 1.7× (115ms → 68ms)** on 300 files × 200 lines with every line changed
  (60k insertions / 60k deletions), both engines returning identical counts. Modest on purpose — the
  diff dominates and can't be removed; what's gone is the Swift materialization on top of it. On a
  small dirty tree the saving is proportionally small, which is why the entry was scoped to large ones.
- **It was also wrong, and that's the part worth remembering.** The hand-rolled sum counted SwiftGitX's
  `.additionEOF`/`.deletionEOF` — the `\ No newline at end of file` markers — as real lines. They're
  always paired with a genuine addition/deletion, so a file whose trailing newline changed reported
  **2 deletions where git reports 1**. libgit2's `git_patch_line_stats` skips them and says why in its
  own source comment; `git diff --numstat` agrees. This landed alongside the rename work above, which had
  already moved the `changeset` counts onto the same C call, so `diffLineStats` — the hand-rolled sum, and
  the last EOFNL over-counter — lost its final caller and is **deleted**: no `+N −M` in the app is summed
  off SwiftGitX hunk lines any more. Pinned by two tests that assert against real `git --numstat` output
  rather than against arithmetic in the test.
- `GitDiffStats` opens its handle through `Core/LibGit2.swift` (the rename work's shared owner of
  `git_libgit2_init`), now serving three raw readers. **Residual, deliberately not chased:**
  `workingStatus` opens two repo handles per refresh (SwiftGitX's for the file list, ours for the counts).
  Cheap next to the diff, and it collapses on its own if that read ever goes raw-libgit2 — SwiftGitX keeps
  its `git_repository` pointer `internal`, so there's no way to borrow one today.
- Trap: an unborn HEAD has no tree to diff, and libgit2 spells "empty tree" as a NULL `git_tree *` —
  the same choice SwiftGitX made, kept so a just-initialized project's badge doesn't go blank. There's
  no git answer to check it against (`git diff HEAD` is fatal without a HEAD), which is exactly why it
  needs its own test.

**2026-07-25 — tab strips (#129 follow-ups) and the pane floor.**
- **`WorkroomTabChip`'s title is capped** at 180pt like the terminal chip, with the full title in the
  tooltip. Trap: the workroom title is two `Text`s plus a separator, so the cap goes on the wrapping
  `HStack` — per-`Text` caps truncate the halves independently and eat the workroom name first. A cap test
  needs a *lower* bound too, or it passes vacuously whenever the long-name fixture fails to apply.
- **The overflow scaffolding is one container** (`Views/OverflowingTabScroller.swift`): both strips'
  width measurements, the predicate, the fade and the load-bearing modifier order now live in one file.
  The content closure still receives `overflowing` because both strips gate a hairline on it.
  `WindowMovableController` stays in `WorkroomTabBar`, outermost. The one real change was unifying on
  `.frame(maxWidth: .infinity)` for the terminal strip, which its two geometry tests confirm is inert.
- **Panes have a per-axis floor:** `minPaneWidth` 300, `minPaneHeight` 120, threaded through
  `PaneTreeLayout.minPane(along:)`. One 120pt constant had been serving both axes, which put the width
  floor below the width the strip needs for its own chrome — measured, a diff tab's toolbar alone is
  ~145pt and the whole strip needs ~293pt. Trap: measure this furniture, don't estimate it; the AX frames
  report the *glyph*, so each toolbar button is glyph + 8pt of padding. Side-by-side splits now need
  604pt of pane, which is the honest number.
- **A selected chip is scrolled into view** in both strips, on selection change *and* on mount (a strip
  that appears with a selection already set would otherwise render at the start of its run). No
  per-shortcut plumbing was needed: every path funnels through `TerminalSessions.setFocused` /
  `AppStore.selectedTargetID`, so one `.onChange` sees them all. The mount reveal hangs off the width
  measurements, not `onAppear` — before layout, `scrollTo` is a silent no-op. Traps, both found by
  running rather than reasoning: `window.contains(chip.frame)` is the WRONG visibility test for the
  terminal strip (its visible trailing edge is far inside the window, so the assertion passes on a chip
  that is scrolled away — anchor to the pinned "+" instead), and the chips' `.isSelected` trait is not
  queryable as an AX attribute on macOS, so a test can't ask which chip is selected.

**Dropped, so they don't get re-proposed (2026-07-25):**
- **Collapsing the terminal tab toolbar into a `⋯` menu at narrow widths.** Its whole premise was the
  120pt pane; with the 300pt floor there are no degenerate panes, so it only bought chip room on a
  diff/markdown tab in a narrow split. Not worth the native-menu semantics and the ten UI tests that
  query the toolbar as real buttons. If the diff toolbar grows, the cheap slice is dropping `closeAll`
  from it — that action already exists in File ▸ Close All Tabs and the chip context menu.
- **Drag-edge auto-scrolling** the tab run. The scroll-on-select half shipped and covers the actual
  complaint ("the shortcut did nothing"); auto-scroll would perturb `TabReorder`'s translation math and
  `clampReorder`, which has no unit tests.
- **Signalling the refused `⌘D` split.** The refusal is silent and now fires more often (604pt, up from
  244pt), but it tested fine by hand. Revisit only if "⌘D did nothing" is actually reported.

**2026-07-25 — jj native reads (all five in `vcs/crates/wr-vcs-core/src/jj_backend.rs`).**
- **± line counts** now come from ONE `materialized_diff_stream` per read, so the change kind and the
  counts are the same entry, first-parent-anchored by construction. Deliberately **no** aggregate field
  on `WorkingStatus`/`CommitChanges` — a stored total beside the rows is the second representation that
  caused the bug. `None` counts mean *not counted, never zero* (binary, >4 MiB, non-file). Conflicts
  **do** count their markers, matching `jj diff --stat`, a git worktree diff, and our own commit header;
  `VCSStatusPresentation.lineCountsHelp` says so in both the tooltip and the VoiceOver label. Deleted
  `parseDiffStat`, `commitStatArgs`, and `changeset`'s `--stat` pair: **3 fewer `jj` processes**.
- **Log + branch-label order** go through one `ancestors_revset` helper (jj-lib's `::@`, descending
  commit position = topological). Timestamps were never a graph order; the old max-heap could surface a
  commit above its own descendants. `first_bookmark_in_log_order` shares that walk, so the sidebar can't name a
  bookmark History doesn't show — and it now stops at the first bookmark instead of deserializing every
  ancestor. git's side keeps libgit2 `GIT_SORT_NONE` (= `git log`'s own default), so each backend
  matches its own CLI; do not "unify" them.
- **Error taxonomy** is classified at the source instead of one `fn io()`. Two were latent bugs, not
  labels: `FileLock::lock` blocks on `flock` forever (a `jj` command in a terminal used to stall the
  status sweep and hold a `JJSnapshotGate` slot) — now a non-blocking `try_lock` probe; and
  `WorkingCopyFreshness::check_stale` now runs, so a working copy another workspace rewrote reports
  `StaleSnapshot` instead of being snapshotted from a stale base. App side: `VCSStatusFailure.busy` /
  `.staleWorkingCopy` replace "not a repository" for both.
- **Rename detection** via `diff_stream_with_copies` + the backend's copy records: one `Renamed` row
  with `old_path`, in the Changes panel and History. Backend-dependent by design (jj's `simple_backend`
  returns no records). `Conflicted` beats rename, but defensively only — a conflicted path can't carry a
  copy record, so a conflicted rename decomposes into `Added` + `Conflicted`.
- **Per-file conflict status** classifies an unresolved `after` value as `Conflicted` *before* the
  presence tests (an unresolved merge never satisfies `is_absent()`, which is a *resolved* `Some(None)`
  — why conflicts read as `Modified`). UI: `"!"` in `tokens.conflict`, mapped in `Core/ChangeBadge.swift`.
  CI now runs `cargo test` at all.
- **Merge working-copy diffs**: `jj diff -r @` diffs a merge against its *auto-merged* parents while the
  file list is a tree diff against the FIRST parent, so any file differing only from the first parent
  listed but showed "No changes". `workingFileDiff` resolves `@`'s first parent and diffs `--from <id>
  --to @` (`--from @-` can't express it — `@-` on a merge is several revisions).
- **Chrome glyph buttons' `isHittable == false`** — closed as an environmental XCUITest artefact, not an
  a11y defect; nothing in the app was wrong. Two misleading comments removed, replaced by real guards
  (`testChromeGlyphButtonsAreHittableWhenInline` / `…WhenPinned`).

**Traps worth knowing before touching the same code:**
- A **single-parent or linear fixture cannot expose** the merge/ordering bugs at all — the two bases
  coincide, the heap frontier is size one. Ordering tests need a merge AND skewed timestamps
  (`JJ_TIMESTAMP`); merge tests should assert `parents.len() == 2`.
- `jj diff --stat` prints its summary line even when nothing changed, so a test asserting the *absence*
  of "insertions" passes for the wrong reason — assert the file count.
- No jj fixture may address commits **by bookmark**: with `experimental-advance-branches` (as in the
  author's config) `jj commit` advances the bookmark onto the new commit, collapsing the two merge sides
  and silently producing no conflict. Also: don't `unsafe set_var("JJ_CONFIG")` from parallel `#[test]`s.
- XCUITest's `isHittable` uses **accessibility** hit-testing: neither a covering non-AX overlay nor a
  `0×0` frame turns it false — only a real AX element or another window over the point. A window that
  wasn't frontmost explains the original sighting.
- Conflict-marker counting depends on marker **style**, so "The jj snapshot ignores the user's real
  jj/git config" must fix `materialize_options()` too, not just `snapshot_working_copy`.

**2026-07-24.** `JJSnapshotGate` (per-project-root chain-of-tails actor) serializes every jj-mutating
snapshot across the status fan-out — status sweep, selection refresh, file-watch, `.jjWorkingCopy`
diffs, and `FileTreeModel.list`'s ungated `jj file list`; `maxChainWait` (30s) stops one hung native
call wedging a project's whole queue. `add-project --pretend` is a real dry-run on the non-create path.
Pending sheets clear in `removeProjectLocally()` when they target the deleted project.

**2026-06-24 audit.** Shipped: workroom tab-chip management actions (#23), hardened `gh` auth (#86),
live branch-label refresh (per-project FSEvents on each root's `.git`/`.jj`). Narrowed: at-a-glance
review status (label + PR badge shipped; glyph + sweep stage remain), per-pane activity flash.
**Dropped (won't do):** per-file diff view-mode persistence — the in-memory per-tab toggle is enough.

**2026-06-09.** Splits (A5), the UI-test fixture seam, and terminal notifications (#10) landed.
