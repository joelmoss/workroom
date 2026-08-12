# libghostty 1.2.3 → 1.3.2 bump — QA results

## Baseline (pre-bump)

- Date: 2026-08-12
- Doc-hygiene commit: `2e37b446`
- Package.resolved pin at baseline time: `libghostty-spm` revision `df168f41e5a22b319c184e40f021895746ad4e8f`, version `1.2.3`
- OS: macOS 26.5.2 (build 25F84)
- Arch: arm64
- Machine: MacBookPro (Joel's dev machine)
- Build: local Debug ("Workroom Dev"), `make app-build`, not the installed Nightly
- Launch: direct binary exec (`Contents/MacOS/Workroom Dev -WorkroomUITestFixture 1`), `HOME` overridden to an isolated scratch dir
- **Isolation caveat**: the isolated `$HOME` covers `~/.config/workroom`, but NOT `Defaults`/`UserDefaults`
  (cfprefsd resolves the real home regardless of `$HOME`) — theme/channel/inspector prefs are the
  developer's real ones, not a clean slate. Not relevant to the IO-layer/process checks below, which
  don't touch those prefs.
- Driving method: System Events (AppleScript) targeted by PID (captured at launch, verified frontmost
  by unix id before each destructive action — never by app name/frontmost-assumption), plus direct
  `ps`/`vmmap`/`leaks` from this session's shell (sandbox disabled for process introspection).

### IO layer (the patch swap)

| Item | Result |
|---|---|
| Surface churn | PASS. 20× ⌘T/⌘W cycles. RSS 118304 KB → 171200 KB (+52896 KB). No crash, no beachball, window intact. |
| Split churn | PASS. 10× ⌘D/⌘W (closing the focused split pane each time). RSS → 174128 KB. Exactly one surviving `AXTextArea`, non-blank, full-size after the loop — matches "survivor stays mounted, never blank." |
| Workroom switch | **NOT RUN.** Could not drive reliably: neither `AXPress` nor a raw `click at {x,y}` on the `workroom.tab.*` chip (confirmed correct on-screen bounds) changed the window title or mounted a different surface — 0 observable effect despite the action reporting success. Also tried the app's own ⇧⌥⌘←/→ shortcut: on this machine that combo is intercepted by a system-wide Spaces binding (window got moved to another Space, frontmost reverted to another app — recovered via `open -a` reactivation, no data lost, but confirms real Space-switch collision on this machine, not a libghostty behavior). Consistent with this codebase's documented class of real-mouse-only SwiftUI controls (`[[macapp-textselection-swallows-taps]]`, `[[macapp-xcuitest-gotchas]]`) — synthetic input reaches keyboard shortcuts and raw text entry fine, but not this custom tap-gesture control, in this session. Needs either a real mouse or an XCUITest driven from an actual test host process. |
| Workroom delete | **NOT RUN** — blocked on the same switching mechanism above; also tried `AXShowMenu` on the sidebar workroom row for a delete context-menu path, no menu appeared. |
| Orphan check (normal quit) | PASS. Marker-tagged shell (`exec -a qa_orphan_marker_79022 zsh`, running `vim`) + a second marker-tagged shell running `top`, both confirmed alive, then ⌘Q. Clean exit (no hang, no crash report in `~/Library/Logs/DiagnosticReports`), `ps -ax` for either marker afterward: no match. |
| Orphan check (force-quit) | PASS. Same marker approach, `kill -9` on the app PID instead of ⌘Q. `ps -ax` for the marker afterward: no match. |
| Run tab | PASS. `-WorkroomUITestRunCommand "python3 -m http.server 8123"`. ⌘R → `lsof -i :8123` shows the bound Python process. ⇧⌘R (stop) → port released, process gone. ⌘R again → new process, port re-bound, no "already running" state observed. (Note: clicking the `runCommand.run` button via `AXPress` had no effect, same class of issue as the workroom-tab chips — used the ⌘R/⇧⌘R keyboard shortcuts instead, which worked reliably.) |
| Quit with a live TUI | PASS (folded into the normal-quit orphan check above — `vim` + `top` both live, ⌘Q, clean exit, no `EXC_BAD_ACCESS`, no crash report). |
| Scrollback-click race | PASS (best-effort). `yes` piped into the pane, 8× synthetic clicks inside the surface bounds while output was flooding, then Ctrl-C. App stayed alive and responsive throughout; RSS 158800 → 182496 KB. Note: this proves no crash under synthetic clicks during flood output, not a byte-for-byte reproduction of the exact `mouseButtonCallback` race a real mouse click mid-scroll would hit — synthetic `click at` events land as real `NSEvent`s but may not reproduce the exact timing window a physical click does. |
| `free_text` leak spot-check | **CONFIRMED LEAK on this pin** — the exact bug this check exists to catch. Isolated measurement: fresh launch, `leaks <pid>` baseline = `0 leaks for 0 total leaked bytes`. Then 300 accessibility-value reads of the terminal surface in a tight loop (`value of <AXTextArea>` via System Events), no other interaction. `leaks <pid>` after: `299 leaks for 38272 total leaked bytes` (~128 bytes each). Sampled leak contents are literally the surface's text content ("...ast login: Wed Aug 12...") — unambiguous confirmation these are unfreed buffers, not noise. **Exact call path verified in source** (not assumed): `GhosttySurfaceView.accessibilityValue()` (line 1080) → `readText(tag:)` (line 845) → `ghostty_surface_read_text` + `defer { ghostty_surface_free_text(surface, &text) }` (line 855) — the same helper `readCommandRegion` (line 822-835, the inline-agent path) and `readSelectionText` (line 792-798) both call. So "300 accessibility-value reads" is on-target and reproducible: it exercises `ghostty_surface_free_text` via line 855's call site specifically. **This is the baseline number T10 (post-bump retest) must diff against — expect ~0 leaks after the bump if the upstream fix landed as documented.** Reproduction for T10: fresh launch (`-WorkroomUITestFixture 1`), `leaks <pid>` once for a 0 baseline, then 300× read `value of` the surface's `AXTextArea` via System Events (or any caller of `readText`/`readCommandRegion`/`readSelectionText`), then `leaks <pid>` again. |

### Behaviour keyed to engine internals

| Item | Result |
|---|---|
| ⌘F wrap + ordering | PASS (counting-up half only). Seeded 31 matches of `needle_marker_line` (30 in a loop + 1 in the echoed command line itself). Counter read via accessibility text: `0/31` → after 3× Return (Find Next) → `3/31`. Confirms the counter counts **up**, matching the documented current-engine baseline. Did not independently verify on-screen highlight direction ("walks down the screen") — no screenshot taken; the counter behavior is the signal `TerminalSearch.navigationPlan` actually depends on. |
| Backspace | PASS. Typed `abc`, one Backspace → `ab` (single-char delete, not double). Confirms the `0x7f`-as-literal-text workaround (`GhosttySurfaceView.swift:1171`) is still needed at this pin — no change from expected baseline. |
| ⌃Tab | PASS (as expected baseline). Sent ⌃Tab with the terminal focused (single-pane workroom) — no visible effect, no bytes appear to have been forwarded. Matches "the pinned engine sends no bytes for it." |
| Scrollbar overlay | **NOT RUN** — visual-only assertion (overlay tracking without jumping/sticking while scrolling a long buffer); no screenshot or scroll-position accessibility attribute was read this session. Needs an actual visual pass (screenshot diff or eyeball) rather than the text-only accessibility probing used throughout this baseline. |

### Resource contract

| Item | Result |
|---|---|
| `$TERM` / infocmp | PASS. `echo $TERM` → `xterm-ghostty`. `infocmp xterm-ghostty >/dev/null && echo INFOCMP_OK` → `INFOCMP_OK`. |
| OSC 7 | **NOT RUN** — the check requires ⌘-clicking a relative path in terminal output, the same class of synthetic-click limitation as the workroom-tab chips; not attempted after two other click-based interactions failed the same way this session. |
| OSC 133 | **INCONCLUSIVE.** Ran `sleep 3`, read the `terminal.tab.Terminal 1` element's `title`/`description` attributes during and after — both came back empty (`missing value` / generic `"text"`) via this shallow accessibility probe, no busy-state signal visible through it. Not a negative result — just the wrong instrument. The automated complement (`GhosttyActionDispatchUITests.testOSCProgressReportMarksTheTabBusyThenIdle`, run as T11) is the real signal for this; see the plan's "What already exists." |
| ssh integration (real host) | NOT RUN — needs a real remote host, out of scope for this baseline (see `QA-libghostty.md` §N). |
| ssh cache memoisation | NOT RUN — same reason; the manual checklist item specifically calls for a real `ssh <host>` round-trip, which this environment doesn't have. (The CLI-level cache mechanism itself, independent of a real host, is already covered by `GhosttyCLITests.testGhosttyRunsSshCacheActionAndWritesCache`.) |
| Shell matrix (fish/elvish/nushell) | NOT RUN — not installed on this machine (pre-existing, documented in `QA-libghostty.md` §N). |

## Session notes (methodology, for whoever runs Phase 5's retest)

- **This machine has an environment-specific shortcut collision**: ⇧⌥⌘←/→ (Workroom's workroom-tab-cycle shortcut) is intercepted by a system-wide Spaces binding here, moving the window to another Space instead of switching workrooms. Not a libghostty regression signal either direction — a future retest on a different machine may not hit this at all, or may hit it differently. Don't diff on it.
- **Two custom SwiftUI tap-gesture controls (`workroom.tab.*` chips, `runCommand.run` button) did not respond to synthetic `AXPress` or `click at` this session**, despite exposing the right accessibility actions and correct on-screen bounds. Real keyboard shortcuts and raw text `keystroke` input worked reliably throughout (this is how the Run tab and ⌘F/Backspace/⌃Tab checks above were actually driven). Whoever runs Phase 5 with a real mouse, or from inside an actual XCUITest host process, should expect the workroom-switch and OSC-7 items to be drivable where this session's external-AppleScript approach wasn't.
- Twice this session `windows of process` briefly reported `0` for the live target PID (once after the Spaces-collision above, once with no clear trigger) while the process was confirmed alive and not hidden; both times `open -a "<bundle path>"` reactivation immediately restored the window with no state loss. Worth knowing if Phase 5 hits the same transient.
