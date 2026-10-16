# Recently done

Finished `TODOS.md` items, newest first, condensed from the long status notes `TODOS.md` used to
carry; the full write-ups are in git history. Kept for the parts that stay useful: what changed, and
the traps found doing it. Entries are dated history: names in them may since have been renamed or
removed. Add an entry here when you finish a `TODOS.md` item.

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
