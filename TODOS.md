# TODOs

> Grouped by priority, then by area. Within a group, cheaper/higher-leverage first. Each entry states
> what it is, why, how to start, what it depends on, and its priority. Completed work is summarised in
> **Recently done** at the bottom — including the traps found while doing it, which are the parts worth
> reading before touching the same code. Full write-ups for finished items live in git history.

## P1 — before GA

### Terminal *content* accessibility (macapp) — CMT-3

**What:** VoiceOver support for the terminal's *rendered text* on `GhosttySurfaceView` — accessible
value (screen text), selected text, and change notifications — so the terminal content is navigable
with assistive tech.

**Done so far:** the **UI-tree** a11y has landed (commit `f3859f9`) — `PaneTreeView` exposes each
leaf as `terminal.pane` with a label ("Terminal <title>, pane N of M"), a focused/selected trait, and
an adjustable split divider (`pane.grip`). That claim is unqualified: the one caveat raised against it
(the tab strips' glyph buttons reporting `isHittable == false`) was investigated and closed as an
XCUITest artefact — see **Recently done**. What's still missing is the *content* layer: the
libghostty surface is Metal-rendered, so its text is pixels — invisible to the accessibility system.
Today the surface view sets `role=.textArea` + a label only; it exposes **no value and no selection**,
so VoiceOver reads nothing inside the terminal. Accepted regression for the beta (CMT-3). This is also
the **enabler for content-level UI tests**: once terminal text is in the a11y tree, XCUITest can
assert on rendered output (backspace deleted, TUI drew, scrollback) on top of the now-landed fixture
seam — see `macapp/QA-libghostty.md` (Bucket 2).

**When:** feasible on the currently pinned engine today (the read APIs exist), but ghostty upstream
has merged a11y plumbing worth riding — **ghostty #12902** ("core: send selection_changed
notification", merged 2026-06-04), which on macOS posts `.ghosttySelectionDidChange` → debounced →
`NSAccessibility.selectedTextChanged`. On the pinned engine we'd have to post that notification
ourselves from our own selection events; after the pin bump it comes from the engine as
`GHOSTTY_ACTION_SELECTION_CHANGED`.

This is unblocked by the **pin bump** (see "Bump the libghostty pin", P2), NOT by owning the
xcframework — an earlier version of this entry sequenced it behind CMT-2, which was wrong. A
before-GA item either way; doing it before the bump costs one self-posted notification.

**How to start (minimal-viable, keep light per D1 — crib Muxy's `accessibilitySelectedText()`):**
- `accessibilityValue()` → visible screen text via `ghostty_surface_read_text(surface, <viewport
  ghostty_selection_s>, …)` (reuse the `extractString(from:)` helper).
- `accessibilitySelectedText()` → `ghostty_surface_read_selection` (the same read that powers
  copy-on-select).
- Post `NSAccessibility.post(element:notification:)` `.selectedTextChanged` on selection change
  (we already detect mouseUp / copy-on-select) and a throttled `.valueChanged` on output so
  VoiceOver follows along; keep the role/label and report focus.
- Skip the full `NSAccessibility` text protocol (line/char-range/bounds geometry) — overkill for a
  terminal, and Muxy keeps it minimal too.

**Caveat:** terminal a11y is inherently partial (dynamic output, scrollback, full-screen TUIs);
target "announce output + selection, navigable text", not a perfect document model.

**Depends on:** the read APIs already present in the pinned engine (`ghostty_surface_read_selection`,
`ghostty_surface_read_text`, `extractString`) in `macapp/WorkroomApp/Core/GhosttySurfaceView.swift`.
Cheaper after the pin bump (engine-sent `selection_changed`), but not blocked by it.

**Priority:** P2 (accessibility regression — address before GA, not blocking the beta).

## P2 — perf, correctness, and the next VCS phase

### Bump the libghostty pin (macapp) — post-GA, first change after the GA tag

**What:** move `macapp/project.yml` from the currently pinned `libghostty-spm` package to **1.3.2**
(ghostty commit `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`). Those two numbers are this task's
TARGET, not a claim about what ships — for what is pinned today, read `project.yml`'s comment, which
is the single source of truth. Re-check the target against the packager's newest release before
starting; it moves.

**Why:** it is the only way to reach `ghostty_surface_foreground_pid` + `ghostty_surface_tty_name`
(the "libghostty exposes no PTY child PID" limitation CMT-1 records at `GhosttySurfaceView.swift:95`)
and `GHOSTTY_ACTION_SELECTION_CHANGED` (CMT-3's a11y hook), plus ~1300 upstream commits. **It ships
no user-visible change by itself** — both wins need separate work to wire — which is exactly why it
waits for GA rather than riding under it.

**The version trap that produced two wrong roadmap entries — read this first.** `libghostty-spm`
versions its **package** independently of ghostty. The release bodies state the ghostty ref
explicitly, and package `1.2.3` is built from ghostty **`v1.3.1`**. Reading a package version as a
ghostty version is what made an earlier CMT-2 claim we trailed ghostty by ~2 versions and file it as
P1. Package `1.3.1` ≠ ghostty `v1.3.1`. Always read `Ghostty.ref` + the release body, never the tag.

**The real risk is the patch swap, not the API.** The packager applies its own patches to ghostty
before building, and `Script/apply-patches.sh` feature-probes the header to choose between them:

```
  grep -q "ghostty_surface_foreground_pid" include/ghostty.h
      │
      ├── absent  (ghostty v1.3.1 — what we ship today)
      │     └── 0002-host-managed-io.patch          (17,588 B)
      │
      └── present (ghostty 35e1a016 — package 1.3.2)
            └── 0002-host-managed-io-modern.patch   (18,447 B)   ← never run here
                                                                    PTY/IO hosting: surface teardown,
                                                                    orphan shells, the EXC_BAD_ACCESS
                                                                    site WorkroomApp.swift:606 documents
```

By contrast the mid-enum `GHOSTTY_ACTION_SELECTION_CHANGED` insert — which renumbers 14 following
tags including `SHOW_CHILD_EXITED` and `COMMAND_FINISHED` — is **not** a risk: header and static
archive ship together, `GhosttyRuntimeAdapter.handleAction` dispatches on symbolic labels, and
nothing persists a raw tag. Don't spend the retest budget there. (Don't write a test asserting a
tag's raw value either — test and app import the same header, so it can never fail.)

**Blocking work, same commit:**
- **Regenerate `macapp/Resources/ghostty/`** from the same ghostty ref — `terminfo/` and
  `shell-integration/` ONLY. See the separate entry below for why `themes/` must not be touched.
- **Resolve `TerminalSearch.navigationPlan`.** It both inverts direction against the engine's
  ordering and synthesizes wrap by emitting `total - 1` steps, keyed to the pinned engine's "stops
  dead at the ends" behaviour. If wrapping or match ordering moved upstream, ⌘G becomes *wrong*, not
  redundant.

**Retest the IO layer, not the enum:** repeated surface create/destroy, split/close churn, workroom
switch/delete, the run-tab supervisor, and the `ps` orphan check. `0010-fix-scroll-remainder-zeroing.patch`
is also new, so include the scrollbar overlay. The XCUITest action-tag baseline (added ahead of this
work, deliberately against the old engine) is the pass/fail gate.

**Also required:**
- **A universal Release build before landing.** CI only ever builds Debug/arm64 and `release.sh`
  takes `ARCHS_STANDARD`, so today the first universal link happens at release time:
  `VCS_APPLE_FLAGS=--universal make app-vcs`, then
  `xcodebuild -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build`.
- **A bake gate.** `nightly.yml` builds daily from master, so this reaches nightly users ~24h after
  landing. Require N clean nightlies before it enters a `pre` tag.
- **A `QA-libghostty.md` §N "engine bump smoke"** (~12 items). Committing to the full 13-section
  manual walk on every bump guarantees it won't happen next time.

**Rollback is not one line:** revert the commit(s), `rm -rf macapp/DerivedData/SourcePackages`,
rebuild. CI's `spm-`/`xcbuild-` caches key on `project.yml` and their `restore-keys` fallback can
restore a mixed state. Do **not** remove any workaround (backspace DEL-as-text, ⌃Tab) until this has
baked — both fail safe, and the backspace test passes either way, so removal needs a raw-PTY probe.

**Depends on:** GA shipping first. `Package.resolved` is now tracked, so the resolved revision is a
reviewable diff.

**Priority:** P2 — real value, no user-visible gain on its own, and it swaps the layer that runs the
user's shell. First change after the GA tag, not before it.

### Own the GhosttyKit xcframework (macapp) — CMT-2, GA-time supply-chain decision

**What:** stop depending on the third-party `libghostty-spm` (Lakr233) package as the source of
truth. Build our own universal `GhosttyKit.xcframework` + version-matched resources from a ghostty
ref *we* pin, and point `project.yml` at it.

**Status: demoted from P1, and re-argued.** Two of the three rationales this entry used to carry were
wrong, and are struck:

- ~~"We trail ghostty by ~2 versions"~~ — a **package-vs-ghostty version confusion**; see the trap
  described in the pin-bump entry above. We have been on ghostty's newest *release* the whole time.
- ~~"Only owning the pin can reach OSC 99"~~ — **a fork cannot deliver OSC 99 either.** See the OSC 99
  entry under Notifications for the upstream state; the short version is that the open parser PR
  routes the command into an "unimplemented → discard" branch, and the pieces that would make it
  reach an embedder do not exist as PRs at all.

**What survives, and it is the whole argument: supply chain.** The shipped binary is **not stock
ghostty**. `Patches/ghostty/` carries 11 patches (~200 KB, including a 113 KB prebuilt-framedata
patch and the ~18 KB host-managed-IO patch that rewrites PTY hosting), applied at build time by a
single maintainer. The artifact is checksummed by SPM but **not signed or notarized** — unlike
ghostty-org, which minisigns its own `ghostty-vt` artifacts. We link that into a notarized app, in
the component that runs the user's shell. Slice composition churns too: arm64e slices shipped
2026-07-21 and were reverted three days later, re-cutting an already-published tag.

**And the lag concern is real — for a mechanism the old entry never identified.** The packager does
**not** track ghostty. `.github/workflows/build.yml` reads its ghostty commit from a hand-maintained
`Ghostty.ref` file (regex-validated as a 40-char sha), and the weekly cron never queries ghostty at
all — it bumps the package's own patch number and bails with `"main matches package tag …, skipping
scheduled release"` when the package repo hasn't moved. Release-tag auto-detection existed up to
package 1.2.9 and was **removed**. Five package releases in 17 days all shipped one engine. So when
ghostty ships 1.4.0, nothing pulls it until one person edits a file.

**How to start (cheaper than a full fork — reuse the packager's tooling):** clone
`ghostty-org/ghostty` at the chosen ref, run the packager's build script against it, and regenerate
`terminfo`/`shell-integration` from that same ref. Decide deliberately which of the 11 patches to
carry — `0002-host-managed-io*` is load-bearing for embedding; the iOS/Catalyst ones are not ours.
Vendor the xcframework + a 2-file C shim, or host it as a release artifact in a separate repo's CI.
Zig is needed only to *build*, not to *consume*. Signing is unchanged (a static archive in the main
executable, no new framework to sign).

**Depends on:** nothing in-app. Best decided once GA has shipped and the pin bump has baked, since
owning the pin means owning the patch decisions above.

**Priority:** P3 — a real supply-chain posture question with no feature blocked behind it. Revisit at
GA, or the first time the hand-maintained `Ghostty.ref` leaves us stranded on an engine we need to
move off.

### Finish the action-dispatch UI coverage (macapp) — search counters

**What:** add the `SEARCH_TOTAL` / `SEARCH_SELECTED` case to
`WorkroomAppUITests/GhosttyActionDispatchUITests.swift`. The other two visible tags (`SET_TITLE`,
`PROGRESS_REPORT`) are covered and green; this one was attempted, hit a wall, and was parked rather
than left as a failing test.

**Why:** the scrollback find bar's "n/N" counter is the only surface for those two actions, so
without it they have no automated detector — the same gap the rest of that file exists to close, and
it matters most when the engine is bumped.

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

### Regenerate the bundled ghostty resources (macapp) — blocking for the pin bump

**What:** regenerate `macapp/Resources/ghostty/terminfo/` and `shell-integration/` from the exact
ghostty ref the pinned package builds from, and record that ref in `SOURCE.md`.

**Why:** `SOURCE.md` records the provenance as "a recent Ghostty build" — no ref, no sha. The
shell-integration scripts and the engine's Zig-side injection are a **coupled contract**
(ZDOTDIR/ENV/XDG_DATA_DIRS, `GHOSTTY_SHELL_FEATURES`, ssh integration). `GhosttyApp.resolveResources`
only checks the directory exists, so if that contract moved, OSC 7 and OSC 133 degrade **silently** —
taking ⌘-click path resolution, tab titles, and the busy indicator with them. There is no error, no
log, and no test: the terminal just quietly stops reporting things.

**Trap:** `themes/` in that directory is **ours**, not upstream's — 56 curated files (`8fd7fa19`,
`602b5aa3`) whose filenames `ThemeService.families` parses. Regenerating it breaks theming. Scope the
regeneration to `terminfo/` and `shell-integration/`.

**Watch first:** `libghostty-spm` PR #43 proposes shipping compiled terminfo + shell-integration from
the package itself, pointing `GHOSTTY_RESOURCES_DIR` at the package bundle. If that merges, this
becomes "delete our copies" instead. Open as of 2026-08-05.

**Depends on:** the pin bump — the resources must match the engine that ships with them.

**Priority:** P2, but only as part of the bump. Regenerating against the *current* engine separately
is also valid and strictly reduces risk, since today's provenance is unknown.

### VCS write actions — Phase 2 (macapp) — roadmap pointer

**What:** The next VCS phase: turn the read-only foundation into a full in-app VCS UI. **Fetch, push
and pull-with-rebase have SHIPPED** (the VCS toolbar), and so have **commit + message-only amend/describe**
(the Changes inspector's commit dialog). What remains: selection-aware amend (needs a temp index),
bookmark (jj) / branch (git) management, and the deep jj ops (undo/op-log, split, absorb, evolog,
interdiff).

**Where the write seam actually is — this changed.** The original plan put write methods on
`VCSProviding` with a `CLIVCSProvider` fallback. That is **not** what shipped, and new work should not
follow it. Writes live behind a **separate** `VCSWriting` protocol (`Core/VCSWriting.swift`) with its
own factory `VCS.writer(for:)`, conformed by `CLIVCSWriter`. Two reasons, both load-bearing:

- `VCSProviding`'s doc calls it "the single seam the app **reads** VCS data through", and four
  resolvers construct providers freely and call them with no gate. A `fetch` on that protocol means
  nothing structurally stops a read path firing a network mutation — the opposite of what
  `JJSnapshotGate` exists to guarantee.
- A CLI-backed method needs an injected `StatusCommandRunning`, and `GitProvider`/`RustJJProvider` are
  stateless value types constructed at four call sites with nowhere to put one. A new conformer has
  somewhere.

So: add commit/amend and the rest as `VCSWriting` members, and they inherit the gate, the network
environment hardening and the failure taxonomy for free.

**Which backend each op uses — decided, don't re-litigate.** `VCSWriting` says *where* writes live,
not *how* they run. The split:

| Ops | Backend | Why |
|---|---|---|
| commit/amend — **CLI, decided against this table's original answer** | **CLI** (`CLIVCSWriter.commit`, shipped) | This row used to say "native", and that was wrong on three counts it never weighed. **libgit2 runs no hooks** ([#964](https://github.com/libgit2/libgit2/issues/964)) — a `pre-commit`/`commit-msg` that the user's terminal honours would be silently skipped, which is worse than not offering commit at all. **libgit2 cannot sign**, so `commit.gpgsign = true` would produce unsigned commits. And native jj commit is blocked on `immutable_heads()` being a jj-*cli* revset alias that jj-lib cannot resolve — so it would happily rewrite commits the user's own `jj` refuses to touch. (The empty-committer and dropped-signature halves of that third blocker are now fixed by `jj_config.rs`; the revset one is not.) |
| branch + bookmark management, jj undo/op-log/split/absorb/evolog | **native** (libgit2/SwiftGitX, jj-lib) — provisional | Local, typed APIs, no output to parse, no tool-version floor, no locale exposure. Still the default answer, but **not "don't re-litigate"**: commit was re-litigated on measurement and moved. Check each op for hooks, signing, and revset aliases before assuming native. |
| fetch, push, pull | **CLI** — permanently, not a stopgap | Three independent blockers, all verified from checked-out sources: SwiftGitX passes NULL options (`git_remote_fetch(remotePointer, nil, nil, nil)`, and `pull` is a `// TODO`), so it has no credential callback at all; **libgit2 implements no `credential.helper` protocol** — nothing in its `src` reads that config key, so native auth means reimplementing helper invocation ourselves; and jj-lib shells to `git` for remote ops anyway (that's where its `MINIMUM_GIT_VERSION` comes from), so a "native jj push" is a git subprocess wearing a Rust coat. |

**Non-goal: Workroom does not store credentials.** No OAuth client, no keychain writes, no auth
prompt, no account concept. The user's own helpers (`osxkeychain`, GCM, `!gh auth git-credential`,
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
per-backend command table and the placement rules (fetch always runs at the project root, for both
backends; jj push too, because bookmarks are repo-global). The read layer blocks nothing. What's left
of the error taxonomy is one-sided (git still flattens to `.io`), and the stale-working-copy **repair**
is itself a write, so it belongs to this phase.

**Depends on:** the VCS read foundation (shipped, Phase 1) and the write seam (shipped with the
toolbar). Spans `Core/VCSWriting.swift`, possibly `vcs/` (Rust) + `WrVcs` UniFFI for native jj ops, and
new write-flow UI.

**Priority:** P2 (the product direction; large — see the plan for the real breakdown).

### `withTimeout` doesn't observe the CALLER's own cancellation (macapp) — VCS-foundation eng-review, /review follow-up

**Status:** the original version of this entry (a `withThrowingTaskGroup` awaiting a detached
operation child past its own deadline) is **fixed** — `Core/Timeout.swift` now races via a single
`withCheckedThrowingContinuation` + a `TimeoutGate`, exactly the fix this entry used to recommend.
Re-audited during the jj-snapshot-serialization `/review` (2026-07-24, cross-model: Codex found it)
and found a **different, still-live** gap in that same seam.

**What:** `withTimeout`'s `withCheckedThrowingContinuation` only resolves on ITS OWN internal race
(the operation finishing vs. its own `seconds` deadline firing) — it never wires up
`withTaskCancellationHandler`, so it does not observe the CALLING task being cancelled from outside.
Concretely: `AppStore+WorkroomStatus.swift`'s `statusSweepTask?.cancel()` (a new sweep replacing an
old one) propagates into `runLocalSweep`'s `withTaskGroup` children structurally, but a cancelled
child's in-flight `withTimeout(seconds:) { … }` call (inside `resolveJJ`/`resolveGit`) keeps running
to completion (or its own `seconds` timeout) regardless — it doesn't stop early just because the
enclosing task gave up.

**Why:** Wastes CPU/time re-running a probe nobody wants anymore, and — post the jj-snapshot-gate
fix — adds unnecessary extra contention pressure on `JJSnapshotGate` (an unwanted, already-abandoned
caller still occupies a project's queue slot for up to its full timeout). This is a
responsiveness/efficiency gap, not a data-integrity one, because the call sites in this seam do
check `Task.isCancelled` before merging a stale result (`runLocalSweep`'s
`if Task.isCancelled { break }`, etc.).

**Corrected 2026-08-05 — do NOT re-read this entry as "the convention protects us".** This used to
say *every* call site already checks, so state stays correct. That was false, and the counterexample
shipped: `refreshGitHubCLI` mutated `githubCLIStatus` **inside** an awaited function, where the
callers' own guards (`AppStore+WorkroomStatus.swift:86`/`:144`) run too late to help. A cancelled
probe's SIGKILLed `gh` still returned through `StatusCommandRunner`'s non-throwing continuation with
the signal number as its exit code, the classifier read that as "not signed in", and publishing it
*stamped the TTL* — so the wrong value suppressed its own repair for a full minute. The cost of a
missed guard is therefore a **wrong published value**, not merely a wasted probe. Two defences
landed with that fix and are what keeps the residual risk low: `CommandResult.signaled` (a killed
child is never mistaken for a CLI that ran and failed) and `GHAuthProbe.keepPrior` (a non-answer
neither writes nor stamps). The `withTimeout` gap below is a genuinely different mechanism and stays
deferred on its own merits.

**How to start:** Wrap `withTimeout`'s continuation in `withTaskCancellationHandler` so cancelling
the calling task settles the `TimeoutGate` early (same shape `JJSnapshotGate.run` already uses to
propagate cancellation into its own chained `Task`). Verify the existing "operation keeps running,
result dropped" contract still holds — this only makes the WAIT responsive to cancellation, not the
underlying synchronous native call (still uncancellable, unchanged).

**Depends on:** —. Touches `Core/Timeout.swift`. Broad blast radius (every `withTimeout` caller:
`WorkroomStatusResolver`, `BranchResolver`, `JJSnapshotGate`'s own internal use) — needs its own
careful review/testing, not a drive-by fix.

**Priority:** P2 (efficiency/responsiveness, not correctness; no user-visible bug today).

### VCS toolbar: the findings the `/review` pass didn't fix (macapp)

**What:** Everything the toolbar review verified but left standing. Each was reproduced or read off the
code; none is speculative. Ordered by what a user hits first.

**Four have since SHIPPED and are struck below**, so the list is what remains:

- **the empty-remote case** (was (1)): `CLIVCSWriter.mergeRemotes` now unions the configured remote list
  (`git remote`, `jj git remote list`) with the ref-derived names for both backends, so publishing to a
  brand-new empty remote works and the counts stay ref-derived.
- **(5), (6) and (7)** — the three a user noticed — see each entry.

2. **jj Pull guesses `trunk()` as the base for an unbookmarked `@`.** Right for a workroom off trunk,
   wrong for one off a feature branch: it reports "N behind" counting trunk's commits and the rebase
   then refuses (`immutableHistory`, now typed and retry-free, so it fails honestly rather than looping).
   The real fix is remembering each workroom's own base rather than deriving it — `::@ &
   remote_bookmarks()` can't, because the base stops being an ancestor the moment it advances.
3. **jj bookmark names that need quoting never match.** jj's template pre-quotes non-identifier names
   (verified: `"main|evil"` comes back WITH the quotes), so `parsed.bookmarks.first { $0.name == name }`
   compares `"main|evil"` against jj-lib's raw `main|evil` and always fails — tracking, counts and Pull
   go silently nil. Parse names unquoted, and build the rebase destination from `(name, remote)` with
   `jjQuote` on each rather than reusing the pre-joined `comparedTo` display string.
4. **jj multi-remote: the wrong remote's tracking row wins.** `trackingByName[name] = …` overwrites by
   name with no `primaryRemote` filter, so with `origin` + `upstream` both tracking `main` the last row
   read decides the counts while every UI string interpolates `primaryRemote`. The git path builds
   `"\(primary)/\(branch)"` explicitly; jj is the asymmetry. Same root cause makes `@..trunk()` capable
   of counting against a different remote than the one it names and fetches.
5. ~~**`resolvedBranchNames` is stale-wins and never pruned.**~~ **SHIPPED.** The cache now yields
   instead of winning: `mergeLocalStatus` drops the entry when the sweep's `branchForCI` disagrees
   (`pruneResolvedBranchNameIfDrifted` — an empty/absent swept branch is not a disagreement, since a
   detached HEAD and an unbookmarked jj `@` legitimately report none), and `removeWorkroomLocally` /
   `removeProjectLocally` prune it on delete beside the label they already dropped. `git switch` in a
   workroom's terminal now follows within one sweep. Note what was NOT changed: the write side is still
   focused-target-only and still gated on the inspector showing Changes — that gate is the reason a read
   costs 2-3 processes rather than a pointer move, and drift-pruning is what makes it safe.
6. ~~**A failure is discarded if the selection moved.**~~ **SHIPPED.** The `lastFailure` write stays
   behind `finish`'s identity guard (correct — the bar renders whatever is selected NOW), but the DIALOG
   is now raised ahead of it, carrying `VCSFailureReport.workroom` so the sheet names where it happened
   when that isn't the current selection. Deliberately NOT a toast: `WorkroomNotification` is OSC-shaped
   (`targetID` + `tabID` + `kind == .osc`), so a VCS failure doesn't fit it without inventing a second
   kind, and the dialog was already the app's answer for "something you asked for failed" — it was just
   being suppressed.
7. ~~**A failed remote READ renders "No repository".**~~ **SHIPPED.** `RemoteStateModel` now publishes
   the read's failure typed (`readFailure`) rather than only as the `String` inside `state.failed`, which
   nothing rendered and nothing could classify. The presenter has a tier for it ([13b], below an action
   failure and an in-flight action, above everything else): it names the cause, carries the lock path,
   and — only when re-reading could plausibly help (`readRetryIsWorthwhile`) — offers "Try Again", which
   re-runs the READ (`retriesRead` — re-reading is not a `VCSRemoteAction`, so it can't route through
   `perform`). A read failure carrying an ACTION recovery (a leftover rebase, a rejection) offers that
   action instead; one that nothing can fix (`toolMissing`, a LOCATED lock, `noRemote`) is a disabled
   message, per `retryAction`'s rule. [13c] renders the re-read in flight ("Trying again…" + spinner).
   `activate` is wired too, as the toolbar's own `.task`.
8. **A workroom deleted mid-action reports "git isn't on Workroom's PATH".** `StatusCommandRunner`
   returns `commandNotFound` for a launch failure ("cwd vanished" per its own comment) and `classify`
   maps that exit code to `.toolMissing`, which offers no recovery — while the version toast
   simultaneously says git is fine. Launch failure needs its own sentinel.
9. **`JJSnapshotGate`'s 30s self-heal is far below the write timeouts it guards.** The gate accepts
   re-admitting the original race past `maxChainWait`, justified as "the rare genuine-wedge case, not
   routine contention" — but fetch is budgeted at 120s and pull at 300s, so exceeding 30s is routine.
   Two windows, each with its own `AppStore` and its own `inFlight`, can queue two writes on one project
   root; the second gives up and runs concurrently with a live `pull --rebase` on the shared `.git`.
10. **Colocated jj root: "Abort rebase" reports success, changes nothing, loops.** `classify` can hand a
    colocated root `.rebaseInProgress` from a `rebase-merge` left by a `git rebase` in its terminal, and
    the jj branch of `abortRebase` returns `.ok(summary: "Nothing to abort")` — so `finish` clears the
    failure, the user pulls, and the identical failure returns.

Plus one doc correction: `gitLastFetch`'s comment claims `FETCH_HEAD`'s mtime covers "one the user ran in
a terminal". It doesn't, for the terminals this app opens — a fetch inside a worktree writes
`worktrees/<n>/FETCH_HEAD` while the common one stays put (measured), so counts update from the shared
`refs/remotes` while the timestamp doesn't. Either read both and take the max, or stop claiming it.

**Why:** These are the residue of a five-pass review (critical + 4 specialists + Claude adversarial +
Codex) whose P0s — argv option injection and jj push publishing the wrong workspace's commit — are
already fixed. What's left is real but none of it is a security hole or silent data loss.

**Priority:** P2. What remains is jj-shaped ((2), (3), (4), (10)) plus two cross-cutting ones ((8), (9));
the four a user actually notices have shipped.

### Gate git VCS *reads*, not just writes (macapp) — VCS-toolbar eng-review follow-up

**What:** Route git status reads through the same per-project `JJSnapshotGate` the writes now use.

**Why:** The toolbar's write path gates git as well as jj, because a project's workrooms are
`git worktree add` worktrees sharing ONE `.git` — a lock lost mid-`pull --rebase` can leave a workroom
wedged in a rebase. But that only half-closes the contention: `WorkroomStatusResolver.resolveGit`
never touches the gate (only `resolveJJ` does), so a fetch writing `packed-refs` while the ungated
status sweep runs `git status` across N sibling worktrees reproduces exactly the
`packed-refs.lock could not be obtained` failure the gate's own doc cites.

**Pros:** removes the last window where `.locked` is an *expected* outcome rather than an anomaly, so
the UI's Retry affordance becomes a genuine edge case.

**Cons:** serialising reads could measurably slow the status sweep, which fans out per workroom by
design. This wants measurement first — it may be that read/write contention is rare enough in practice
that the cost isn't worth it.

**Context / how to start:** `WorkroomStatusResolver.resolveGit` (the ungated read) vs `resolveJJ` (the
gated one); `CLIVCSWriter.gated` for how the writes do it. Note the gate is key-based and
backend-agnostic, so if this lands, renaming `JJSnapshotGate` → `RepoWriteGate` (3 call sites + its
test suite) stops being speculative churn and starts being accurate.

**Depends on:** the VCS toolbar (shipped).

**Priority:** P3 (a real but narrow race; needs measurement before it's worth the sweep's latency).

### jj sibling-workspace staleness after a rebase (macapp) — VCS-toolbar eng-review follow-up

**What:** Detect and surface when a jj operation in one workroom leaves a *sibling* workspace stale.

**Why:** All workrooms of a jj project share one repo and op-store. `jj rebase -b @` — what
pull-with-rebase runs — rewrites commits, and any other workspace whose `@` descends from a rewritten
commit is marked stale and needs `jj workspace update-stale` before its next command. Today that
surfaces as an unexplained error in a **different** workroom from the one the user acted in, which is
the worst attribution problem available: nothing on screen connects cause to effect.

**Pros:** turns a mystery error into an explained one, and the repair is a single command Workroom
could offer as a button.

**Cons:** needs a cheap way to detect staleness across workspaces without reading each one (a per-op
check would multiply the cost of every pull).

**Context / how to start:** `VCSStatusFailure.staleWorkingCopy` already exists in the taxonomy, and
`RustJJProvider.workingStatus` already maps jj's stale-working-copy error onto it — so the detection
half may largely exist; the gap is noticing it for a workroom the user is NOT looking at, and offering
the repair. The repair is itself a write, so it belongs on `VCSWriting`.

**Depends on:** pull-with-rebase (shipped).

**Priority:** P3 (jj projects only; wrong-workroom errors are rare but very confusing).

### jj `push-<id>` bookmarks accumulate on the remote (macapp) — VCS-toolbar eng-review follow-up

**What:** Decide what happens to the `push-<change-id>` bookmarks that pushing an unbookmarked jj `@`
leaves on the remote.

**Why:** A jj workroom is `jj workspace add`, whose `@` carries no bookmark, so the toolbar's Push runs
`jj git push --change @`. jj creates a bookmark named by `templates.git_push_bookmark` (default
`"push-" ++ change_id.short()`), and **nothing ever removes it**. Verified on jj 0.43 against a bare
origin — two pushes of two different changes left two bookmarks behind permanently:

```
push-rrxukuporqwy
push-slxllnxlmxwz
```

On a shared remote that accrues indefinitely, one entry per change anyone ever pushed from a workroom.

**Not a problem, though it was filed as one:** the review paired this with a suspected
non-fast-forward asymmetry — that re-pushing an amended change would be rejected. It isn't. A change id
is stable across amends, so jj moves its own bookmark with no force flag and no error:

```
bookmark: push-slxllnxlmxwz [move sideways from b7e44fc98f79 to 8f82f551ad69]
```

Don't re-investigate that half.

**Pros:** a shared remote stays legible.

**Cons:** this is jj's OWN behaviour for an anonymous push, not something Workroom invented — bare
`jj git push --change` does exactly this. Diverging from it means inventing a naming or cleanup policy
that jj users won't expect from other jj tools. Doing nothing is defensible.

**Context / how to start:** `CLIVCSWriter.jjPushRevision` and the `--change` push path; the options are
(a) leave it and document it, (b) offer cleanup of merged `push-*` bookmarks, or (c) require a bookmark
before pushing, which costs the one-click Publish a fresh workroom currently gets.

**Depends on:** the VCS toolbar (shipped).

**Priority:** P3 (jj projects only; cosmetic on a personal remote, untidy on a shared one — and the
status quo matches jj's own).

### "New workroom from branch…" (macapp) — the successor to branch switching

**What:** Pick a local or remote branch and create a workroom for it, from the VCS toolbar's branch
segment or the ⌘O picker.

**Why:** Branch *switching* was deliberately cut from the VCS toolbar. A workroom's identity IS its
branch — `internal/vcs/git.go` creates it with `git worktree add -b`, and there is no `branch` field
anywhere in `internal/config` — so switching a workroom's branch makes its directory name permanently
wrong, with nothing to reconcile the two. The jj equivalent is worse: `jj new <bookmark>` on the
bookmark the toolbar already displays was reproduced **removing a file from the working copy** and
leaving the workroom's commit as a nameless dangling head, with no visible change in the UI.

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

### The other `CommandResult` consumers don't know about `signaled` (macapp) — gh-flap eng-review follow-up

**What:** consume `CommandResult.signaled` in `AgentRunner.classify`, `FileTreeModel`, and
`RustJJProvider.runCLI`.

**Why:** the gh-flap fix added `signaled` (a killed child reports its SIGNAL in `terminationStatus`, so
9 or 15 is not an exit code) and wired it into the gh classifiers plus both `CLIVCSWriter` failure
classifiers. Three consumers still read a raw exit code as evidence. `AgentRunner.classify` is the one
that reaches a user: a killed `claude` diagnosis becomes `.failed(exitCode: 9)` and the agent banner
shows "exit 9", which is exactly the class of nonsense commit `a64e4269` set out to end.
`FileTreeModel` gates on `result.ok`, so a signalled listing renders as a silently empty file tree.
`RustJJProvider` throws `VCSError.io("jj exited 9")`.

**Pros:** finishes the job — every place that reads an exit code as evidence learns that a signal is not
one. Each site is a one-line branch plus a test, since the mechanism already exists and is tested.
**Cons:** none of the three has a reported symptom, and two fail safe (an empty tree, a typed IO error)
rather than making a false claim.

**How to start:** `AgentRunner.classify` first (the only user-visible one): treat `signaled` as its own
outcome before the `exitCode != 0` branch, and mind that `timedOut` implies `signaled`, so the timeout
check must stay first.

**Depends on:** `CommandResult.signaled` (shipped).

**Priority:** P3 — cheap, but speculative until someone reports one.

### `ShellEnvironment` exposes no probe-readiness signal (macapp) — gh-flap eng-review follow-up

**What:** give `ShellEnvironment` a way for callers to know whether the interactive-shell PATH probe has
landed (or to await it), instead of silently degrading to the floor.

**Why:** `ShellEnvironment.path()` returns the probed PATH if the probe finished and the deterministic
floor otherwise, with nothing distinguishing the two. The probe is fired detached in `WorkroomApp.init`
and nothing joins it, while `refreshVCSToolReport` runs from `apply(projects)` — so a launch-time
`--version` probe can genuinely run against floor-only PATH. The floor covers Homebrew but not a
version-manager shim dir, Nix, or MacPorts, so those tools read as missing. `VCSToolVersionCache` no
longer *pins* such a verdict (it refuses to cache a discovered absence — shipped with the gh-flap work),
but that treats the symptom: any future caller reading `path()` early inherits the same ambiguity with
no way to detect it.

**Pros:** removes a whole class of "it depends when we asked" bugs, and would let the few callers that
genuinely need enrichment await it rather than guess. **Cons:** the probe is best-effort BY DESIGN — its
failures must degrade to the floor, never block — so a readiness signal must not become a hidden
dependency that stalls launch. Larger and more delicate than it first looks.

**How to start:** `ShellEnvironment.ProbeState` already tracks a generation; surface "has a probe
completed" from it, then audit `path()` callers for who should wait versus who should keep degrading.

**Depends on:** nothing.

**Priority:** P3 — the honest fix for a family of PATH-timing bugs, none currently reported.

### `VCSToolVersionCache` pins a tool verdict for the whole process (macapp) — gh-flap follow-up

**What:** give the `git`/`jj` version cache the three contracts the `gh` cache got in the same area and
this one never did: a freshness lease, a generation-stamped in-flight slot, and per-`ProjectStore`
ownership instead of `static let shared`. `Core/VCSToolVersions.swift` (the cache is the actor at the
bottom); the shape to copy is `Core/GitHubAuthCache.swift`.

**Why (the user-visible half first):** `report(probeJJ:)` caches every verdict except `.notInstalled`
**forever** — the only thing that clears `cached` is the tests-only `reset()`. So `.belowFloor` is
permanent for the process: the user reads "Git 2.41 or newer is required", runs `brew upgrade git`, and
fetch/push/pull stay disabled with the toast still standing until they relaunch the app.
`refreshVCSToolReport` does re-run on every `apply(projects)`, but it gets the pinned answer back, and
dismissing the toast (`dismissedToolWarnings`) only hides it — nothing re-probes. `gh` got a monotonic
60s/10s TTL *and* a manual Refresh; the tool whose warning names an action the user is expected to go
perform got neither.

Two structural gaps behind it, both fixed in `GitHubAuthCache` and both still live here:

- **Reentrancy loses the single-flight and can downgrade the cache.** `await task.value` suspends the
  actor with `inFlight` set, and the `inFlight = nil` after it is unconditional and unstamped. A
  `probeJJ: false` caller finishing clears a concurrent `probeJJ: true` caller's slot, so the next jj
  caller forks a third `--version` pair; and if the jj-blind lane resumes *last* it overwrites the
  jj-aware report, because `probe(probeJJ: false)` returns `jj: .notInstalled` outright and
  `hasMissingTool(probedJJ: false)` doesn't count it. Narrow (both windows normally compute the same
  `probeJJ` from the same config) but exactly the class the `gh` generation stamp exists to kill.
- **`static let shared` plus an injected `runner:` is the hazard `GitHubAuthCache` documents rejecting**
  — `make app-test` runs classes in parallel, so one test's fake runner can answer another's probe, and
  `reset()` cannot stop an in-flight task repopulating afterwards. Cheap to close here:
  `VCSToolVersionsTests` already builds fresh instances, so `AppStore` is the *only* `.shared` caller.

**How to start:** lift the `GitHubAuthCache` shape wholesale — `ContinuousClock` freshness with
injectable TTLs, generation-stamped `inFlight`, instance ownership. Only the TTL is new policy: refusing
to cache `.notInstalled` already ships, so pick a shortish lease for `.belowFloor` (an upgrade is the
expected repair and it should be noticed) and a long one for `.ok`.

**Depends on:** nothing. Adjacent to the `ShellEnvironment` probe-readiness item above — that one is
about a verdict taken too early, this one about a verdict kept too long — but neither blocks the other.

**Priority:** P3 — self-repairing on relaunch, and no report of it in the wild. The stale `.belowFloor`
alone justifies it.

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
(SwiftGitX `Patch` → text) and `RustJJProvider` (`jj diff --git` CLI text). That's the deliberate
Option-1 first cut — it works and keeps one renderer — but text is a lossy intermediate for the
features above. Both backends already expose structured diffs natively (libgit2 hunk callbacks;
jj-lib diff regions / a `computeNativeDiff` over old+new content, as jayjay does), so a structured
model would be lib-native end-to-end. Deferred because no shipped feature needs it yet, and the
rewrite touches the whole diff UI (regression surface).

> Note: the earlier "evaluate libgit2 for git diffs" framing is obsolete — git already reads through
> SwiftGitX/libgit2 (status, changeset, working + commit diff, `fileContent`). The open question is no
> longer *which* git library, but *text vs structured hunks* at the `VCSProviding` seam.

**How to start:** Add a structured `FileDiff`/`Hunk`/`Line` model + a `VCSProviding.structuredDiff`
(or evolve `fileDiff`/`workingFileDiff` to return it); git via `git_diff`/`git_patch` hunk callbacks,
jj via jj-lib regions or `compute(old,new)` fed by `fileContent`. Reuse the existing `DiffCache` +
`maxDiffBytes` gate. Rewrite `DiffViewer` (and `IntraLineDiff`/side-by-side pairing) to consume hunks.

**Depends on:** the shipped Option-1 diff pipeline (`VCSProviding.fileDiff`/`workingFileDiff` +
`DiffResolver` + `DiffViewer`). Touches `Core/VCSProviding.swift`, `GitProvider`, `RustJJProvider`,
`jj_backend.rs` (+ UniFFI), `Core/DiffResolver.swift`, `Views/DiffViewer.swift`.

**Priority:** P3 (build when a feature — ignore-whitespace / word-diff / staging / diff-edit — needs it).

### Unify `workingStatus` onto the `VCSProviding` protocol (macapp) — VCS-foundation follow-up

**What:** `workingStatus` is the one VCS read that never made it onto the `VCSProviding` protocol.
`GitProvider.workingStatus` returns a git-shaped `GitWorkingStatus`; `RustJJProvider.workingStatus`
returns the app `WorkroomStatus`. Both are concrete, off-protocol, and differently-shaped, so
`WorkroomStatusResolver` bridges each backend by hand (`resolveGit` maps `GitWorkingStatus` →
`WorkroomStatus`; `resolveJJ` calls the jj one directly).

**Why:** Every other read (log/changeset/fileDiff/workingFileDiff/fileContent/currentRef) is on the
protocol with one app-native return; `workingStatus` is the odd one out. Unifying it removes the
special-casing in the resolver and lets a future backend (or a mock) satisfy status through the same
seam. `GitWorkingStatus` (`GitProvider.swift:335`) is explicitly a placeholder — its own doc says the
jj status "unifies onto a shared `VCSProviding.workingStatus` in the follow-on."

**How to start:** Define a backend-neutral working-status return (the app already has `WorkroomStatus`
+ the jj `@`/`@-` disclosure model; give git the same shape, `.parent`/`jjWorkingCopy` fields nil for
git). Add `func workingStatus(root:) async throws -> …` to `VCSProviding`; have both providers return
the unified type; drop the `GitWorkingStatus` bridge in `WorkroomStatusResolver`.

**Depends on:** the VCS read foundation (shipped). Touches `Core/VCSProviding.swift`, `GitProvider`,
`RustJJProvider`, `Core/WorkroomStatusResolver.swift`.

**Priority:** P3 (consistency/cleanup; the hand-bridged path works today).

### Git-side errors still flatten to `.io` (macapp) — error-taxonomy follow-up

**What:** `GitProvider` throws `VCSError.io("\(error)")` from every catch, so nothing on the git path
can reach `.lockContention` / `.notFound` / `.unsupportedRepo`. The jj path is now classified at the
source; git isn't.

**Why it wasn't done with the jj half:** the blocker is deliberate and documented in `GitProvider`'s
own header — binding SwiftGitX's typed error (`catch let e as SwiftGitXError`) trips a **Swift 6 SIL
ownership error** across the async boundary, so the provider catches untyped on purpose. Classifying
would mean sniffing error *strings* (fragile, locale-adjacent) or getting the typed catch to compile.
Note the status path depends on today's behaviour: `.io` → `.notRepository` is the honest answer for
git's most common failure (a path that isn't a repo), so this is not a silent lie the way the jj cases
were — it's a missing distinction (`index.lock` contention in particular, which would map to `.busy`).

**How to start:** re-test the typed catch on the current toolchain (the SIL bug may be fixed); if it
still crashes, isolate the typed binding in a small synchronous helper the async path calls. Then map
libgit2's `GIT_ELOCKED`/`GIT_ENOTFOUND`/`GIT_ENOTREPO`-shaped cases onto the taxonomy.

**Depends on:** nothing. Touches `Core/GitProvider.swift`.

**Priority:** P3 (no wrong diagnosis today, only a coarse one).

### Git diff shows one side when a file is both staged and re-modified (macapp) — VCS-foundation eng-review

**What:** `GitProvider` working diff/status use `entry.workingTree ?? entry.index`, so a file that is
staged AND further modified in the worktree renders only the working-tree (index→worktree) delta, not
the combined HEAD→worktree change.

**How to start:** Diff HEAD-tree → worktree directly for the file (or combine index + worktree deltas)
rather than picking one status delta.

**Depends on:** VCS read foundation. Touches `Core/GitProvider.swift`.

**Priority:** P3 (partial-staging is uncommon in the workroom flow; content still shown, just one side).

### The jj snapshot ignores the user's real jj/git config (macapp) — VCS-foundation eng-review

**Status: the config stack itself has LANDED.** `wr-vcs-core/src/jj_config.rs` now layers the user's
real configuration (`$JJ_CONFIG`, else `~/.jjconfig.toml` + `$XDG_CONFIG_HOME`/`~/.config/jj/config.toml`
+ `conf.d/*.toml`) over jj's defaults, and all three call sites (`open`, `snapshot_working_copy`,
`materialize_options`) read it. That fixes the two consequences this entry never named, both of which
were live for **every** jj user rather than only non-default configs:

- **Every snapshot stamped an EMPTY committer.** `for_rewrite_from` sets
  `commit.committer = settings.signature()` unconditionally, and defaults-only settings carry
  `user.name = ""` / `user.email = ""`. Mostly invisible (`jj log` shows the author) and self-healing
  on the next real `jj` command, but NOT if `@` is pushed as-is — which the app's Push button does via
  `jj git push --change @`. Pinned by `tests/committer_identity.rs`, which fails with `<>` against the
  old code.
- **Signatures were dropped.** `Signer::from_settings` read `signing.backend = "none"`, so
  `can_sign()` was false and a rewrite of an already-signed `@` discarded its signature under the
  default `behavior = "keep"`. Now works for free, since the signer is built from these settings.

**What remains** (the original scope of this entry — the settings now reach jj-lib, so these follow,
but none is verified): `core.fsmonitor`, `working-copy.eol-conversion`, `working-copy.exec-bit-change`
and `ui.conflict-marker-style` are all derived from `TreeStateSettings::try_from_user_settings`, so
they should now be honoured — but no test covers them. The custom `core.excludesFile` chaining in
`base_ignores` is genuinely still missing. **Repo-level config is also still unread**: jj 0.43 keeps it
under `~/.config/jj/repos/<hash>` rather than `.jj/repo/config.toml`, which the current chain does not
resolve.

Original description follows.

**What:** `snapshot_working_copy` built its settings from jj's **built-in defaults only** —
`UserSettings::from_config(StackedConfig::with_defaults())` — and jj-lib derives
the whole of `TreeStateSettings` from those settings (`local_working_copy.rs`
`try_from_user_settings`): `ui.conflict-marker-style`, `EolConversionMode`
(`working-copy.eol-conversion`), `working-copy.exec-bit-change`, and `FsmonitorSettings`. So on the
one code path that *mutates* the repo, our snapshot can behave differently from the user's own `jj`:

- **fsmonitor is always off.** A user with Watchman configured (`core.fsmonitor`) still gets a full
  filesystem crawl — on every 15s status sweep, fanned out per workroom. The perf cost scales with
  repo size and is invisible to us.
- **EOL conversion / exec-bit policy are the defaults**, so a repo configured otherwise gets an `@`
  rewritten on different rules than `jj` itself would use.
- Originally filed narrower (custom `core.excludesFile`): the base_ignores fix (b7dd9b7d) chains
  git's default XDG global excludes (`~/.config/git/ignore`) + repo `.git/info/exclude` but never
  reads a custom `core.excludesFile`, so those patterns are skipped by the auto-status snapshot.

**Not affected (checked):** per-file conflict detection. `ui.conflict-marker-style` is only consumed
when *materializing* conflicts to disk (the checkout path), which this core never does; snapshot's
marker parse-back goes through `conflicts::update_from_content`, which keys on the stored
`materialized_conflict_data` marker length, not the style.

**Second site, added later:** the native ± line counts (`changed_files` → `materialize_options()`)
materialize a conflicted file to count its marker lines, so `ui.conflict-marker-style` and
`merge.hunk-level`/`merge.same-change` DO change that number. It reads jj's defaults today, on purpose
and for the same reason as the snapshot; when this entry lands, both call sites want the real settings,
not just the snapshot.

**How to start:** the config stack is loaded (`jj_config.rs`). What is left is chaining a custom
`core.excludesFile` in `base_ignores`, resolving jj 0.43's repo-level config under
`~/.config/jj/repos/<hash>`, and testing that the fsmonitor / EOL / exec-bit settings actually take
effect now that they reach jj-lib. Test on throwaway repos only — this is the lock-taking,
`@`-rewriting path.

**Depends on:** the base_ignores fix (shipped) and the config stack (shipped). Touches `jj_config.rs`
and `jj_backend.rs` (`base_ignores`).

**Priority:** P3 for what remains (only bites non-default configs); the identity + signing half that
bit everyone has shipped. The fsmonitor half is still a real perf item on large repos.

### Offer to repair a stale jj working copy from the app (macapp) — error-taxonomy follow-up

**What:** When a workroom reports `.staleWorkingCopy`, offer the repair inline (a button that runs
`jj workspace update-stale`) instead of only naming it in the Changes panel's text.

**Why:** the taxonomy work made the state *visible* and *honest* — the row no longer claims "not a
repository", and the panel says what to run — but the fix is still a manual trip to a terminal. The
state is reachable in ordinary use: workrooms of one project are jj **workspaces** of one repo, so a
`jj rebase`/`jj abandon` in workroom A can rewrite workroom B's `@` and leave B stale until B is
updated. Deliberately not done with the read work: recovering a working copy is a **write**, and every
VCS write belongs to the Phase-2 write-actions chunk (its own confirmation + undo story), not to a
status probe. jj-lib exposes `Workspace::recover`/`RecoverWorkspaceError` for it.

**Depends on:** the shipped `StaleSnapshot` classification (`jj_backend.rs` `snapshot_working_copy`)
and `VCSStatusFailure.staleWorkingCopy`. Relates to "VCS write actions — Phase 2".

**Priority:** P3 (the state is now self-explaining; this saves the trip to a terminal).

### Background fetch — cadence policy + Settings toggle (macapp) — PARTIALLY SHIPPED

**Status:** the on-focus half has **shipped** with the VCS toolbar. `RemoteStateModel.autoFetchIfDue`
fetches when the inspector gains focus, interval-guarded (5 min per project), gated on the inspector
being visible with the Changes section active, skipped entirely under the UI-test fixture, and silent
on failure — it sets the toolbar's inline error but raises no alert and never blocks a read.

**What's LEFT:** the two things this entry originally said were the reason not to "just add a fetch" —
a real cadence policy (a periodic timer, not only focus) and a **Settings toggle** to turn it off. The
5-minute interval is currently a hardcoded constant with no UI. Also worth revisiting: whether an
unattended machine should auto-fetch at all, which is a preference question, not a technical one.

**Why the staleness reasoning below still stands:** it is the clearest writeup of the problem in the
repo, and the toolbar's ahead/behind counts inherit it exactly — they are computed from local
remote-tracking refs, so they are only as fresh as the last fetch. That is why the toolbar shows "last
fetched N ago" beside the counts rather than presenting them as fact.

---

**What (original):** A periodic / on-focus `git fetch` (and `jj git fetch`) so remote-tracking refs —
and therefore the History pane's unpushed badge — reflect the server rather than the last manual fetch.

**Why:** Every push-state answer in the app is local knowledge: `GitGraph` walks
`HEAD --not refs/remotes/origin/*` and the jj core evaluates `ancestors(<tracked @origin tips>)`.
Neither touches the network. So a commit pushed from another machine keeps its badge until you fetch,
and a commit that was force-pushed away still reads as pushed. The badge tooltip is honest about this
("based on your local remote-tracking refs"), but admitting it isn't fixing it.

**Pros:** The badge (and anything later built on the same reads — ahead/behind counts, a push action)
becomes truthful without the user doing anything.

**Cons:** This turns a pure local read into a network feature: auth prompts for private remotes, rate
limits, timeouts, and partial failures on a path that today cannot fail. It needs a cadence policy and
almost certainly a Settings toggle — "just add a fetch" is the wrong shape.

**Context / how to start:** The read path itself needs no change — a fetch only has to write refs; the
per-project watcher (`AppStore.handleRootBranchChange`, which watches each project's `.git`/`.jj`) then
repaints History automatically, exactly as it does after a local push. So the work is entirely about
*when* to fetch and how to fail quietly: pick the trigger (app focus + an interval), keep it off the
synchronous log-read path, decide the credential story (the status sweep already shells `gh`, so there
is precedent for network reads), and surface failure without a modal. Deliberately NOT done as part of
the badge: see the "Staleness" trap in the unpushed-badge plan.

**Depends on:** the unpushed badge (shipped) and on-focus auto-fetch (shipped). Wants a `Defaults` key
+ Settings row, and `RemoteStateModel.autoFetchInterval` lifted out of a constant.

**Priority:** P3 (on-focus fetch covers the common case; a user who wants it OFF currently can't).

### Three independent change-badge palettes (macapp) — jj conflict-status follow-up

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

### Consolidate terminal focus authority + cross-window reconciliation (macapp) — focus-desync follow-up

**What:** (1) Collapse the ~5 duplicated "make first responder + `setSurfaceFocused`" call sites in
`GhosttySurfaceView`/`TerminalContainerView` into one guarded helper; (2) add window key-gain focus
reconciliation so the focused pane's surface reclaims first responder when the app window
reactivates (Cmd-Tab / Mission Control) and first responder had drifted to a non-terminal view.

**Current state:** The reported bug — arrows/letters dead when a TUI selection prompt appears in a
freshly-mounted/unfocused-looking pane — is **fixed**: `createSurface` now re-syncs the libghostty
focus flag when the surface is created while the view already holds first responder
(`GhosttySurfaceView.adoptFocusIfFirstResponder`, tested by `TerminalFocusAdoptionTests` +
`TerminalFocusAdoptionLiveSurfaceTests`). Focus-set logic still lives in several places
(`becomeFirstResponder`, `mouseDown`, search hand-back `:171`, `viewDidMoveToWindow`, `applyFocus`),
and `WindowRegistry`'s `didBecomeKeyNotification` observer still only updates `lastActiveStore`, not
terminal focus.

**Why:** The duplication has produced repeated focus-race fixes (#3 splits, the diff-pane fix, the
`viewDidMoveToWindow` backstop, and now this one) — each patch adds another copy and the next race
slips through the gap. One guarded helper removes that class. Cross-window reconciliation is the one
drift trigger the createSurface fix does not cover (surface already exists; first responder moved
away). Surfaced by `/plan-eng-review` (DRY finding) and the Codex outside-voice pass, deliberately
deferred to avoid refactoring focus timing before the root cause was confirmed.

**How to start:** Extract `focusTerminal(surface:)` with a single guard set; route the existing call
sites through it. For reconciliation, extend the `WindowRegistry` `didBecomeKeyNotification` handler
(`Core/WindowRegistry.swift:50`) to restore first responder to the focused pane **only** when no
sheet is open AND the current first responder is nil/the window/a removed responder (NOT a live text
field or sidebar table — codex's caveat: "no sheet" alone is insufficient). Unit-test the guard as a
pure decision.

**Depends on:** the shipped createSurface focus-sync; also relates to the queued first-responder
stale-state recheck noted under "Workroom split: deferred follow-ups" (`TerminalContainerView`
`applyFocus`) — fold both into the one helper.

**Priority:** P3 (primary bug fixed; this is the DRY/robustness follow-up that prevents the next
focus race).

### Workroom split: deferred follow-ups (macapp) — #23

**Shipped:** drag a workroom tab onto a pane edge → a nested, resizable side-by-side split of full
terminal UIs, same feel as the ⌘D terminal panes (`Views/WorkroomSplitView.swift`,
`Core/AppStore+WorkroomSplit.swift`, generic `PaneLayout<Leaf>` / `PaneTreeLayout`). The bar always
shows; `RootView` always routes the detail through `WorkroomSplitView` (single = `.leaf(selected)`).
The pieces below were explicitly deferred — each small, none blocking.

- **⌥⌘-arrow focus between workroom panes** — `PaneTreeLayout.adjacentPane` is already generic and
  ready; only the key-monitor wiring is missing. Deferred to avoid clashing with the terminal-level
  ⌥⌘arrows (which navigate the focused workroom's *terminal* split) — needs a precedence decision.
- **Drag-a-pane-out-to-dissolve** — removal today is the per-pane ✕ (strip trailing) + clicking a
  non-member tab; the terminal split's "drag the grip up out of the panes" gesture isn't wired for
  workroom panes.
- **Cross-relaunch persistence of the split** — `workroomSplit` is session-only (the terminal split
  isn't persisted either). Add a `Defaults` key + restore-on-load if wanted.
- **Per-pane activity border-flash** (partial) — the *terminals hosted inside* a workroom pane flash
  via `PaneLeafView`'s `activityPulses` handler, but the workroom **pane itself** doesn't flash the way
  a terminal split pane does; workroom-level activity surfaces via `WorkroomTabChip` tinting instead. A
  presentation difference, not a missing signal.
- **Queued first-responder stale-state recheck** (`Views/TerminalContainerView.swift:78`) — `applyFocus`
  enqueues `makeFirstResponder(view)` on `DispatchQueue.main.async` and re-checks only
  `firstResponder !== view`, not a *fresh* focus condition, so a stale enqueue could in theory flip
  focus cross-target. Largely defused already by the `surfaceActive` gate (a non-focused workroom pane
  passes `isFocusedPane=false` → never enqueues); this is the residual race within terminal-pane splits.
  Fix would re-read live focus state inside the async block rather than relying on the captured value.

**Priority:** P3 (polish on a shipped feature).

### Two split paths still bypass the pane floor (macapp) — pane-min-width follow-up

**What:** `TerminalSessions.fits` is the single floor guard (`minPaneWidth` 300 / `minPaneHeight` 120,
`eb762b87`). Two paths don't consult it, and can't today, because it measures a
`GhosttySurfaceView`'s bounds and neither path has one:

- **`AppStore.insertWorkroomSplit`** (`Core/AppStore+WorkroomSplit.swift`) — no fit guard at all, and
  workroom panes are the one place each pane renders its *own* `TerminalTabStrip`, whose diff toolbar
  alone is ~145pt (the measurement 300 was derived from). With ~700pt of content, dragging a third
  workroom chip in nests a split at `total: 348`, which trips `lengths`' even-split fallback and
  yields two 172pt panes.
- **`TerminalSessions.fits` exempts content panes** — `guard let surface else { return true }`, so
  every diff / file / changeset pane is outside the floor that exists *because of* the diff toolbar.
  ⌘D on a diff pane in a 400pt split is permitted and gives two ~198pt panes.

**Why it's still open:** both need a measured pane rect where only a surface is available today. The
views already compute one (`PaneTreeLayout.plan(_:in:)` → `plan.panes`), so the fix is to pass the
destination pane's size in at the call site rather than store frames in the model — but the workroom
drop path threads its target through a `dropTarget: (CGPoint) -> (sid, edge)?` closure owned by
`RootView` and handed down through `WorkroomSplitView` → `WorkroomPaneLeaf` → the tab bar, so it's a
signature change across several files on a drag path that only XCUITest can exercise.

`splitTab` and `moveTabIntoSplit` — the two that only needed the surface already in hand — are fixed.

**Priority:** P3 (bad layout, recoverable by resizing; no data loss).

### Pane-footer truncation is manual-verify only (macapp) — #136 follow-up

**What:** The pane footer's path segment (`TerminalStatusBar.pathSegment`) carries two deliberate
layout decisions that **no test covers**: `.truncationMode(.head)` (keep the tail, because a
repo-relative path's discriminating part is its filename and immediate directory) and
`.layoutPriority(1)` (the branch yields space before the path does).

**Why it's open:** neither test layer can see it.

- The **unit gate** can't assert SwiftUI text at all: macOS only materializes SwiftUI's a11y elements
  for a live AX client, so an `NSHostingView` in a test process reports an `AXGroup` with 0 children
  (documented at `macapp/WorkroomAppTests/HistoryCommitCardTests.swift:9-13`). `PaneRenderingTests`
  works only because `GhosttySurfaceView` is a real `NSView` it can count.
- **XCUITest** reads the accessibility *label*, which carries the full untruncated string no matter
  what is actually drawn — so a test passes while the branch has collapsed to nothing on screen.

Automating it would need image-snapshot testing, which this repo has none of and which would churn
on every theme and font change. So it's an eyeball check in the #136 verification steps: split a diff
pane narrow and confirm the path keeps its filename while the branch truncates first.

**Depends on:** nothing, but the entry above shrinks it — content panes are exempt from the 300pt
pane floor (`TerminalSessions.fits` returns `true` when there's no surface), which is what makes a
~198pt content pane reachable in the first place. Fix that and this gap mostly stops mattering.

**Priority:** P3 (degraded legibility in a narrow split; no data loss, no wrong information).

### AppKit tracking-handle divider for an even wider resize target (macapp) — #83 follow-up

**What:** Replace the SwiftUI invisible-`Rectangle` resize divider (`SplitDivider` in
`Views/PaneTreeView.swift`, `WorkroomSplitDivider` in `Views/WorkroomSplitView.swift`) with a
dedicated AppKit tracking/drag handle (pattern: the existing `InspectorResizeHandle`) so the grab
target can extend *over* the terminal surface without stealing its mouse input.

**Why:** Issue #83 widened the hit zone to `PaneTreeLayout.dividerHitThickness` (8pt = the 4pt gutter
plus the 2pt pane padding on each side). That's the safe ceiling for the overlay approach — any wider
would overhang the live libghostty surface and intercept text selection, OSC8 link clicks, the
right-click menu, and TUI mouse reporting near the gutter. A real AppKit handle owns its own tracking
area, so it can be larger and still not fight the terminal NSView.

**How to start:** Model it on `InspectorResizeHandle`; mount one per `PaneDividerFrame`, positioned on
`d.rect`, calling the same `onRatio`/`setRatio` path the current divider uses. Keep the visual gutter
invisible (the panes' own borders mark the boundary).

**Depends on:** shipping #83 first, then real-use feedback that 8pt still feels fiddly. Surfaced by the
Codex outside-voice pass during `/plan-eng-review`.

**Priority:** P3 (8pt already doubles the old 4pt target; only revisit if users still find it tight).

### Memory / live-surface diagnostics (macapp)

**What:** Lightweight instrumentation of live `ghostty_surface_t` count and process memory, to
catch leaks/growth at high tab counts.

**Why:** Each surface is a GPU-backed Metal layer; the plan flags the 50–100-tab surface budget as
"measure, don't assume." Occlusion is wired (A4) so off-screen surfaces idle, but magnitude at
Workroom's tab counts is unverified. Muxy ships a 458-line `MemoryDiagnostics` for this reason.

**How to start:** A periodic sampler logging `tabsByTarget` leaf count + `mach_task_basic_info`
resident size via `os.Logger`; optionally a debug overlay. Keep it far lighter than Muxy's — a
counter + a memory read, not crash-crumb recovery (D1). (None of this exists yet — no
`mach_task_basic_info` read, no surface-count logging.)

**Depends on:** `TerminalSessions` (surface inventory), `GhosttyApp` (`os.Logger` already set up).

**Priority:** P3 (diagnostic aid; pair with the manual surface-budget QA pass).

### OSC 52 clipboard-confirmation policy (macapp)

**What:** A real policy/UI for terminal-app clipboard access (OSC 52) — the runtime's
`read_clipboard_cb` / `write_clipboard_cb`. Today writes are gated to `text/*` mime and reads use
Ghostty's permissive default (auto-allow); `confirmReadClipboard` is a stub, so a deliberate
prompt/allowlist is deferred.

**Why:** Code-review finding #7. OSC 52 lets a remote program read/write the system pasteboard;
the permissive default is fine for a beta (it matches Ghostty's own default) but a security-minded
user should be able to require confirmation.

**How to start:** Implement `confirm_read_clipboard_cb` to surface a prompt (or consult a
`Defaults.Keys` policy: allow / prompt / deny); gate `write_clipboard_cb` similarly. Decide the
default (Ghostty = allow).

**Depends on:** the clipboard callbacks already wired
(`macapp/WorkroomApp/Core/GhosttyRuntimeAdapter.swift`, `Core/GhosttyApp.swift`).

**Priority:** P3 (permissive default is acceptable for the beta).

### Quick-switcher deferrals (macapp) — #132 follow-ups

**What:** Six things the ⌥Tab / ⌃Tab switcher shipped without, deliberately. Independent of each
other; take them one at a time.

- **MRU order in the ⌘O Open Workroom picker.** `SwitcherRecency` already answers "what did I use
  last", so `OpenPickerModel` could rank by it instead of alphabetically. Cheap, but it reorders a
  shipped, tested surface (`OpenPickerModelTests`) — hence deferred until we've lived with MRU in the
  switcher and know it feels right there first.
- **Settings UI for the two trigger modifiers.** `Defaults[.switcherWorkroomModifier]` /
  `[.switcherPaneModifier]` ship with no picker, so retuning them needs `defaults write`. They exist
  because a global-hotkey grabber (AltTab, HyperSwitch, Contexts all bind ⌥Tab) intercepts upstream of
  `NSApp.sendEvent` where no local monitor can see the key — i.e. the *only* remedy for an affected
  user is a preference they currently can't reach. The Keyboard Shortcuts sheet already renders the
  configured chords (`SwitcherModifier.display`), so the picker is the missing half.
- **Scope ⌥Tab to the current Space.** A cross-window commit to a window on another Space animates the
  Space switch for ~0.5–1s. Nothing is wrong, but it's a jarring result for a keystroke that reads as
  instant. Either filter `QuickSwitcher.workroomSlots` by `hostWindow?.isOnActiveSpace` (and lose the
  ability to reach those workrooms at all) or leave it; decide from use, not from taste.
- **The shared `UnreadBadge` still draws the RAW accent.** The rail passes its own corrected pair
  (`Palette.nsBadgeFill` == `nsRing`, ink measured), because a themed accent can sit close to the
  surface it's on — the sidebar and toolbar badges have the same exposure and no correction. Now a
  small change: `ThemeTokens.contrastRatio` is genuinely WCAG since `dfcc0bd8`, so
  `legible(accent, on: host, target: 3.0)` at the component's own call sites means what it says.
- **The 10s session ceiling cancels silently.** A stuck modifier can't leave the rail up forever, so
  `QuickSwitcherReducer.sessionCeiling` ends the session — with **no commit**, so a user who held ⌥ for
  eleven seconds while reading the rail gets nothing. Arguably the timeout should commit the cursor
  instead. A product call, not a bug: pick one and say so in the reducer's doc comment.
- **⌃-click on the pane rail is unverified.** ⌃-click is a secondary click, and the rail panel is never
  key, so it may not deliver a `.onTapGesture` at all. Needs a **real mouse** — this repo has twice
  been lied to by synthetic input (`macapp-textselection-swallows-taps`,
  `macapp-hover-slide-release-only`), so an XCUITest pass here would prove nothing.

**Why:** each of these was written down in the #132 plan's out-of-scope table and would otherwise be
lost with it. Two other entries from that table are now **moot**: the window-capture layer was built
and then removed (an aspect-fit terminal thumbnail at card size is a grey smudge that looks like every
other terminal), so "a libghostty damage callback for thumbnail freshness" and "per-pane sensitive
marking / screen-sharing auto-suppress" no longer have a subject — `Core/Snapshots/` is gone and the
rail draws marks and miniatures instead.

**Depends on:** nothing. The badge item wants `dfcc0bd8` (the contrast-metric fix), which has landed.

**Priority:** P3 for all six, except the Settings picker, which is **P2 for anyone running a hotkey
grabber** — for those users ⌥Tab never arrives and the workaround is unreachable from the UI.

### Stream the inline terminal agent's diagnosis into the banner — #49 follow-up

**What:** Show the diagnosis appearing live in the banner (claude `--output-format stream-json`)
instead of a spinner during the (blocking) call.

**Why:** Nicer perceived latency. Deferred deliberately, not dropped: (1) the diagnosis output is a
structured JSON object (`{summary, fix, detail}`) — that's what makes the "Insert fix" button
reliable (the on-demand eval validates it) — and streaming emits partial JSON deltas that don't
render nicely; (2) the inline diagnosis now runs on Haiku 4.5 (~2-3s), so the spinner is brief and
the payoff is marginal.

**How to start:** The clean approach that preserves the structured fix is to change the model's
output to "one-line prose summary, then a delimiter, then the JSON fix", stream the prose live while
parsing the JSON tail on completion. Needs: an incremental-stdout streaming runner (the current
`StatusCommandRunner` buffers to completion), a stream-json NDJSON delta parser, the split prompt +
parser, banner partial-text state, and its own entry in `AgentDiagnosisEvalTests`.

**Depends on:** the inline agent (#49, merged). Touches `AgentRunner`, `AgentPrompt`,
`TerminalAgentManager`, `TerminalAgentBanner`.

**Priority:** P3 (polish; marginal over a 2-3s spinner, and must not regress the structured fix).

## P3 — Inspector, window layout, and theming

### Back/forward doesn't reinstate the inspector section (macapp) — nav-history follow-up

**What:** `activeInspectorSection` is not part of a `NavLocation`, so ⌘[/⌘] never moves it. Add it to the
location and map content kinds to sections (`.diff`/`.file` → `.changes`, `.changeset` → the pane holding
History), suppressed under replay so it doesn't write the persisted default.

**Why:** narrower than it first looks, and worth stating so nobody re-scopes it wrongly:
`ActivitySection.changes` stacks `[.changes, .history, .pullRequest]` as sub-sections of **one** pane, so
moving between a diff and a commit needs no section switch at all — both lists are already on screen.
The only real case is **Files ↔ Changes**: open a file from the Files section, press Back to a diff, and
the pane is correct while the inspector still lists files, so no row highlights.

**How to start:** `AppStore.activeInspectorSection` (`@Published`, persisted in its `didSet`) plus the
`FocusedTabSelection` → `ActivitySection` mapping. `withHistorySuppressed` already exists for the
replay-side guard.

**Depends on:** nothing.

**Priority:** P3 (cosmetic — the detail pane, which is what the bug report was about, is correct in every
case; only the inspector's list can be the wrong one).

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

### Profile inspector pane body during live divider-drag (macapp) — NSSplitView inspector follow-up

**What:** Verify there's no stutter when dragging an inspector section divider with a large Changes
set. The NSSplitView inspector (shipped) hosts each section body inside a native `NSScrollView`, so
a vertical divider drag changes only the pane's *viewport height* — the body's `NSHostingView` keeps
its intrinsic (content) height and its width is unchanged, so SwiftUI should NOT re-lay-out per
frame. This TODO is to confirm that under profiling, not a known regression.

**Why:** `ChangesPanel` can render up to ~200 non-lazy file rows. (An earlier version of this entry
put the worst case at ~400 across **two** lists — the jj Parent Commit group, its disclosure state and
its `Defaults` collapse flags are all gone; the panel is now one unified working-copy list for both
backends, so the ceiling is back to one list's worth.) The original eng-review of the migration plan
flagged per-frame re-layout as a risk; the scroll-view pane design should avoid it (drag = viewport
change, not document re-layout), but it hasn't been profiled.

**How to start:** Instruments (Time Profiler / SwiftUI body re-evaluation) while dragging the
Changes divider on a fixture with ~200 changed files. Only if jank shows: coalesce
resize → re-layout, or `.drawingGroup()` the body for the drag duration. Note `LazyVStack` won't help
here — the pane scrolls via AppKit `NSScrollView` with an intrinsic-size host, so there's no SwiftUI
clip rect to virtualize against.

**Priority:** P3 (likely already a non-issue by construction; confirm before optimizing).

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

### Per-reviewer comment counts in the PR panel (macapp) — #52 follow-up

**What:** Show a per-reviewer comment count next to each reviewer row in the Pull Request panel,
e.g. `iainad approved · 3 comments` — the `[N comments]` part of the issue #52 mockup.

**Current state:** #52 shipped the per-reviewer rows (state + bot-aware "in progress" label) by
riding the existing `gh pr list --head … --json …` probe, which carries `latestReviews` /
`reviewRequests` but **no review-comment counts**. The rows show state only.

**Why:** richer signal at a glance — how much feedback a reviewer left, not just their verdict.

**How to start:** counts aren't in `latestReviews`, so this needs a second call —
`gh api repos/{owner}/{repo}/pulls/{number}/comments` (review/diff comments) grouped by
`user.login` — added to `resolvePR` (`Core/WorkroomStatusResolver.swift`) and surfaced on
`Reviewer` (e.g. an optional `commentCount`). Weigh the extra network round-trip on the already-slow,
TTL-throttled PR probe; consider fetching counts lazily/only for the selected PR. Map counts onto
the existing identity-keyed fold; teams won't have counts.

**Depends on:** the #52 reviewer rows (shipped).

**Priority:** P3 (nice-to-have; deliberately deferred from #52 to keep that change to free data).

## P3 — Notifications and run commands

### OSC 99 desktop notifications (macapp) — blocked upstream, watch ghostty 1.4.0

**What:** support Kitty-style OSC 99 notifications (`printf '\e]99;;done\a'`). Nothing to build here
yet — this entry exists so the gap stays tracked and nobody re-derives the upstream state.

**Why it's a gap:** SwiftTerm parsed OSC 99; libghostty does not, so this is a regression against the
app's own prior behaviour. OSC 9 and OSC 777 work today
(`GhosttyRuntimeAdapter` `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`), which covers the common cases.

**Upstream state (checked 2026-08-05) — the important part:**
- Issue **ghostty-org/ghostty#5634** is open, assigned, milestone **1.4.0**.
- PR **#10467** ("parse the Kitty desktop notification protocol (OSC 99)") is open, rebased and
  described by its author as ready — but it adds **only a parser**. Its one-line `stream.zig` change
  files `.kitty_desktop_notification` in the branch that logs `"unimplemented OSC callback"` and
  discards it. Its own description says: *"This includes only parsing of the OSC. You cannot (yet)
  use OSC 99 to send notifications."*
- Three further pieces are needed before an **embedder** sees anything: stream dispatch, a
  Surface/apprt action (OSC 99's richer model — id, urgency, icon, chunked payloads — does not fit
  the existing 2-field `DesktopNotification`), and a `ghostty_action_*` tag in `include/ghostty.h`.
  **None exists as an open or merged PR.**

**So: the re-check trigger is "ghostty 1.4.0 ships", NOT "#10467 merges".** Merging #10467 alone
changes nothing observable, and cherry-picking it into a fork of our own would not either — this is
why the OSC 99 rationale was struck from CMT-2.

**Depends on:** upstream only. Then the pin bump (or whatever engine source we're on) to pick it up.

**Priority:** P3 — one escape sequence, with two working alternatives already wired.

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

### Stopped run-tab silently closes instead of warning when its command is cleared (macapp) — #127 follow-up

**What:** `runOrFocusRunCommand()`'s `.stopped` case routes through `restartRunCommand` →
`respawnRunCommand`, which checks `hasRunCommand` and — if false — just closes the stopped-but-open
run tab and returns. No settings sheet, no warning, nothing.

**Why:** #127 gave the `.armed/.none` case (nothing has ever run) a "no command configured" warning
sheet instead of a silent no-op. `.stopped` never got the same treatment, so the gap is now
inconsistent: repro is run command configured → it stops (pane stays open) → user clears the command
via Project Settings → next ⌘R on that target silently destroys the stopped pane instead of
explaining why nothing (re)started. Found by the outside-voice adversarial review during #127 (Codex);
this branch predates #127 and wasn't touched by it, so it's a pre-existing gap in the original #7
feature, not a regression — but #127 makes the inconsistency more visible.

**How to start:** Mirror the `.armed/.none` branch's `hasRunCommand` check + `pendingProjectSettings`
routing inside `respawnRunCommand` (`AppStore.swift`, guard at line ~1465) before it unconditionally
closes the tab. Needs care around issue #67's focus-preservation semantics (`wasFocused`) — that
logic wasn't reviewed against this change.

**Depends on:** #127 shipping first (`AppStore.swift`'s `PendingProjectSettings` +
`pendingProjectSettings`).

**Priority:** P3 (pre-existing, narrow repro — needs a run to have started and stopped, then the
command cleared before the next ⌘R; surfaced by the #127 eng/outside-voice review, not reported by a
user).

## P3 — Tests and tooling

### Deferred UI workflow tests (macapp)

**What:** The two workflow UI tests left to write on top of the now-landed fixture seam:
1. **Notification badge + click-to-navigate** — drive a terminal to `printf '\e]9;…\a'`, assert the
   sidebar/tab badge appears, click it, assert it navigates to (and clears on) the right terminal.
2. **Delete-workroom-clears-badges** — assert deleting a workroom withdraws its notifications/badges.

**Why:** The fixture seam itself is done (`Core/UITestFixture.swift` + `-WorkroomUITestFixture 1`
gives deterministic, CI-able state — see `AppStore.loadFixture()`), and the split-pane + basic
workflow suites pass deterministically (no `XCTSkip`). These two notification/delete flows are the
remaining gap, called out explicitly in `WorkroomWorkflowUITests.swift` ("Still to add: …").

**How to start:** Add the tests to `macapp/WorkroomAppUITests/WorkroomWorkflowUITests.swift` using
the existing fixture launch arg and the `sidebar.*` / `terminal.tab.*` accessibility identifiers. The
badge assertions need the notification a11y identifiers to be queryable — add them if missing.

**Depends on:** the fixture seam + accessibility identifiers already in place
(`macapp/WorkroomApp/Core/UITestFixture.swift`, `Views/ProjectSidebar.swift`,
`Views/TerminalTabStrip.swift`).

**Priority:** P3 (the smoke + opportunistic suites cover the basics; these harden the notification
flows).

## P3 — Performance and diagnostics (WORKROOM-2B follow-ups)

### Status-aware avatar image loader (macapp) — WORKROOM-2B follow-up

**What:** Replace `AsyncImage` in `AvatarView` (`Views/Avatar.swift`) with a small loader that reads the
HTTP status, caches decoded images in memory, caches genuine 404s, and retries transient failures.

**Why:** the shipped mitigation (`AvatarImageFailures`) is a session set of URLs whose load *failed* —
and `AsyncImage`'s `.failure` phase carries an error, not a status, so "this author has no Gravatar"
and "the network dropped" are indistinguishable. The set is therefore cleared on app activation, which
bounds the damage but means an offline scroll shows initials until the user comes back to the app. A
status-aware loader removes the ambiguity, and gets image caching (no flicker on re-realization) for
free. Gravatar is requested with `d=404` on purpose, so a miss really is a 404 — the information is
there, `AsyncImage` just doesn't expose it.

**Current state:** `AvatarImageFailures.shared` + the `.failure` branch in `AvatarView.body`. Covered
by no test: `AsyncImage` offers no injection seam, which is itself part of the argument for replacing it
(a hand-rolled loader is testable behind a `URLProtocol` stub).

**How to start:** `AvatarView.body`'s image branch and the `AvatarSubject.imageURL` contract. Keep the
`.loadRemoteAvatars` privacy gate exactly as it is — no request may be issued when it's off. Bound the
image cache (count or bytes); Gravatar/GitHub avatars are 16–54 px, so it stays small.

**Depends on:** nothing (the lazy History list that made repeated loads visible has landed).

**Priority:** P3 — the current mitigation covers the common case; this is the correct version.

### `FilesPanel` renders up to 4000 rows eagerly (macapp) — WORKROOM-2B follow-up

**What:** `Views/FilesPanel.swift:58-60` builds every visible tree row in an eager `VStack`, capped at
`FileTreeModel.renderCap = 4000`, and each row holds `@EnvironmentObject store` + `@ObservedObject
model`.

**Why:** this is the third instance of the pattern that produced the WORKROOM-2B App Hang — eager stack
plus per-row observation of a publishing object — and its cap is 20× the Changes panel's 200. The
History pane took >2 seconds of main thread at ~1000 rows of comparable per-row work.

**Why it is NOT P1:** unmeasured. No hang report names Files, and `FileTreeModel` publishes far less
often than `TerminalSessions` did (tree loads and expand/collapse, not terminal output), so the
high-frequency trigger that made History fatal may simply not exist here. Tree rows also carry
expand/collapse state, which lazy stacks handle less predictably than fixed-height list rows.

**How to start:** measure before changing anything — add a `#if DEBUG bodyPasses` counter to the row
(same shape as `HistoryRow`/`ChangedFileRow`) and count passes per `FileTreeModel` publish with a large
expanded tree. If the number is large, the fix is the one this branch established: hoist the selection
lookup into the panel, give the row an `Equatable` gate, and switch the stack to `LazyVStack` (only if
the rows are fixed-height — see the comment at `Views/DiffViewer.swift`'s `unifiedBody` for when lazy
is wrong).

**Depends on:** nothing; the counter harness and the pattern both exist now.

**Priority:** P3 — structural risk, no measured symptom.

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

## P3 — CLI

### Harden `vcs.Detect` to validate a real repo (CLI) — #103 follow-up

**What:** `vcs.Detect` (`internal/vcs/vcs.go`) currently treats a directory as a repo if `.jj` is a
dir OR `.git` merely *exists* (file or dir). A bogus/empty `.git` therefore registers as a project
via `add-project` and only fails later, at workroom creation.

**Why:** Surfaced by the Codex outside-voice pass during `/plan-eng-review` of issue #103 (the
create-project work). It's a pre-existing robustness gap — the existing-path `add-project` already
has it; #103's create flow inits a real repo so its happy path is unaffected — but a stricter check
would fail fast with a clear error instead of a confusing late failure. Re-confirmed by the Codex
pass during the jj→git stale-vcs fix: the new reconcile-on-list (`Service.effectiveVCS`) also uses
marker-file truth, so a *present-but-broken* `.jj` dir would still reconcile as jj — hardening
`Detect` fixes both the late-failure gap and the reconcile accuracy in one place.

**How to start:** In `Detect`, validate beyond existence — e.g. `git rev-parse --git-dir` (or read
`.git`/`HEAD`) for git, and confirm `.jj/repo` for jj. Weigh that `Detect` runs on every
create/list/delete (now also list-reconcile), so keep it cheap (a stat-level check may suffice over
forking git).

**Depends on:** nothing; touches all VCS consumers (`create`, `list`, `delete`, `add-project`).

**Priority:** P3 (pre-existing; create-new path inits a valid repo, so not blocking #103).

### The config lock can be stolen from a live holder (CLI) — `withLock` audit

**What:** give the config's advisory lock (`Config.withLock`, `internal/config/config.go`) an
*ownership token* and a heartbeat, so a lock is only ever removed by the process that holds it, and
"stale" measures time since the holder last made progress rather than time since it started.

**Why:** the lock file carries no identity — it is created empty with `O_CREATE|O_EXCL` and released
by an unconditional `defer os.Remove(lockPath)` that deletes *whatever* file is at that path, not the
one this process created. So a steal silently unlocks a live holder:

```
  A: creates lock ─────── fn (stalls > staleAfter) ────────► defer Remove  ← deletes B's lock
  B:                       stat says stale, Remove + create ──── fn ─────────────► (unprotected)
  C:                                                    creates lock ── fn ──► interleaves with B
```

Two read-modify-write cycles then interleave on `config.json`, and because each one `Read`s the whole
map and `Write`s its own snapshot back, the loser's edit vanishes — a workroom or project silently
disappearing from the sidebar, which is precisely what this lock exists to prevent. There is no error
on any path: both writes "succeed".

The staleness rule makes that reachable rather than theoretical. The lock file's mtime is stamped at
creation and never refreshed, so `time.Since(info.ModTime()) > staleAfter` is really "has been held
for 10s", not "has been abandoned" — any holder that genuinely takes longer (a home dir on a synced
or network volume, a machine under heavy load, a CLI paused under a debugger) is declared dead while
it is still working.

Two constants that don't agree, worth settling in the same pass: the wait loop gives up after
200 × 10ms ≈ **2s** while `staleAfter` is **10s**, so a waiter can never actually reclaim a lock
orphaned by a crash *during its own wait* — it spins for two seconds and then proceeds **unlocked**.
The unlocked fallback is deliberate (documented: never fail an operation over the lock), but it means
that after a crash every writer for the next 10s runs with no mutual exclusion at all, and that is
when the app and the CLI are most likely to be writing together.

**How to start:** write a nonce (pid + a random token) into the lock file; release with a
read-compare-then-remove, and steal only after re-reading the same nonce you judged stale. Refresh the
mtime periodically from the holder (or record a deadline in the file) so staleness tracks liveness.
Then make the wait cap and `staleAfter` consistent. Testable without concurrency by injecting the
clock and the nonce — today's only lock test (`TestWriteAtomicLeavesNoTempOrLockFiles`) asserts
cleanup, not exclusion.

**Depends on:** nothing. Pure `internal/config`; no caller signature changes.

**Priority:** P3 — every `withLock` body is a short read-modify-write today, so the >10s stall that
opens the window is rare. Cheap to close, and the failure it produces (a silently lost entry, no
error) is one of the hardest to diagnose from a bug report.

## Recently done

Condensed from the long status notes this file used to carry at the top; the full write-ups are in git
history. Kept here for the parts that stay useful: what changed, and the traps found doing it.

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
