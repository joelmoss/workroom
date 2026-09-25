# macOS App Guidelines

The Workroom macOS app: a SwiftUI (macOS 15+) front-end that bundles the `workroom`
Go binary and drives it over the CLI's `--json` contract. See README.md and CONTRIBUTING.md for full
architecture, signing, and notarization detail — this file is the quick reference.

## Dev tasks (Makefile)

Every dev task runs through the **repo-root `Makefile`**, namespaced `app-*` (run from the repo
root, not `macapp/`):

```bash
make app-run        # canonical local loop: xcodegen → xcodebuild (Debug) → relaunch
make app-build      # xcodegen → xcodebuild (Debug)
make app-test       # xcodebuild test (WorkroomAppTests) — parallel; APP_TEST_FLAGS= to serialize
make app-test-scripts # shell-script tests (build-helper archs, channel classify) — no toolchain
make app-generate   # force-regenerate the (gitignored) .xcodeproj from project.yml
make app-vcs        # build the Rust VCS core → WrVcs SwiftPM package (auto-run before app builds)
make app-format     # swift-format, rewrite sources in place
make app-lint       # swift-format --strict (non-zero on any violation — the hard gate)
make app-release    # Release build → notarize → staple → DMG installer (Scripts/release.sh).
                    # Gated on app-test + app-test-scripts: several assertions exist to stop a bad
                    # ARTIFACT shipping (bundled-resource checksums, universal-arch cases), and a
                    # CI-only gate can be outrun by a release cut from a dirty tree.
make app-icon       # regenerate AppIcon PNGs (Scripts/make-icon.swift)
make app-clean      # remove DerivedData + .xcodeproj
```

Builds reuse `macapp/DerivedData/` so the Swift packages (incl. the GhosttyKit xcframework)
aren't re-resolved/re-downloaded every build. (`cli-*` targets cover the Go CLI — see the root
AGENTS.md.)

## VCS core (Rust jj + SwiftGitX git)

Workroom reads VCS data through **two backends behind one Swift layer** (the app is growing into a
VCS-first IDE — issue #59 is the first brick):

- **jj → Rust `jj-lib` via UniFFI.** The `vcs/` Rust workspace (jj-only) builds a static xcframework
  + generated Swift into the local SwiftPM package `vcs/swift/WrVcs` — the app does `import WrVcs`.
- **git → SwiftGitX (libgit2), pure Swift.** git has a mature native Swift path; jj has none — so
  only jj needs the Rust/UniFFI bridge. (An all-Rust core with gix was tried and dropped: gix bought
  no real unification and libgit2 is the more complete git engine.)

**Three reads reach past SwiftGitX**, all linking the `libgit2` C API **directly** (its own SPM package
in `project.yml`, URL + version identical to SwiftGitX's own dependency so SwiftPM sees one package
identity). `Core/LibGit2.swift` owns the single `git_libgit2_init` and hands out raw `git_repository`
handles (SwiftGitX inits inside `Repository.open`, which a direct C caller can't rely on); these four
files are the only ones in the app touching raw libgit2:

- **Push state — `Core/GitGraph.swift`.** SwiftGitX cannot express a commit *range*: its
  `CommitSequence` only calls `git_revwalk_push`, never `git_revwalk_hide`, it exposes no
  merge-base/graph helper, and its repository pointer is `internal` — so "which commits aren't on
  `origin` yet" (`HEAD --not refs/remotes/origin/*`) needs the C API. The jj side answers the same
  question natively with one `ancestors(<tracked @origin tips>)` revset. Push state is
  **origin-scoped** and any unreadable ref degrades the WHOLE page to "unknown" (no badge) rather than
  a partial answer.
- **Commit diffs — `Core/GitCommitDiff.swift`.** Rename detection is `git_diff_find_similar` run over a
  live `git_diff`, and a SwiftGitX `Diff` materializes its deltas/patches in an `internal` init and
  frees the `git_diff` before returning, so there's nothing left to detect on. Without it a committed
  rename read as delete + add while `git show` showed one rename row (git defaults to
  `diff.renames=true`), and a root commit's diff came back empty (SwiftGitX diffs it against itself).
  Detection options are NULL, which is what makes libgit2 read the repo's own `diff.renames` /
  `diff.renamelimit` — naming a flag explicitly suppresses that config read, so a repo set to
  `diff.renames=false` or `=copies` would silently disagree with its own CLI. Typechanges are included
  (`GIT_DIFF_INCLUDE_TYPECHANGE`); without it libgit2 splits a file↔symlink change into delete + add
  on the SAME path, giving the file list two rows with one `id`. `GitProvider.changeset`/`.fileDiff`
  both read through it, so the History file list and the patch text can't disagree.
- **Working-tree ± line counts — `Core/GitDiffStats.swift`**, via `git_diff_get_stats`. SwiftGitX
  surfaces no diffstat, and its `Diff` is **eager**: `Diff.init` builds a `Patch` per delta and
  materializes every hunk line into a Swift `String` before the caller sees it. Summing those for the
  badge cost one `String` per changed line of the whole worktree on **every** status refresh, so the
  counts moved to libgit2, which counts in C and allocates nothing Swift-side. The diff itself is
  irreducible — that's what `git diff --shortstat` costs too. With `changeset` now counting through
  `GitCommitDiff`, **no** `+N −M` in the app is summed off SwiftGitX hunk lines any more, which also
  ends a real bug: that sum counted the EOFNL markers (`\ No newline at end of file`) as lines, so
  changing only a file's trailing newline reported two deletions where git reports `1 insertion(+),
  1 deletion(-)`. libgit2 skips them, as `git diff --shortstat`/`--numstat` do. It runs
  `git_diff_find_similar` too, for the same reason `GitCommitDiff` does: the file list beside these
  counts already pairs renames (libgit2 status' `.renamesIndex`/`.renamesWorkingTree`), so without it
  a staged rename rendered as one "renamed" row badged `+N −N` while `git diff HEAD --shortstat`
  reported `0 insertions(+), 0 deletions(-)`.

**Read surface & routing.** `Core/RepositoryServices.swift` defines the context-bound `VCSProviding`
protocol. `RepositoryRouter` captures the backend and shared ownership for a validated host/path
identity; native engines implement `LocalVCSProviding` behind its local adapter. `RustJJProvider`
maps `WrVcs.*` → app-native models, and `GitProvider` wraps SwiftGitX. `WorkroomStatusResolver` and `BranchResolver` read through this layer — **the jj CLI
parsers are gone** (log/changeset/currentRef/workingStatus are all native jj-lib).

**The two mutating reads: jj working-copy status and working-copy diffs.** jj's working copy is
itself a commit, so on-disk edits don't exist to jj-lib until snapshotted — a working-copy status
read (`RustJJProvider.workingStatus`) therefore *must* snapshot `@` first: it takes the working-copy
lock and rewrites `@` (modeled on jayjay's `refresh_working_copy`). A working-copy file diff
(`workingFileDiff` with base `.workingCopy`) runs `jj diff` without `--ignore-working-copy`, so it
snapshots too. `BoundLocalReader` routes both through `JJSnapshotGate` and requires the context's
shared ownership (`requireOwnership()`), so an unregistered repository cannot snapshot. Immutable
revision reads (log/changeset/currentRef) stay a read-only `load_at_head` with no lock and no gate.
Because they mutate, **only test snapshot changes on throwaway repos** (corruption risk). Status
line counts come from the SAME native status read — `changed_files` materializes each changed file's
two sides and counts them, so `resolveJJ` fires no `jj diff --stat` process (it used to; see
`40456bae`). Oversized and binary files report no count rather than being read whole. Cargo coverage:
`vcs/crates/wr-vcs-core/tests/working_status.rs` + `line_stats.rs`; Swift coverage:
`WorkroomStatusIntegrationTests.testJJ*`.

`make app-vcs` (→ `vcs/scripts/build-apple.sh`) builds the Rust artifacts and **runs automatically
before `app-build`/`app-test`/`app-generate`** (a Makefile prerequisite). Requirements:

- **`protoc`** on PATH (`brew install protobuf`) — a build-time dep of jj-lib.
- arm64 by default; **`make app-release` builds universal** (`VCS_APPLE_FLAGS=--universal`), which
  needs **rustup `stable` ≥ 1.93** + `rustup target add x86_64-apple-darwin aarch64-apple-darwin`
  (Homebrew's rust can't cross-compile; the script preflights this and errors clearly). It also
  cross-builds the Linux agents, which need cargo-zigbuild and the two musl targets (see "Linux
  agents" below).
- **Unchanged inputs are a no-op.** The script hashes the Rust sources, manifests/lockfile, itself,
  `rustc --version` and the arch flavour into `vcs/swift/WrVcs/Frameworks/.build-stamp`, and exits
  early when that matches and the outputs exist. `WR_VCS_FORCE=1 make app-vcs` rebuilds regardless.
  CI leans on this: it caches the *outputs* keyed on the same inputs, so a commit that doesn't touch
  `vcs/` skips the ~4-minute crate-graph build (and `make app-test`'s own `app-vcs` prerequisite
  stays free).
- **Xcode-driven builds are gated, not auto-fixed.** ⌘R/⌘U (and a raw `xcodebuild`) skip the
  Makefile, so they'd otherwise link the last-built core. A `Rust VCS core up to date` pre-build
  phase runs `build-apple.sh --check` and **fails the build** with `run 'make app-vcs'` when the
  stamp doesn't match `vcs/`. It can't rebuild for you: SPM extracts the binaryTarget's xcframework
  before target build phases run, so a fresh `.a` wouldn't reach that build's link. Silently linking
  a stale core cost a debugging session once — conflicted files read as `.modified` because the
  linked core predated a merged per-file-conflict fix.

The xcframework + generated Swift are **gitignored and regenerated**; only `Package.swift` + a
`shim.c` are tracked. Packaging note: the xcframework is **library-only** (no headers) and the FFI
Clang module (`wr_vcs_uniffiFFI`) is a separate SPM C target — a headers-bearing static xcframework
copies its `module.modulemap` into the shared `Debug/include/` and collides with GhosttyKit's
("Multiple commands produce include/module.modulemap").

## Terminal sessions: `wr-agent` (Rust) and the daemon it replaces

A pane's shell outlives the pane, so the app does not own the pty — a **session helper** does, and
the app attaches to it. There are two, mid-migration (issue #154, Phase 1):

- **`wr-agent`** (`vcs/crates/wr-agent`, Rust) — where every NEW session goes. One binary,
  `serve | attach`, multiplexing services over one stream with a versioned envelope
  (`service:u8 | stream:u32 | length:u32 | payload`). It keeps a **shadow terminal** (libghostty-vt,
  behind the `terminal-state` cargo feature) so a reattaching pane is repainted from emulator state
  rather than a byte replay. A newer app does not kill a running agent: it asks it to replace its
  own program with the bundled binary in place, keeping its pid and every session
  (`AgentHandOff.start()`, protocol 6, `wr-agent hand-off`), gated to Nightly and Dev (#230); see
  the "As built (#230)" section of `docs/designs/remote-workrooms.md` for the mechanics.
- **`workroom-session`** (`macapp/WorkroomSession/`, Swift) — the shipped daemon. It keeps the
  sessions it already holds until the user closes them; it cannot hand a live pty over.

**The migration is a drain, not a switch.** `SessionBackend.preferred()` returns `.rustAgent` unless
the agent fails its probe; `PersistentSessionService.backend(forSession:)` resolves each EXISTING
session to whichever helper owns it. Two rules there are load-bearing and were both got wrong once:
the answer is resolved **once per session and cached** (a pane asks twice — `attachCommand` for the
binary, `launchEnvironment` for the socket — and the two must agree, or the daemon binds the agent's
socket), and an **unanswered** ownership probe resolves to *neither* — `backend(forSession:)` returns
nil and the pane opens a plain shell until a later probe succeeds. There is no safe guess, because
**both** helpers create-on-attach: `SessionDaemon.handleAttach` ends in `create(request:connection:)`
for an id it does not hold, exactly as the agent does, so either guess forks a second pty under the
same id and orphans the user's shell. A failed `connect` is NOT an unanswered probe — it means
nothing is listening, which is a definitive "not owned" (the daemon leaves a stale `session.sock`
behind on any `pkill`, so this case is common, not exotic).

**Building it.** `macapp/Scripts/build-agent.sh` is a build phase, mirroring `build-helper.sh` (the
Go CLI): it iterates `ARCHS`, so a universal Release build produces both slices and `lipo`s them. The
built binary is staged beside `$DEST` and **renamed into place, never written over it** — a running
agent executes that file, and macOS SIGKILLs a process whose signed binary changes under it ("Code
Signature Invalid"); writing in place used to kill every Dev session, and any hand-off (#230), on
each rebuild. `build-agent_test.sh` guards both that loop — the same regression once shipped an
arm64-only CLI inside 23 universal betas — and the rename (a hard link stands in for the running
binary, and a rebuild must leave it unwritten); the cross cases need `rustup target add
x86_64-apple-darwin aarch64-apple-darwin`, which CI installs. `terminal-state` is **not optional for
the app**: without it a reattaching pane repaints blank, which only shows up after a
quit-and-relaunch. `wr-agent protocol` reports `terminal-state yes|no`, and the build test asserts it
against the shipped binary.

**Linux agents (issue #227).** Release and Nightly builds also put a static musl `wr-agent` per
Linux arch in `Contents/Resources/wr-agent-linux-{aarch64,x86_64}`, for pushing to remote hosts.
Both arches ship always, whatever `ARCHS` says, because a remote box's arch has nothing to do with
the Mac's. They are not codesigned; the app's signature seals them as resources. Debug skips them
(and removes stale ones) unless `WR_AGENT_LINUX=1`. Building them needs `cargo install
cargo-zigbuild --locked` and `rustup target add aarch64-unknown-linux-musl
x86_64-unknown-linux-musl`, which the release workflows install. `release.sh` asserts both ELFs are
present and static, and the `agent-linux` CI job runs `protocol` on each under Linux.
`AgentBootstrap.connect` (#231) pushes the matching one to a remote host on first connect, beside
the agent's socket, and hands the running agent off to it; the far side is
`Resources/agent-bootstrap/{probe,install}.sh`, run through `HostDriver.exec`. See the "As built
(#231)" section of the design doc, and `vcs/scripts/ssh-fixture/run.sh` for running its tests.

The Zig toolchain and the pinned Ghostty engine come from `vcs/scripts/build-ghostty-vt.sh`
(cached per `(engine sha, target)` outside the repo). That pin must stay in step with the
GhosttyKit the app links — see the comment in `project.yml`.

## Working rules for the session/VCS layers

Three rules, each written after the failure that produced it. They are narrow on purpose: they
apply to the terminal-session and VCS-routing code above, which is concurrent, cross-process and
cross-language, and where a fix that is locally correct is routinely globally wrong.

**1. Verify the premise before writing the justification.** A load-bearing claim about code you did
not write — "the daemon fails loudly here", "this constant bounds that loop", "nothing else matches
on this enum" — gets read and quoted before anything is built on it. If you cannot point at the
line, you do not know it.

Both of these shipped, each under several paragraphs of confident reasoning, each one grep from
being disproved:

- *"Guessing the daemon fails loudly, so an unanswered ownership probe should resolve there."*
  `SessionDaemon.handleAttach` ends in `create(request:connection:)` for an id it does not hold —
  it creates on attach exactly as the agent does. Both guesses silently fork a second shell. The
  rule was wrong and a test asserted it, which kept it wrong.
- *"`WRITE_TIMEOUT` bounds the repaint."* It is a **no-progress** bound, reset per `write` call
  (`transport.rs`). Reused as a total-transfer budget it became a throughput floor, so a healthy
  peer on a slow link was permanently unattachable.
- *"`CLIVCSWriter` is untouched, so agent-routed and native writes classify identically by
  construction."* Both halves of the premise were true and the conclusion was false. The classifier
  really was untouched; it reached opposite verdicts because the two paths fed it different INPUT —
  a stale child environment, a different exit code for a missing tool, and transport failures
  reported as "the command never ran". One classifier fed divergent input is harder to catch than
  two classifiers, because nothing looks out of sync. Generalised: when a claim is "X is unchanged,
  therefore behaviour is unchanged", the thing to verify is everything that reaches X.

The standard is the one worth applying to a reviewer's finding: quote the line, or drop the
confidence. It applies to your own premises first.

**2. Ask what the fix made worse, not only whether it works.** Every fix here gets a negative
control for the bug it targets. That is necessary and it is not sufficient — the bug it *creates*
is usually in the property next door, and nothing in the diff points at it.

Three rounds of this on one branch (#188): chunking a repaint fixed a panic and turned one write
timeout into N; bounding that with a `break` left the client's parser stranded mid-escape-sequence;
the bound itself became the throughput floor above. Each fix was correct about its target.

The same shape again on #205's review fixes, three times in two rounds: replacing an env allowlist
with `env_clear()` + the app's own environment fixed a stale-identity bug and silently dropped the
`GIT_DIR`/`GIT_WORK_TREE` scrub, so a commit requested in one repository landed in another and
reported success; putting a cancellation shield in the command runner protected the jj flock and
stranded connection slots on every superseded read; gating the resulting SIGKILL on `timed_out`
stopped it firing after normal exits and opened a path where it never fired at all. Each fix was
correct about its target. Each was caught by a reviewer that had not written it.

So: name the neighbouring property before pushing (the lock hold, the client's parser state, what a
caller now does with an error it never saw before), and test it.

**3. An independent adversarial pass is required here, not optional.** For any change to
`Core/Session/`, `VCSProviding`/`VCSWriting` routing, or `vcs/crates/wr-agent`, dispatch a reviewer
that did not write the code and give it the diff, the intent, and an evidence gate. Every defect
listed above was found that way; none was found by re-reading.

Being more careful is not a substitute, and on this branch it demonstrably was not one.

## Formatting & linting

Swift is formatted/linted with **swift-format** (bundled with the Xcode toolchain — run via
`xcrun swift-format`, no install). Config `macapp/.swift-format` (2-space, 100 cols) covers
`WorkroomApp/` + `WorkroomAppTests/` only (not the `Scripts/*.swift` tools). Use `make app-format`
/ `make app-lint`. Every Xcode/`xcodebuild` build also runs a `swift-format lint` pre-build phase
that surfaces violations as **warnings** (non-fatal — `make app-lint` is the hard gate). Run
`make app-format` before committing.

## Gotchas

- **The Swift module is `Workroom`** (the target is `WorkroomApp`; `PRODUCT_MODULE_NAME` is pinned
  to `Workroom` in `project.yml`). Tests use `@testable import Workroom`. The pin matters because
  `PRODUCT_NAME` is **per-config**: `Workroom` for Release, `Workroom Dev` for Debug (see below) —
  without the pin the Debug module would become `Workroom_Dev` and break the import. A test
  target's `TEST_HOST` must point at the Debug product (`Workroom Dev.app/Contents/MacOS/Workroom
  Dev`); XcodeGen's auto-derived (target-name-based) host is wrong and fails with "Could not find
  test host".
- **Debug builds run side by side with the release build.** The Debug config has a distinct
  identity — bundle id `com.developwithstyle.workroom.dev`, product/display name `Workroom Dev`,
  and the orange-badged `AppIcon-Dev` icon set — so a local build doesn't fight the installed release
  `Workroom` for activation, the key window, preferences (separate UserDefaults domain via the
  bundle id), or the system-wide ⌘§ hotkey. The Debug build deliberately **doesn't register ⌘§**
  and **doesn't run Sparkle scheduled checks** (`#if DEBUG` in `WorkroomApp.swift` / `Updater.swift`)
  so it can't grab the global hotkey or try to "update" itself to the release DMG. Both builds
  still share the CLI config at `~/.config/workroom/config.json` (the bundled CLI has no
  config-path override), so they show the same projects/workrooms. `make app-run` only kills the
  `Workroom Dev` instance, never your release build. The three app icons (`make app-icon` renders
  all of them) share the yellow blocked mark; Dev and Nightly overlay their channel labels.
- **Every `Defaults.Key` must declare `suite: .app`.** `Defaults.Key` captures its suite at
  DECLARATION and falls back to `UserDefaults.standard`, and `WorkroomAppTests` is *app-hosted*
  (`TEST_HOST` is `Workroom Dev.app`) — so one key declared without the suite makes `make app-test`
  rewrite the developer's own theme, release channel, inspector layout and run commands.
  `Core/DefaultsSuite.swift` defines `UserDefaults.app`: the real domain normally, a throwaway
  `com.developwithstyle.workroom.tests*` suite under XCTest or an XCUITest launch (per-pid and
  wiped for hosted unit runs, since `make app-test` shards across parallel workers; one stable
  name, never wiped, for XCUITest so a quit-and-relaunch test still sees what it left). The whole
  redirect is `#if DEBUG` — a shipped build must never redirect preferences. `UITestFixture` keeps
  reading `.standard` on purpose: launch *arguments* live in a different domain from preferences.
  `DefaultsIsolationTests.testEveryShippedKeyDeclaresTheAppSuite` parses `DefaultsKeys.swift` and
  fails on a key that forgets it, so the rule is enforced, not just documented.
- **Adding/removing/renaming a `.swift` file needs an `xcodegen generate`.** XcodeGen
  expands the source glob into explicit file refs in the (gitignored) `.xcodeproj`, so
  the change is invisible (or, for a deleted/renamed file, a hard "Build input file
  cannot be found" error) until the project is regenerated. The `make app-*` build
  targets now run `xcodegen generate` every time, so this is handled automatically —
  it only bites when building from Xcode directly (regenerate, or run `make app-generate`).
- **SourceKit "Cannot find type X in scope" is usually noise.** The single-file indexer
  doesn't see sibling files; a clean `xcodebuild` is authoritative.
- **The app binary is also the `ghostty` CLI, and the entry point is `main.swift`, not `@main`.**
  `Contents/MacOS/ghostty` is a **relative** symlink to the app binary (a `postCompileScripts` phase
  in `project.yml`, before the final code-sign so the link is sealed into the signature).
  `WorkroomApp/main.swift` branches on `argv[0]`: invoked as `ghostty` it runs libghostty's
  `+action` dispatcher (`ghostty_init` **then** `ghostty_cli_try_action` — the first only *stores*
  the action, so calling it alone runs nothing) and exits; otherwise it calls `WorkroomApp.main()`
  and the GUI path is byte-for-byte what it was. That branch is why `ghostty_init` was NOT hoisted
  out of `GhosttyApp`: the engine captures the environment at init, and `WorkroomApp.init()`'s one
  `setenv("PATH", …)` has to land first or every terminal inherits the un-enriched Finder PATH.
  Ghostty's bundled shell integration needs this to reach `"$GHOSTTY_BIN_DIR/ghostty" +ssh-cache`
  (the engine sets `GHOSTTY_BIN_DIR` itself, to the running executable's directory). Side effect:
  `ghostty` is on every pane's `PATH` and shadows a real Ghostty.app in there, so a bare `ghostty`
  prints a message naming Workroom and exits 1 instead of launching a second app. `release.sh`
  asserts the link exists, is relative, and can actually dispatch `+ssh-cache` on the shipped
  artifact; `GhosttyCLITests` covers the rest. See `Resources/ghostty/SOURCE.md`.
- **The terminal is libghostty** (`libghostty-spm`'s `GhosttyKit` xcframework). The embedding C API
  is not yet stable, so the pin is EXACT — don't float it. **`project.yml` is the single source of
  truth for which package version and which ghostty engine we ship** — read the comment there rather
  than trusting a version quoted anywhere else, and note the trap it documents: the package versions
  itself independently of ghostty, so package `1.3.1` is not ghostty `v1.3.1`. Bumping it is not a
  one-line change (see "Bump the libghostty pin" in `TODOS.md`). The terminal surface
  (`Core/GhosttySurfaceView.swift`) + runtime (`GhosttyApp`/`GhosttyRuntimeAdapter`) are ours; the
  bundled `Resources/ghostty` (terminfo + shell-integration) must ship for the engine to start.
- **The child environment has two layers, and only one of them is reliable** (`Core/ShellEnvironment.swift`).
  A Finder-launched `.app` gets a minimal PATH, so: the **floor** (`floorPath()`) reads `/etc/paths`
  + `/etc/paths.d/*` — `path_helper`'s own inputs — with no shell at all, and that alone resolves
  Postgres.app's `psql`; the **probe** (`refresh()`) then runs one `$SHELL -ilc` for what only an
  interactive login shell knows (`.zshrc` PATH entries, mise shims). The probe is best-effort by
  design: its failures degrade to the floor, so a `.zshrc` that ends `exec tmux` costs enrichment
  and never the bug. Three traps worth knowing: **`path_helper` APPENDS** the PATH it's handed, so
  the probe must be spawned with a *cleared* `PATH=/usr/bin:/bin:/usr/sbin:/sbin` or Homebrew ends
  up at the tail; the payload is a **raw `env -0` stream between UUID markers** because command
  substitution strips NULs and the user's `base64` may be GNU's (wraps at 76 cols); and the deadline
  is a `DispatchWorkItem` **inside** the blocking closure, because `withTimeout` cannot cancel a
  `runBlocking` call and would leak a shell per invocation. `setenv("PATH", …)` happens exactly once,
  in `WorkroomApp.init` — a later write would race the status sweep's `ProcessInfo.environment`
  reads. Everything else reads `ShellEnvironment.path()` (PATH only, for the automatic sweep) or
  `.environment()` (the full environment, for setup/teardown scripts).
- **Menu enable/disable must flow through `focusedSceneValue` + `@FocusedValue`**
  (see `WorkroomApp.swift`); a `Commands` body does not re-evaluate when the shared
  `AppStore` mutates. ⌘1–9 are handled by an `NSEvent` local monitor in `AppDelegate`,
  not menu items, so they fire before the terminal swallows the keys.
- **⌥Tab / ⌃Tab (the quick switchers, issue #132) are monitor-only and deliberately NOT in
  `GhosttySurfaceView.isAppShortcut`.** That list is static, but whether the app owns Tab depends on
  runtime state: a workroom with one pane has nothing to switch to, so ⌃Tab must reach the TUI. The
  monitor branch consumes the event only when a switch actually happened, exactly as ⌥⌘digit and
  ⌥⌘arrows already do — same reasoning as the unreserved ⌃⌘arrows. `AppShortcutReservationTests` pins
  Tab as never-reserved so a later "defence in depth" edit can't take `<C-Tab>` from every TUI. Both
  trigger modifiers are `Defaults` keys (`switcher*Modifier`) because a global-hotkey grabber
  (AltTab, HyperSwitch, Contexts all bind ⌥Tab) intercepts upstream of `NSApp.sendEvent`, where no
  local monitor can see the key and no API can detect the conflict.
  The Go menu's **Last-Used Workroom / Last-Used Pane** items carry the same key equivalents purely so
  macOS renders and teaches them (and so the feature is mouse-reachable) — the monitor still owns the
  keystroke, since it runs ahead of menu dispatch and consumes the event whenever it switched. Their
  enablement is therefore load-bearing, not cosmetic: a disabled item drops its key equivalent, which is
  what stops the menu eating a Tab the monitor deliberately passed through. Their action resolves the
  store from the **key window** (`QuickSwitcher.stepFromKeyWindow`), not from the `Commands` body's
  focused store, which outlives an aux window becoming key.

## Layout

**VCS info that only the GUI needs** (e.g. the sidebar root row's current branch/bookmark)
is resolved app-side in `Core/BranchResolver.swift` (per project, async, with a per-call
timeout) — deliberately NOT added to the `workroom --json` contract, which the human CLI
never shows.

`WorkroomApp/Core/` — store, CLI wrapper, terminal sessions, models, theme.
`WorkroomApp/Views/` — `NavigationSplitView` tree sidebar + terminal detail.
`Scripts/` — `run.sh` (local), `build-helper.sh` (embeds+signs the Go binary), `release.sh`
(build → notarize → staple → DMG → EdDSA-sign for Sparkle), `appcast.sh` (publishes the Sparkle
appcast to the fixed `appcast` release), `appcast-notes.sh` (re-renders a published item's
`<description>` from the current release body — see "Auto-update" below), `make-icon.swift`
(regenerates the `AppIcon` PNGs in `Assets.xcassets` — run `swift Scripts/make-icon.swift`).

## Auto-update (Sparkle)

`Core/Updater.swift` wraps Sparkle's `SPUStandardUpdaterController` (the "Check for Updates…"
menu item + the Settings toggle bind to it). The `SU*` keys in `project.yml` (`SUFeedURL`,
`SUPublicEDKey`, `SUEnableAutomaticChecks`) configure it. **Versioning is tag-driven** —
`CFBundleShortVersionString`/`CFBundleVersion` resolve from `$(MARKETING_VERSION)`/
`$(CURRENT_PROJECT_VERSION)`, which `release.sh` injects from the git tag (build number =
commit count, so it only ever increases — Sparkle compares it). The appcast feed is an asset
on the fixed `appcast` GitHub release. See `CONTRIBUTING.md` ("Auto-update") for the one-time keypair
setup and the `SPARKLE_PRIVATE_KEY` secret.

**Release channels (issue #91) — two build identities.** The **main** app (`Release` config)
switches `stable`⟷`pre` at runtime via the *Settings ▸ General ▸ Release channel* picker
(`ReleaseChannel.pickerCases` = stable/pre only). **Workroom Nightly** is a separate side-by-side
product — the `Nightly` build config in `project.yml` (bundle id `…workroom.nightly`, name, labelled
`AppIcon-Nightly`, `WORKROOM_RELEASE_CHANNEL=nightly` → the `WorkroomReleaseChannel` Info.plist
marker read by `ReleaseChannel.current`/`isNightlyBuild`), extending the Debug/"Workroom Dev"
per-config identity pattern to a third identity.

`Updater.allowedChannels(for:)` returns `{nightly}` on the nightly build and the picked stable/pre
floor otherwise; one appcast feed carries all channels (`Scripts/appcast.sh` tags items via the
shared `Scripts/channel-helper.sh`; stable stays untagged = Sparkle default), and Sparkle's
bundle-id check stops either identity installing the other's DMG. Nightly is a single **rolling**
item; appcast idempotency keys on `(channel, build)`. `build-helper.sh` bakes both
`-X main.version=$(MARKETING_VERSION)` and `-X main.channel=$(WORKROOM_RELEASE_CHANNEL)` into the
bundled CLI, and `CommandLineInstaller` symlinks it as `workroom` (main) or `workroom-nightly`
(nightly build) so both coexist in PATH. `Updater.migrateReleaseChannelIfNeeded` opts an upgrading
beta user into `pre` and coerces a legacy `.nightly` selection to `.stable` (main build only).

**Release-notes in the update dialog.** Sparkle's dialog renders the appcast item's
`<description>`. `appcast.sh` (run during the release) embeds the GitHub release body as that
description — but at release time the body is still goreleaser's raw commit list, since the
curated notes are written afterwards. So a second path keeps them in sync: the
`.github/workflows/appcast-notes.yml` workflow fires on every `release: edited` event and runs
`Scripts/appcast-notes.sh`, which re-renders the matching item's `<description>` from the
release's *current* body. Curating a release's notes therefore auto-refreshes what the update
dialog shows; no rebuild needed. To fix an already-published feed by hand, run it directly:
`TAG=vX.Y.Z REPO=owner/repo GH_TOKEN=$(gh auth token) macapp/Scripts/appcast-notes.sh`.
