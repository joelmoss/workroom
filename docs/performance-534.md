# Performance hill climb for #534

## Item 1: sidebar, 2026-10-24

Baseline: `646ef6c8c`, with the counters and fixture introduced in this change. Run
`make app-bench-sidebar BENCH_OUT=/tmp/sidebar.json`. Debug app test host on the same Mac,
300 × 700 window, expanded projects, five local workrooms per project, 500 notifications,
no terminal surfaces or git probes. Paths deliberately do not exist. Initial layout is timed
from assigning the hosting view to the window through synchronous layout. Status updates use
`mergeLocalStatus` on the first root, alternate dirty/clean/dirty, then force layout and display.
The row counts include a subsequent 600 ms run-loop drain; that drain is outside the timing.
The first two tables used the original synchronous harness. The current command uses the
asynchronous harness described below. Times are milliseconds; updates are medians of three,
initial layout is one sample.
These synthetic timings do not reproduce or identify a specific Sentry hang.

| Projects | Baseline initial | Cached counts initial | Baseline status | Cached counts status | Rows per status update |
| --- | ---: | ---: | ---: | ---: | ---: |
| 8 | 293 | 242 | 52.5 | 26.0 | 56 |
| 16 | 382 | 317 | 91.9 | 56.9 | 112 |
| 32 | 816 | 699 | 180.7 | 111.0 | 224 |
| 64 | 1635 | 1432 | 393.2 | 259.5 | 448 |

Results contradict two hypotheses in the issue: scaling is roughly linear over these sizes,
and remote menu entries are evaluated **zero** times during initial layout and status updates.
The boxd/exe.dev availability checks also already return immediately; container choices do the
sysctl, executable and sign-in checks. No menu-laziness change was made.

Rejected experiment: flattening the tree to an array of identifiable row enums with a concrete
View per row still built offscreen rows. At 64 projects it reduced status row evaluations from
448 to 384 but increased median update time to 688 ms. It was removed.

Kept: notification counts are derived together from the bounded history and cached until any
history mutation. Previously every target badge scanned all 500 entries, including six scans
per project rollup, on every status update. Counts remain derived from the history rather than
incrementally maintained. The existing count/dismissal/callback tests and a new warm-cache
mutation test cover weighted entries, requests, eviction, cross-window moves and clear.

The `Sidebar tree` signpost measures tree-value construction, **not** the later SwiftUI List
diff/layout. The benchmark's layout timing and row counters cover that subsequent work.
### Confine VCS observation to the status views

Next baseline is the cached-counts commit, `b4df10c`. Move the VCS dictionary reads out of the
project/root/workroom builders and into the glyph, root accessibility modifier and collapsed
project aggregate. No change to status writes or their freshness clocks.

| Projects | Cached counts status | Status views status | Row rebuilds after split |
| --- | ---: | ---: | ---: |
| 8 | 26.0 | 6.6 | 0 |
| 16 | 56.9 | 18.1 | 0 |
| 32 | 111.0 | 27.3 | 0 |
| 64 | 259.5 | 32.1 | 0 |

In that synchronous measurement, 64 projects used 88% less time than cached counts alone.
The row-invalidation regression test was run before the change: it failed with 224 row rebuilds
at 32 projects, and now checks both dirty and clean updates rebuild no rows. Attempts to verify
root accessibility-label rendering through the hosting fixture were not reliable under parallel
window tests, so that test and its instrumentation were removed. The label expression is unchanged
inside the new modifier, but VoiceOver behavior has not been verified here.

The benchmark was then tightened to yield the main actor for 20 ms between mutation and final
layout/display. Nested RunLoop pumping alone does not run all deferred SwiftUI work. It now
also measures `CLOCK_THREAD_CPUTIME_ID` on the main actor, so the fixed scheduling allowance
does not inflate CPU cost. Both versions were rebuilt and rerun with the same new harness:

| Projects | Cached counts elapsed | Status views elapsed | Cached counts CPU | Status views CPU |
| --- | ---: | ---: | ---: | ---: |
| 8 | 57.9 | 29.0 | 42.9 | 13.3 |
| 16 | 95.6 | 38.5 | 77.8 | 20.7 |
| 32 | 152.1 | 47.5 | 135.2 | 29.4 |
| 64 | 267.8 | 55.8 | 255.1 | 38.0 |

This confirms an 85% reduction in main-thread CPU at 64 projects, including deferred work.
Row rebuilds remain zero at every size. All timings are Debug, three samples per size; these
are local comparisons, not release-build latency promises.

### Row-local hover

The root/project/workroom rows and terminal rows now own their hover state in a small view around
each row. The Add Project button owns its own hover too. Highlights, disclosure, delete/close
buttons and spinner swapping use the same row-local Boolean. The nested List structure is retained;
this does not revive the rejected flattened-array experiment.

The regression drives the binding used by the actual `onHover` handlers, at 32 projects × five
workrooms, without notifications or terminal surfaces. Native mouse-event delivery is outside
this fixture. Main-thread CPU includes the same 20 ms actor-yield/draw window as above:

| Hover state | Row rebuilds per change | Main-thread CPU samples (ms) | Median |
| --- | --- | --- | ---: |
| Shared sidebar state | 224, 224, 224 | 140.1, 109.2, 117.4 | 117.4 |
| Row-local state | 1, 1, 1 | 60.5, 46.5, 52.7 | 52.7 |

The test was run before the change and failed with all 224 rows rebuilding. It now requires its
own row to rebuild and fewer than five rows in total. CPU is 55% lower; native List layout still
contributes materially even with only one row builder running.
The native table also must retain 224 individual rows, drop to 218 when one project collapses,
and return to 224 on expansion. The status benchmark still rebuilds zero rows (64-project
main-thread CPU median 38.7 ms, against 38.0 ms before hover isolation).

Remaining item-1 work: notifications still invalidate the sidebar as a whole. The measurements
do not establish quadratic scaling. The expanded benchmark now also appends three notices to
the full 500-entry history. With row-local hover but notification observation unchanged:

| Projects | Notification CPU median (ms) | Rows rebuilt per append |
| --- | ---: | ---: |
| 8 | 46.8 | 56 |
| 16 | 85.4 | 112 |
| 32 | 150.6 | 224 |
| 64 | 295.5 | 448 |

### Confine notification observation to badge views

Move the existing project rollup, target and terminal counts into `SidebarUnreadDot`; the
sidebar itself no longer subscribes to notification history. Count derivation and cache
invalidation are unchanged. A regression run before this split failed with 224 row rebuilds
after one notice; the notice is also required to be present in the history, so a dropped input
cannot produce a false pass.

| Projects | Notification CPU before (ms) | Notification CPU after (ms) | Rows rebuilt after |
| --- | ---: | ---: | ---: |
| 8 | 46.8 | 20.0 | 0 |
| 16 | 85.4 | 24.1 | 0 |
| 32 | 150.6 | 34.1 | 0 |
| 64 | 295.5 | 44.6 | 0 |

At 64 projects this is 85% less main-thread CPU. Status CPU is still 40.0 ms, with zero row
rebuilds. The row-hover regression and native table collapse/expand checks remain in the suite.

Item 1's measured improvements are complete: shared hover, VCS and notification invalidation have
been narrowed; menus were already lazy in the tested paths, and the proposed quadratic scaling
was not reproduced. This does not establish that every reported sidebar hang is fixed. Native
List layout remains material, initial layout still builds every row, terminal-session publishes
still reach the sidebar, and VoiceOver changes were not tested end to end. Further work should
start from a new measured bottleneck. The other numbered items were outside this sidebar work.

## Item 2: main menu rebuilds

`make app-bench-menu BENCH_OUT=/tmp/menu.json` runs an opt-in Debug benchmark on macOS 26+
using a real SwiftUI Window scene and the production `WorkroomCommands`. It holds the GUI lock
exclusively while tracking and automatically dismissing native menus. Normal unit tests retain
their shared GUI lock. The fixture has 32 projects with five workrooms each, one fake terminal
surface, and an inspected root in its own temporary directory; it does not launch VCS probes.

The baseline is `7e2f5b5bb` with the same body counter, signpost and benchmark instrumentation.
Three warmed samples measure main-thread CPU through the deferred UI update, using
`CLOCK_THREAD_CPUTIME_ID`; the 30 ms actor-yield sleep does not count as CPU. Native menu tracking
is outside the timed samples. The baseline fails the zero-rebuild regression assertion; the
candidate passes it.

| Update | CPU before, median (ms) | CPU after, median (ms) | Commands body passes before → after |
| --- | ---: | ---: | --- |
| Idle control | 0.36 | 0.36 | 0 → 0 |
| Unrelated workroom status | 2.46 | 0.76 | 1 → 0 |
| Focused notification flag | 3.90 | 3.68 | 1 → 1 |

Unrelated status updates use 69% less main-thread CPU, an absolute saving of about 1.7 ms per
update in this fixture. All three baseline samples rebuilt the commands once; all three candidate
samples rebuilt them zero times. Genuine focused flag changes still rebuild the commands.

`RoomCommandState` publishes an equatable focused-scene value containing only commit eligibility,
the PR number/URL/draft action, draft-action eligibility and Finder availability. A separate view
modifier derives it so observing the status dictionary does not invalidate the root view body.
The commands no longer read that dictionary; status clocks, line counts and unused PR metadata
cannot change their presentation. The `MainMenu` signpost `Workroom commands` measures commands
body construction, not the complete later native menu layout.

The native regression opens menus to verify dirty/clean commit eligibility, PR navigation,
draft actions, in-flight actions, modal gating and notification navigation. Model regressions also
cover irrelevant status changes and a selected directory disappearing. Reading closed native
menu items is insufficient: AppKit updates their enabled state during menu tracking.

This does not reproduce or establish a fix for the reported two-second WORKROOM-44 hang. These
are warm Debug measurements, not Release, cold LaunchServices or slow-filesystem profiles.
Finder availability retains one synchronous filesystem check in the publisher on the existing
status triggers; editor cache invalidation is unchanged. Splitting every commands group to avoid
the remaining few milliseconds on genuine presentation changes would add substantial complexity
without a demonstrated noticeable gain. Item 2 stops at this measured improvement.

Validation: `make app-build` and `make app-lint` pass; the full `make app-test` run reports
3,490 passed, zero failed and 83 skipped. The opt-in native menu benchmark passes separately
(it is one of the normal suite's skips). All 17 existing GUI-lock tests pass.

## Item 3: editor icon decoding

The former `ExternalEditor.icon` cached an NSImage containing an NSCustomImageRep drawing closure.
Panes shared that instance, so repeat draws were already cheap. The important delay was first use,
and CPU timing alone hid most of it: an initial VS Code request took 21.4 ms elapsed but only
0.84 ms of main-thread CPU. First SwiftUI displays took 21.8–52.0 ms elapsed while using 1.5–3.1 ms
of CPU.

`make app-bench-editor-icon BENCH_OUT=/tmp/editor-icon.json` measures the installed VS Code, Zed
and Xcode icons in the Debug app test host. Each sample bypasses Workroom's wrapper cache while
retaining the real NSWorkspace cache. It times the synchronous request, first draw into a 40×40
RGBA context at 2×, and two additional draws of the same icon. It also displays three 18pt SwiftUI
images in an NSHostingView, flushes layout/display and the CA transaction, and forces a bitmap
snapshot. The benchmark holds the GUI lock exclusively and skips in the normal test suite.
The old drawing closure from `549df3866` is retained in the benchmark for comparison.

The order control is `make app-bench-editor-icon PREPARED_FIRST=1 BENCH_OUT=/tmp/icon-control.json`.
It prepares and displays the bitmap before requesting or displaying the deferred icon, in a fresh
test process. First-display elapsed results before the production change were:

| Editor | Deferred icon, displayed second (ms) | Prepared bitmap, displayed first (ms) |
| --- | ---: | ---: |
| Visual Studio Code | 25.83 | 1.12 |
| Zed | 25.01 | 0.68 |
| Xcode | 20.31 | 0.81 |

Repeating the control with the production rasterizer gave deferred/prepared first-display times
of 46.03/1.88 ms for VS Code, 29.41/0.68 ms for Zed, and 23.02/0.73 ms for Xcode. Prepared
three-sample CPU medians were 0.75, 0.71 and 0.89 ms respectively.

Preparing the bitmap first warms both the source and the image-display infrastructure, but the
deferred icon still waits 20–26 ms on first SwiftUI use. This supports removing that deferred path;
the difference is not explained by simply displaying the candidate second. These are observed
first-use samples, not percentile latency promises. Warm three-sample CPU median savings across
runs were only 0.39–0.75 ms for the three images, which would not alone justify the change.

`EditorIconCache` now coalesces requests by application URL and resolves, copies and draws the
Finder icon on a concurrent worker. It sends only an immutable, fully drawn 40×40 CGImage back to
main, where the shared 20pt NSImage is published. `ExternalEditorIcon` confines readiness
observation to a small leaf and reserves the same space for a generic app symbol while loading.
Editor actions remain available throughout. Apple documents that
[icon(forFile:) supports any app thread](https://developer.apple.com/documentation/appkit/nsworkspace/icon(forfile:)).
The `EditorIcon` signpost `Prepare editor icon` covers the worker's lookup and rasterization.

An app launch/quit still refreshes the installed-editor list, but only invalidates the icon at
the changed app's URL. Other apps no longer cause every pane to repeat first-display work.
Invalidating a pending request cancels its publication; a late result cannot overwrite the
replacement. Failed requests stay memoized until invalidation rather than retrying on each render.

The benchmark's prepared arm calls the production rasterizer. Its display timings exclude
background preparation and placeholder/publication overhead; the UI does not wait for preparation.
Regression tests cover shared in-flight requests, ready bitmap dimensions and representation,
cache reuse, and refreshing only the changed app.

This does not reproduce or establish a fix for the reported two-second WORKROOM-42/2N hang.
NSWorkspace's caches are not forcibly purged, memory pressure is not induced, and a full terminal
restore is not measured. Forcing a bitmap snapshot may include work beyond a normal display;
this is not an Instruments attribution of the Sentry stack. The ordinary-use frequency of app
launch/quit cache eviction is unmeasured.

Stop after removing the measured first-use wait from the UI path and retaining ready bitmaps
across unrelated app activity. Warm display CPU is already around a millisecond for three icons;
further work needs a new bottleneck.

Validation: `make app-build`, `make app-lint` and `make docs-check` pass. The final full
`make app-test` run reports 3,493 passed, zero failed and 84 skipped. The prepared-first native
icon benchmark passes separately; it is one of the normal suite's skips.

## Item 4: sound feedback and first backend probe

`make app-bench-feedback BENCH_OUT=/tmp/feedback.json` is opt-in and plays three foreground
chimes and three system bells. It holds the GUI lock exclusively, measures caller CPU and elapsed
time separately, and writes every sample. These are Debug app-host measurements, not release
percentiles or a reproduction of a two-second Sentry hang.

### Sound feedback

At `a29325d14`, the first `NotificationSound.play` took 379.89 ms elapsed and 54.85 ms of
main-thread CPU. The later two calls took 1.54 and 22.04 ms elapsed. The system bell took
2.55, 1.35 and 0.25 ms elapsed. Although [NSSound playback is asynchronous](https://developer.apple.com/documentation/appkit/nssound/play()),
initialization and starting playback still stalled the caller.

The sound player now owns its NSSound on one audio actor. Main-actor admission happens before
task allocation: at most one operation per sound kind can be pending, even if audio setup is
slow. Foreground chimes have a 500 ms cooldown; terminal bells have a separate 250 ms cooldown,
shared across panes. A bell flood cannot consume the chime allowance. Cooldowns use monotonic
time. Denied sound requests never drop the notification's history entry or toast.

| Caller | Elapsed before (ms), three samples | Elapsed after (ms), three samples |
| --- | --- | --- |
| Foreground chime | 379.89, 1.54, 22.04 | 0.203, 0.047, 0.037 |
| Terminal bell | 2.55, 1.35, 0.25 | 0.016, 0.012, 0.030 |

The next main-actor turn ran after 0.35, 0.10 and 0.24 ms in the candidate, while the playback
job completed separately. Thus quick admission does not conceal synchronous setup on the next
UI turn. The cold chime's caller CPU fell from 54.85 to 0.19 ms. Actual sound latency and the
Core Audio thread's CPU are outside these caller timings; no claim is made that playback itself
became faster. Output audibility remains manual QA, as the existing libghostty action tests note.

The burst regression was run against the unbounded dispatch path and failed with 100 admitted
jobs for 100 BEL events, against the required one. The bounded path also covers separate sound
allowances, a backend still pending after the cooldown, and a cooldown after playback returns.
Rare UI-refusal beeps outside terminal output retain their existing direct NSSound calls.

Before startup preparation, the initial session-backend probe's bundled protocol command
measured 71.69 ms cold and 16.09/14.71 ms warm on the main thread; the injected 200 ms backend
fixture blocked its first caller for 201–203 ms.

Sound validation: app-build, app-lint and docs-check pass. The full app suite reports 3,497 passed,
zero failed and 85 skipped; the opt-in feedback benchmark passes separately.

### Initial backend preparation

The store-level regression drives saved-pane restoration through `AppStore.bootstrap` and injects
a delayed health probe. It failed before the change because that probe ran on main. After the
change it runs off main and the first restored pane still receives a persistent session ID.
The test's surface never spawns a shell and its saved session lives in its own temporary file.

`prepareBackend` shares one background initial probe across startup windows. Nonempty project
loads await it before publication; windows reusing the shared project list await it before
reconciling their selection and restoring panes. The project-load generation is checked again
after the await, preserving the rule that publication cannot use a superseded result. Empty
project listings do not start a health probe.

Both a ready result and a failure are cached before startup proceeds. Failure retains the existing
30-second retry cooldown, and the per-session ownership rules and background retry behavior are
unchanged. In particular, a pane does not open early as a nonpersistent shell while a healthy but
slow first probe is still running.

The extended feedback benchmark retains the synchronous getter as a control and separately awaits
preparation, measures the next UI turn, then reads the cached backend:

| Delayed 200 ms fixture | Elapsed samples (ms) |
| --- | --- |
| Unprepared synchronous backend read | 202.08, 202.06, 202.06 |
| Total background preparation await | 210.12, 207.62, 210.06 |
| Next main-actor turn during preparation | 38.58, 0.22, 0.21 |
| Prepared synchronous backend read | 0.010, 0.066, 0.016 |

The necessary health-check wait remains; it no longer occupies the main actor during normal
startup. The first UI-turn sample includes other cold app-host work and is not sub-millisecond.
No timing threshold is imposed on unit tests. The saved-pane test checks the probe's actual
thread, while service tests cover sharing the initial result and caching failure for the cooldown.

Direct synchronous backend readers outside prepared startup retain their first-call fallback.
Legacy per-session ownership queries and other uses of the synchronous process runner are outside
this change. These measurements do not reproduce a two-second Sentry hang, measure Release launch
to first paint, or establish how often the real helper is slow. Stop item 4 after removing measured
sound setup and the initial startup probe from the main actor; further launch/restore bottlenecks
need their own profile.

Backend-preparation validation: app-build and app-lint pass. The full app suite reports 3,500
passed, zero failed and 85 skipped. The feedback benchmark passes separately. The saved-pane
bootstrap regression was observed failing on main before the fix and passing afterward.

## Item 5 — terminal title layout

`make app-bench-title BENCH_SECONDS=60 BENCH_OUT=/tmp/title.json` opens the real
`WorkroomTerminalsView`, pane tree and tab strip at 1100 × 700, with one inert terminal surface.
It drives the surface's real title handler with four alternating spinner glyphs at 10 Hz, after
a two-second warmup. Both the idle and changing phases use the same 100 ms scheduling loop.
The fixture starts no shell or daemon session and runs with the exclusive GUI lock. Each phase
records process CPU (`getrusage`), main-thread CPU, elapsed time and DEBUG-only view body counts.

A separate ten-second stack sample was taken before changing production code. It showed title
text layout, the pane's `ViewThatFits`/toolbar construction and the tab strip's chip/context-menu
construction on main. The latter two had avoidable invalidation paths: a title reader wrapped
the whole pane toolbar, and chip-width preferences wrote the strip's drag state while idle.

Moving the title reads into text/accessibility leaves and separating current chip measurements
from idle drag state eliminated those body passes. That alone did **not** establish a meaningful
CPU gain: the longer control measured 8.12% of a core and that candidate 7.79%, with essentially
the same title-related cost after subtracting idle. An earlier 20-second comparison suggested
25%; the longer run did not support that claim.

The retained title slot takes the width left by the toolbar and draws the live text in an overlay.
Its size therefore does not depend on the current glyph's intrinsic width. This follows
[SwiftUI's overlay layout contract](https://developer.apple.com/documentation/swiftui/view/overlay(alignment:content:)).
The configured minimum title width still determines when optional controls collapse. Tab chips
keep their natural widths. A drag snapshots the latest measurements on its first movement and
continues receiving new measurements while active; split brackets observe widths live.

| 60-second phase | Control | Stable title slot | Repeat |
| --- | ---: | ---: | ---: |
| Idle process CPU, % of one core | 0.78 | 0.49 | 0.48 |
| Changing-title process CPU, % of one core | 8.12 | 7.14 | 7.27 |
| Changing-title main-thread CPU, ms | 4636 | 4115 | 4190 |
| Pane toolbar body passes, 600 events | 599 | 0 | 0 |
| Unsplit tab strip body passes, 600 events | 299 | 0 | 0 |

The idle-adjusted process cost fell from 7.34% to 6.65–6.79% of a core, about 8–9% in these runs.
These are Debug chrome measurements, not a reproduction of the issue's live-engine 10.5% or
Release CPU estimates. Short runs varied substantially; they are not used as the headline.

The normal regression changes both the glyph and title length, checks zero toolbar/idle-strip
body passes, and compares pixels from the actual pane-title rectangle above the inert surface.
The pixel assertion excludes the separately updating tab chip, so freezing the pane title cannot
pass. The original implementation failed the body-count assertions; the candidate passes while
the rendered title changes. No title updates are throttled or discarded.

Stop item 5 at this modest plateau. Remaining title text shaping and chip layout still cost CPU;
reserving 180 points for every chip would sacrifice compactness, and reducing the update rate
would reduce title fidelity. Neither tradeoff is part of this change. The fixture isolates chrome:
it does not measure live PTY/rendering cost, hidden panes, Release behavior or VoiceOver end to end.

Validation: app-build, strict app-lint and docs-check pass. All five focused native UI tests pass:
long-title width, narrow-toolbar collapse, per-pane actions, dragging a tab into a split and split
brackets around unequal-width chip groups. Both final opt-in benchmark runs pass, including the
rendered-title regression. The full app suite reports 3,501 passed, zero failed and 86 skipped;
the new opt-in timing test is skipped in that normal run, while its rendering regression runs.

## Item 6 — output flood: engine profiling

`make app-bench-output-flood BENCH_SECONDS=60 BENCH_OUT=/tmp/flood.json` opens one real
`GhosttySurfaceView` at 1100 × 700 points and 2× backing scale. Its explicitly launched `/bin/sh`
waits on terminal input, then execs `/usr/bin/yes`. No project, saved session, daemon, login-shell
startup file or SwiftUI pane chrome participates. The fixture uses its own temporary directory,
records its child PID, tears down the surface and verifies that the child exits. It holds the GUI
lock exclusively and prevents App Nap during measurement. The benchmark is opt-in; normal tests
never start this flood.

The phases are idle, visible flood, hidden flood (`setVisible(false)`, as for a hidden tab), then
five seconds of recovery after surface teardown. Each active phase defaults to 60 seconds. The
JSON includes app and producer CPU, main-thread CPU, BSD/Mach syscall counts, context switches and
the engine's named thread CPU. A `.phase.json` sidecar provides the current app and producer PIDs
for a separate `sample`/`ps -M`/`top -d` run.

CPU counter units matter on Apple silicon: `proc_pid_rusage` returns Mach ticks, so the harness
applies `mach_timebase_info`; `PROC_PIDTHREADINFO` returns nanoseconds. Every phase cross-checks
the app's converted CPU against independent `getrusage` timeval data. The initial prototype's
unconverted CPU readings were discarded. Counter definitions and conversion are grounded in
[Apple's task accounting implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c).

A first corrected, unprofiled 60-second run on macOS 27.0.1, arm64, measured:

| Measure | Idle | Visible flood | Recovered |
| --- | ---: | ---: | ---: |
| App CPU, % of one core | 0.76 | 145.26 | 0.27 |
| Main-thread CPU, % of one core | 0.28 | 3.07 | 0.19 |
| Producer CPU, % of one core | 0 | 30.18 | exited |
| App BSD syscalls/s | 148 | 343,866 | 73 |
| App context switches/s | 124 | 14,214 | 62 |
| Producer context switches/s | 0 | 36,971 | exited |

This reproduces substantial background-thread cost, not the exact historical two full cores or
54k app-only context switches/s. App plus producer switches were about 51k/s; they must not be
reported as app-only switches. The app's two CPU accounting methods agreed within 0.9 ms over
the flood's 87.16 seconds of CPU time. The app is Debug, but the prebuilt engine reports
`GHOSTTY_BUILD_MODE_RELEASE_FAST` at runtime.

### Profile and source check

A separate ten-second `sample` captured the named `io-reader` and `io-gather` threads. The reader
executes engine frames, including UTF-8 decoding; the gather thread repeatedly enters `read`,
`poll` and kernel waits. Most Zig function names are stripped in the shipped archive, so the
sample does not establish function-level percentages or how many reads returned EAGAIN. During
that run `ps -M` observed two hot background threads near 98% and 41%, versus about 3% on main.
The sampled run's aggregate CPU was lower than the unprofiled run and is not used as a performance
comparison. A sample's inclusive frame counts are not added together as CPU percentages.

The exact pinned upstream
[read pipeline](https://github.com/ghostty-org/ghostty/blob/1e9e14af5df14211892f5fc15fd21a49c7d94868/src/termio/Exec.zig#L1300)
already uses four 64 KiB gather buffers, a 1 KiB saturated-stream threshold, up to 16 immediate
read retries across refill gaps, a 1 ms bridge poll and a 3 ms bridge budget. These are not missing
app-side buffers. Both the clean cached source and the official upstream file at the pin were
checked. The gather code explicitly trades extra reads for saturated-stream throughput.

[Apple's `yes`](https://github.com/apple-oss-distributions/shell_cmds/blob/main/yes/yes.c) builds
an approximately 8 KiB buffer and writes that buffer repeatedly. Thus a claim that this producer
flushes every two-byte line would be wrong. Neither syscall totals nor the sample establish the
actual bytes/s reaching the terminal.

### Named-thread and hidden-surface control

A second unprofiled run confirmed the visible load at 144.97% of a core. These are independent
per-thread CPU deltas from `PROC_PIDTHREADINFO`, not percentages inferred from stack samples:

| % of one core, 60-second phases | Visible flood | Hidden flood |
| --- | ---: | ---: |
| Whole app | 144.97 | 141.92 |
| `io-reader` | 93.81 | 99.06 |
| `io-gather` | 39.14 | 41.77 |
| `renderer` | 7.22 | 0.72 |
| `io` | 0.01 | 0.01 |
| Main thread | 3.04 | 0.25 |
| Producer, separate process | 29.60 | 32.67 |

Visible app BSD syscalls were 331,068/s, versus 322,900/s hidden. App context switches were
13,031/s visible and 8,834/s hidden. Idle app CPU was 0.72%; after teardown it was 0.30%, both
reader threads were gone and the producer had exited. The final benchmark passed its output,
CPU-accounting, named-thread and cleanup assertions.

Occlusion cuts renderer/main work, but does not stop terminal parsing and gathering. Since `yes`
is unbounded and backpressured, the phases do not establish equal bytes/s: the total CPU difference
cannot be sold as an efficiency improvement. The low main-thread cost and the bare-surface repro
also rule out SwiftUI pane/title reconstruction as the dominant cost in this fixture.

### Upstream handoff draft

**Title:** macOS embedded PTY flood: gather thread costs about 40% of a core beside a saturated reader

In a macOS 27.0.1 arm64 C API host, one 1100 × 700-point surface at 2× backing scale running
`/usr/bin/yes` uses 145% of a core in two unprofiled 60-second runs. The engine is the exact
[Workroom pin](../macapp/project.yml), with the package's embedding patches, and reports ReleaseFast.
Named-thread deltas show about 94% reader CPU, 39% gather, 7% renderer and 3% main. With the surface
occluded, app CPU remains about 142% (99% reader, 42% gather). The producer is measured separately.
App BSD syscalls are around 331k/s visible; the gather sample contains repeated `read`/`poll` calls.

Reproduce in Workroom with `make app-bench-output-flood BENCH_SECONDS=60 BENCH_OUT=/tmp/flood.json`.
It gates an owned `yes` child so idle/flood/occluded phases share one surface, then verifies cleanup.
For a separate stack capture, use the app PID in `/tmp/flood.json.phase.json` during `flood` with
`sample <app-pid> 10 1 -file /tmp/flood.sample.txt`; `ps -M -p <app-pid>` provides a CPU cross-check.

The pinned read pipeline already batches into 64 KiB buffers and deliberately spins across refill
gaps. A useful next experiment is a read-retry-budget A/B measuring bytes/s, CPU per byte, small-burst
latency, request/response behavior and shutdown/backpressure. High CPU on an unlimited producer
alone does not establish a regression. This has not been reproduced in stock Ghostty or a different
engine build; the prebuilt archive's stripped Zig frames limit symbol attribution.

This handoff is a local draft, not a published upstream issue. Stop item 6 here: there is no measured
app-side runtime improvement to commit, and changing the engine pipeline needs the upstream
throughput/latency comparison. No bytes are dropped or delayed to lower a CPU counter, and the
embedding/pin architecture in [ADR 0001](adr/0001-raw-ghosttykit-exact-pin.md) is unchanged.

Validation: app-build, strict app-lint and docs-check pass. The full app suite reports 3,501 passed,
zero failed and 87 skipped. The added opt-in flood benchmark is one of those skips; it passes
separately with all four phases, real terminal output, independent CPU-counter agreement, named
engine threads and producer cleanup. Production app behavior and dependency pins are unchanged.

## Item 7 — status-probe subprocesses

### CI result reuse

`make app-bench-status BENCH_OUT=/tmp/status.json` drives the real `AppStore.bootstrap`, focus
reload and selection status paths with one temporary Git project and 20 real worktrees. All 21
branches initially point at the same committed revision. Git commands are real; each `gh` probe
starts a real local shell fixture returning valid CI/PR JSON, without network traffic. The CLI
listing is injected, surfaces are inert and automatic fetch is replaced, so these are counts at
the status-command runner boundary, not a system-wide trace of a production app launch. Fixture
creation is outside the measured window. The first observation window is ten seconds.

| Status subprocesses | Before | After |
| --- | ---: | ---: |
| Launch `git rev-parse` | 21 | 21 |
| Launch CI GraphQL | 21 | 2 |
| Launch `gh auth status` | 1 | 1 |
| Launch repository lookup | 1 | 1 |
| Launch total GitHub subprocesses | 23 | 4 |
| Focus reload at ten seconds | 0 | 0 |
| Per selection: Git subprocesses | 1 | 1 |
| Per selection: GitHub subprocesses | 4 | 3 |

Two candidate runs reproduced those counts with every row resolved and no command failures.
The two cold CI requests are the existing bounded sweep's first two concurrent requests; completed
answers are shared without introducing another task owner. PR lookup, PR details and individual
checks still run on each selection. HEAD is still read on each selection, so a new commit gets a
different cache key immediately. Cold workrooms with distinct commits do not get the shared-commit
launch saving; the fixture's 23→4 is not a promise for every project layout. No network latency or
launch-to-first-paint improvement is inferred from these local subprocess fixtures.

Completed CI facts now live on the shared `ProjectStore`, keyed by GitHub host/owner/repository and
exact commit, with the existing five-minute policy. Separate stores keep separate caches. Entries
expire using a monotonic clock. Manual Refresh bypasses the cache; a superseded in-flight probe
cannot overwrite a forced result. Cancelled and transient answers are not cached, and probe tasks
remain owned by their original callers, preserving cancellation and concurrency bounds.

Cached answers also carry their original check time into the row. A prototype incorrectly stamped
them as newly checked on selection, which would let repeated selections postpone the sweep past
the intended expiry. The store regression was observed failing that timestamp assertion
and now passes. The original path also failed its two-selections/one-CI-query assertion (two queries
were observed). Integration coverage verifies a same-branch new commit and manual Refresh still
query GitHub, while unit coverage checks expiry, repository isolation, window sharing, cancellation,
transient results and late completions after force.

The baseline does not reproduce two complete GitHub sweeps at bootstrap: it publishes two listing
generations but issues one 21-item CI pass. The historical four-Git-process local status description
also no longer applies to native libgit2 status reads; the remaining local subprocess here reads
HEAD for CI. The daemon-routed Git and filesystem-event paths are separate follow-up measurements.

CI-reuse validation: app-build, strict app-lint and docs-check pass; the focused CI/cache/repository
suite reports 36 passed. The full app rerun reports 3,508 passed, zero failed and 88 skipped.
The first full run had one item-5 title toolbar counter failure; a focused repetition run and the
complete rerun passed with title code unchanged. This remains a fixture-timing caveat, not evidence
of a CI-cache rendering regression.

### Daemon status reads

A wire-level regression drives the real `workroomd serve --stdio` VCS service against an owned
temporary Git repository. An environment-scoped Git shim records subprocesses, then executes real
Git. Setup commands are outside the counts. The four successive requests cover tracked edits,
tracked edits after configuring a clean filter, a clean tree and an untracked-only tree.

| Git subprocesses per daemon working-status request | Before | After |
| --- | ---: | ---: |
| Tracked edits | 4 | 4 |
| Tracked edits with a newly configured filter | 4 | 4 |
| Clean tree | 4 | 2 |
| Untracked-only tree | 4 | 2 |

Clean and untracked-only status reads now omit the tracked diff/numstat pass: there are no tracked
rows to receive its counts. That removes both the diff process and its filter-discovery process,
halving Git child counts for those cases. Dirty tracked reads retain their existing counts and
filter protection. These are process-count measurements, not CPU or latency measurements.

A prototype also reused filter discovery across the status and diff commands, reducing tracked
reads to three processes. Mandatory independent review found that branch-conditional config can
activate a different filter if another terminal switches branches during the status command.
The prototype's discovery would then miss that driver before diff. That optimization was dropped.
The retained regression switches between branches at the same commit after status and verifies
fresh discovery still suppresses the newly active driver. The harmless filter sentinel reproduced
the rejected prototype's failure; the final version passes in both daemon configurations. Final
independent review found no further actionable issues.

### File-change batches and stopping point

A separate app regression delivers three ignored-output batches through the real selected-workroom
file-change consumer, then delivers a visible source edit as a positive control. The ignored writes
leave status clean, the visible edit makes it dirty, and neither path invokes the Git/GitHub status
command runner. Local refreshes already use native Git reads. This measures delivered batches;
it does not measure OS notification coalescing, native CPU cost or a production build storm.

The daemon File watch still reports filesystem changes without Git-ignore filtering. Its generic
watch contract and VCS metadata consumers need a VCS-aware design before blanket filtering is
appropriate. Native refresh cost in large repositories remains unmeasured. The baseline also did
not reproduce duplicate complete bootstrap CI sweeps, so both listing passes remain.

Stop item 7 at this plateau: reuse completed CI answers and omit daemon diffs with no consumers.
The remaining exact-HEAD subprocess verifies cache identity after commits. The native current-ref
API returns a branch name or abbreviated detached ID; obtaining an exact commit requires a new
API across the repository boundary. Reading a stale status snapshot would weaken cache correctness,
and the existing native log API does extra traversal/decorating work. There is no measured basis
here for that broader change. Item 8's usage pollers are measured separately below.

Final validation: the complete Rust workspace and the `terminal-state` daemon suites pass, including
the wire-level count/filter regression in both configurations. Rust formatting, clippy and rustdoc
checks pass in both configurations. The SSH-container integration cases remain ignored by these
standard runs. App build, strict Swift lint and docs-check pass. The final full app suite reports
3,509 passed, zero failed and 88 skipped, including the native file-change positive control as a
passing test; the opt-in performance fixtures remain skipped in the standard suite.

## Item 8 — usage polling at startup

`make app-bench-usage BENCH_OUT=/tmp/usage.json` constructs the real usage monitor with temporary
file roots and real subprocess transports. The `cswap list --json` command and Codex app-server
JSON-RPC exchange run against owned local shell scripts, which return valid usage data and record
their PIDs. No provider accounts or network requests participate in these fixture reads. The
benchmark holds the GUI lock exclusively and verifies both results arrive and both children exit.

Three baseline samples each started both processes before creating/displaying the fixture window.
The unchanged startup path failed the zero-pre-display-process assertion with two observed. Monitor
construction itself took only 0.13–0.19 ms elapsed and 0.13–0.18 ms main-thread CPU. This reproduces
early background process work, not a synchronous startup hang. A controlled 250 ms scene-creation
gap makes placement observable; it is not a measurement of production launch duration.

The app now arms automatic usage polling after AppKit completes a window-update pass with a
workroom window visible, followed by a one-second grace period. AppKit's
[`didUpdateNotification`](https://developer.apple.com/documentation/appkit/nsapplication/didupdatenotification)
marks the completed window-update pass; the helper queues its callback afterward. This is a
window-lifecycle boundary, not a physical display/compositor first-paint timestamp. Local bridge
and rollout reads still start immediately. Opening usage details, pressing Refresh or enabling a
usage footer can still poll immediately. A manual read supersedes the pending first automatic
read. The existing three-minute interval, disabled-footer guard and in-flight joining remain.

A draw-only prototype passed the ordinary display benchmark but failed the hidden-layout
regression: a window laid out while hidden could reuse its cached drawing on show and never
release the pollers. The final helper uses the completed update pass plus its own window's
visibility, so hidden layout does not start polling or require an extra repaint when shown.

| Three-sample fixture result | Before | After |
| --- | ---: | ---: |
| Usage subprocesses before window display | 2, 2, 2 | 0, 0, 0 |
| Subprocesses for the completed first poll | 2, 2, 2 | 2, 2, 2 |
| Monitor construction elapsed (ms) | 0.13–0.19 | 0.13–0.35 |

The final benchmark also asserts zero children at the display-submission boundary, after native
layout/display, CA flush and `NSApp.updateWindows()`. Both usage answers arrive 1.16–1.27 seconds
after that boundary in the local-script fixture. This deliberately delays fresh polled readings;
it does not reduce work per poll or establish a CPU/launch-latency improvement. The scripts do not
model full Codex server startup, Keychain work or provider response time. No real Release startup,
restored-terminal launch or compositor first-paint measurement is inferred from these samples.

Stop item 8 after removing those two automatic process launches from the pre-display window.
Keeping a long-lived Codex server, changing the three-minute refresh policy or caching readings
across launches would change resource lifetime or freshness and needs separate evidence. Local
readings, prompt manual refresh and the current usage sources are retained. Item 9's stopped-run
daemon polling is next.

The focused usage/polling/transport suite passes all 25 tests, including hidden-then-shown native
windows, periodic polling, disabled footers, manual reads before/after timer setup, repeated window
callbacks and teardown before the first deadline. App build, strict Swift lint and docs-check pass.
The final full app suite reports 3,511 passed, zero failed and 89 skipped. The opt-in usage
benchmark is skipped in that standard run and passes separately with its three process samples.

## Item 9 — parked-run daemon reader

`make vcs-bench-daemon DAEMON_BENCH_KIND=parked DAEMON_BENCH_SESSIONS=1` now runs the release
daemon with one real run session whose command finishes successfully and leaves its supervisor
parked. It checks the outcome file before measurement. As in the existing shell benchmark, the
daemon and clients use an owned socket directory and are cleaned up afterward. The 60-second
macOS baseline measured 4.5 daemon context switches/second and 0.01 seconds of CPU time.

The run reader formerly used a 250 ms timeout on both platforms. macOS already reports the
supervisor's exit through the PTY, so it now uses the same indefinite readiness wait as ordinary
shells. Linux can keep the PTY open while an escaped descendant holds its slave: it now waits on
both the PTY and the supervisor's pidfd. The kernel's
[`pidfd_open` interface](https://man7.org/linux/man-pages/man2/pidfd_open.2.html) provides exit
readiness without reaping the child. The descriptor closes on exec and an adopted reader opens a
new watch after hand-off. Reaping remains in the existing `TERMINATING` section, preserving the
exit status and hand-off boundary. If a pidfd cannot be opened, Linux retains the original timed
fallback, including checks while a leftover keeps producing output.

An opt-in Linux run-session regression sums voluntary and involuntary context switches across
every `/proc/<daemon>/task/*/status`, rather than incorrectly reading only the main thread. Its
ten-second window follows eight seconds of settling. The old path failed with 49 switches; the
candidate passes with 10. That fixture uses a `/tmp` socket, whose independent fallback check is
once per second, so the remaining roughly one switch/second is expected. This is a Debug Linux
container comparison, separate from the macOS release measurement. The supervisor's own wakeups
are outside these daemon counters and belong to item 10.

Linux validation initially reported three descendant-cleanup failures. A temporary legacy-wait
control reproduced all three; `/proc` identified the leaves as already-exited zombies with parent
PID 1. Adding the required container init/reaper made the unchanged assertions pass. The local
Linux helper now uses `--init` and mounts the shared script-contract testdata read-only. Its first
full run also exposed missing Python in the minimal cached Git image; the complete suite passes
using the cached `node:22` image with Python and Git. Neither fixture problem required a daemon
cleanup change. The temporary control and diagnostic instrumentation were removed.

| Parked-run daemon activity | Before | After |
| --- | ---: | ---: |
| macOS release context switches/second, 60 s | 4.5 | 0.0 |
| macOS release BSD syscalls/second, 60 s | 12.1 | 0.0 |
| Linux Debug context switches/second, 10 s | 4.9 | 1.0 |

Every one of the six final macOS ten-second samples reports zero switches and zero BSD syscalls;
its `ps` CPU time remains 0.03 seconds across the minute, versus 0.03→0.04 in the baseline. CPU was
already effectively zero at this precision, so the established gain is eliminating periodic
wakes, not a meaningful percentage-of-core saving. The Linux result retains its fixture's socket
fallback activity. The opt-in Linux idle test is ignored in ordinary runs and passes separately.

Stop item 9 at this event-driven plateau. A Linux host that cannot open a pidfd still works through
the compatibility fallback. No extra watcher or waiter thread is introduced, and the supervisor's
parked-loop cost is addressed separately in item 10. Independent adversarial review found no
actionable runtime issue. Native focused run-session tests pass in both daemon configurations;
the feature-enabled native run covers hand-off. The full Linux daemon suite passes with default
features and the fixture prerequisites above, including the new early/late exit-watch test and
existing cleanup/restart cases. Linux hand-off cases return early without `terminal-state`, so
this run does not establish Linux feature-enabled hand-off coverage.

Final validation: `make vcs-test` passes the full native workspace and the native daemon with
`terminal-state`; `make vcs-lint` passes rustfmt, clippy and rustdoc in both configurations.
Both changed shell helpers pass shellcheck, and docs-check passes. The standard Linux suite
retains its seven SSH-fixture ignores plus the opt-in idle benchmark; the latter passes separately.

## Item 10 — parked supervisor: timed fallback retained

The initial indefinite-wait optimization was rolled back after review reproduced lost Restart
controls on macOS. The retained parked loop uses a foreground `sleep 0.2`, preserves a delivered
ACTION until the next run, and does not read terminal input. A sleep finishes on its own, so a
control deferred across entry into a shell blocking builtin does not leave the pane parked
indefinitely. This accepts periodic idle work and roughly 200 ms of parked-control delay instead
of retaining the zero-idle-work target. The user explicitly approved this tradeoff.

The initial experiment measured the supervisor child of an owned release daemon with
`make vcs-bench-daemon DAEMON_BENCH_KIND=parked DAEMON_BENCH_SCOPE=supervisor
DAEMON_BENCH_SESSIONS=1`, separately from item 9's daemon:

| Historical experiment, one parked supervisor, 60 seconds | Original timed loop | Indefinite waiter, later reverted |
| --- | ---: | ---: |
| Parent CPU time added (seconds, `ps` centisecond precision) | 0.44 | 0.00 |
| Context switches/second | 26.9 | 0.0 |
| BSD syscalls/second | 179.2 | 0.0 |

Those zero-work results are not a claim about the retained implementation. A fresh direct-script
PTY comparison on the same Mac measured the actual rollback proposal:

| One parked supervisor, 30 seconds per mode | Indefinite waiter | Retained timed loop |
| --- | ---: | ---: |
| Parent CPU time added (seconds, `ps` centisecond precision) | 0.00 | 0.14 |
| Percent of one core | 0.00% | 0.47% |
| Additional sleep launches | 0 | 137 |

These are one observation per mode, not a full-app measurement. Parent CPU excludes short-lived
children's CPU. Context switches are not interchangeable with timer wakeups or process launches.
The retained path gives back item 10's idle improvement; item 9's daemon-reader change remains
separately measured.

The failed check restarted a quick-exiting command as soon as each distinct exited generation
was visible. Repeated unmodified-script fixtures stalled with both supervisor and inert waiter
alive. Minimal trap logging showed that the final request never entered the shell handler. A
stack sample found the shell in `wait4`, with no kernel-pending or masked signal; one extra USR1
advanced the generation. This supports deferred shell trap dispatch across entering the wait,
without identifying the exact internal instruction in Apple's installed Bash build. Production
frequency is unmeasured. Bare `wait`, FIFO/read and alternate-shell experiments were rejected;
bounding only the asynchronous wait also failed a longer stress run.

The strengthened repository regression polls the status every 1 ms for 30 consecutive restarts.
Before the repair it failed at restart 14, retaining generation 13. The timed-loop proposal then
passed 300 restart transitions over 30 fixtures, Quit/wait-process cleanup, control during sleep
startup and PTY hangup. The former zero-additional-sleeps assertion is intentionally replaced by
at most four additional launches in 750 ms; this bounds polling rather than hiding its cost.

The changed script is embedded when a new run supervisor starts. Existing supervisors keep their
script across daemon hand-off and Restart. A stopped tab using an older script must be closed
and reopened before its next command to adopt the repair. The Nightly user docs explain this.

Stop item 10 at the reliable timed behavior. A native event-driven replacement is deferred. The
100 ms active-command shutdown checks retain their existing bounded escalation behavior; the
repair concerns a parked supervisor with no command running.

Repair validation: the strengthened regression failed before the product edit, then all four
parked PTY tests and the real-server lifecycle fixture passed on macOS and Linux (a disposable
Node 22 container with an init reaper). Full native `make vcs-test` passed for the workspace and
terminal-state daemon; `make vcs-lint`, shellcheck and docs-check passed. The Linux checks here
exercise the actual shell script and server fixture, not the feature-enabled daemon hand-off.

## Item 11 — launch stages and watch registration

The opt-in daemon test `watch_registration_does_not_starve_other_requests` creates 16 temporary
Git repositories, queues watches of their real `.git` directories on one connection, then queues
an independent `working_status`. Run it with:

```sh
make vcs-test VCS_TEST_FLAGS='-p workroomd --test file_service watch_registration_does_not_starve_other_requests -- --ignored --nocapture'
```

| Native Debug, macOS 27 | Default daemon | With terminal-state |
| --- | ---: | ---: |
| Last of 16 watch acknowledgements | 246 ms | 198 ms |
| Following working-status response | 285 ms | 227 ms |

Registration remains serial on the connection reader, but the historical 0.7–2.4 seconds per
watch did not reproduce: individual increments were approximately 11–22 ms. These are small,
fresh metadata directories on this Mac; they do not establish a bound for other hosts or large
repositories. Local app VCS reads now use libgit2, so the old claim that these watches queue all
local branch/status reads behind the daemon also no longer describes the current routing.
Retain the opt-in probe and stop here rather than change watch ownership/cancellation without
a measured stall. Its one-second assertion is deliberately excluded from ordinary CI.

`LaunchSignposts` adds Instruments Points of Interest intervals for:
launch to a visible window update, app initialization, application launch callback, window
bootstrap, project list, repository preparation, backend preparation, project publication and
reconciliation, saved terminal restore, terminal engine creation, file-watch registration,
working status and status sweep. Each concurrent interval has a unique identity; static names
record no project paths or commands. Async durations include time suspended, not just CPU time.
The terminal-creation interval covers the actual engine call, while restore covers synchronous
model reconstruction; they are separate work.

The launch boundary begins only on the GUI entry path (never the bundled Ghostty CLI helper)
and ends once for the first normal or onboarding window. It records a completed AppKit update
with a visible window, followed by the existing main-queue callback; it is **not** a physical
compositor first-paint measurement. The existing usage-poll placement uses the same one-shot
observer and retains its one-second initial delay. Instrumentation itself is not a claimed
launch-speed improvement; the intervals provide evidence for the following restore/startup items.

Validation: app generation, formatting, build and lint pass; the full app suite reports 3,511
passed, zero failed and 89 skipped. File-service tests pass in both native configurations (12
passed and the one opt-in measurement skipped in each ordinary run); the measurement passes
separately in both. Rust lint and docs-check pass. Independent adversarial review found no
actionable behavior change in interval lifetimes, the display observer or the probe's ownership.

## Item 12 — restored terminal creation

`make app-bench-restore BENCH_OUT=/tmp/restore.json` restores 1, 8 and 16 targets using the real
model restore, live-session recovery loop and Ghostty engine. Only its children are substituted:
owned inert shell commands replace personal helper attachments, while the model retains the
session identities used by recovery. Every child must exit after teardown. The opt-in fixture
also checks first mount, eagerly recovered agent metadata, and an actual OSC notification from
an off-window terminal. It does not measure daemon attach latency or production launch time.

The initial measurement confirms that model restore is already inert, but live-session recovery
forces every hidden engine and child into existence. Sixteen panes took 118 ms elapsed / 39 ms
main CPU in the first warm measurement, creating all 16 engines before any window mount. With a
5 ms main-loop heartbeat added, the original bulk loop took 99 ms and delayed the heartbeat by
99 ms (43 ms CPU), failing the opt-in 80 ms responsiveness threshold.

Fully lazy creation reduced that work to 0.7 ms and no hidden children, but independent review
found a concrete behavior cost: programs' own OSC desktop notifications arrive only through
their Ghostty engine. This includes Claude's own notifications when synthesized alerts are off,
as well as generic notifying programs and legacy-helper sessions. The retained change therefore
preserves background attachments. Visible panes mount normally; hidden recovery starts after
this window completes a visible update and allows 16 ms for input/display between new engines.
Restore and display may arrive in either order. No task waits for a window that never displays,
and each pacing suspension rechecks the target, tab, session identity and view before creation.
Fresh background Run starts/restarts retain their existing eager behavior.

The new pauses require current ownership at two boundaries: metadata hydration rereads the
current mapped state (not the outer dictionary snapshot), and engine creation rechecks it after
the pause. A regression delivering command-finished callbacks during the first pause failed
before that reread because a later pane revived the finished agent. Moving pending restored
panes schedules their remaining recovery in the destination window; origin recovery skips them.
Fresh moved tabs do not acquire background restore work.

The stale-socket hypothesis is not a meaningful cost on this Mac. An owned Unix listener was
bound and closed, leaving its actual socket inode behind. Five groups of 16 real existence /
legacy ownership checks took 0.19–0.39 ms total per group, all returning the required definitive
`notOwned`. Production socket deletion is not justified by that measurement and is left alone.
An accepting but silent helper is a different condition; its existing timeout/cooldown remains.

The cold first engine remains substantial: 156–631 ms in the separate baseline processes and
183 ms on first mount in the lazy experiment. This work is still required for visible terminals;
neither lazy creation nor pacing eliminates the first engine's setup. The retained improvement
targets the accumulated hidden-pane burst, not total restore CPU, memory or that cold cost.

| Warm 16-pane recovery, Debug | Original bulk loop | Paced final |
| --- | ---: | ---: |
| Largest 5 ms heartbeat gap | 98.7 ms | 7.8 ms |
| Total reconnection elapsed | 98.7 ms | 311.1 ms |
| Main-thread CPU during recovery | 43.4 ms | 48.0 ms |
| Hidden engines / children after recovery | 16 / 16 | 16 / 16 |

The retained change reduces this main-loop interruption by about 92%, while deliberately
spreading the same engine work over more elapsed time. A prior paced sample measured 8.4 ms
maximum gap / 313.4 ms elapsed. Eight panes measured 35.5→8.3 ms maximum gap. These are controlled
Debug measurements, not a production frame-time guarantee or a total CPU reduction. The final
opt-in run passes both tests, including actual hidden notifications and owned-child cleanup;
unique notification text avoids the engine's identical-message suppression.

Stop at this scheduling plateau: removing the background attachments would require a separate
notification-forwarding design, and deleting stale socket names has no measured benefit here.
App generation, formatting, build and lint pass. The full app suite reports 3,513 passed, zero
failed and 91 skipped; both opt-in restore measurements pass separately. Docs-check passes.
Independent adversarial review caught the notification, stale-state and move consequences above;
the retained implementation addresses them, with no further actionable finding in the final pass.

## Item 13 — optional work after window display

The first actual Instruments trace exposed an instrumentation usability issue: the standard
Points of Interest instrument filters the `PointsOfInterest` category. Startup intervals now use
that category, with static stage names and the existing subsystem; no custom template is needed.
Additional intervals separate the PATH floor, updater construction/start, Claude bridge,
session-file read, switcher preparation, Markdown prewarm and Release-only Sentry start.

Both baseline traces launch this checkout's empty-project Debug UI fixture, with isolated
preferences, no personal sessions, no provider commands and no login-shell dotfiles. The GUI
lock is held exclusively. Instruments resolves same-named workroom app bundles ambiguously, so
an exact `/bin/sh -c 'exec "$@"'` wrapper launches the checkout's executable in the same PID.
The profiler ends its owned fixture at its five-second limit (the saved trace reports SIGKILL
and `xctrace` exits 54); the measurement data and end reason are verified before use.

Record with `xcrun xctrace record --template 'Time Profiler' --instrument 'Points of Interest'`,
passing `-WorkroomUITestFixture 1 -WorkroomUITestNoProjects 1 -WorkroomUITestOnboarding hide`
to the exact checkout binary. Export `OSSignpostIntervals` from the completed trace. These are
Debug, instrumented, empty-project launches to a completed visible-window update, not compositor
paint or a Release launch benchmark. The two total launch intervals varied 877–1,845 ms, so
unmatched cold/warm totals must not be presented as an overall app speedup.

| Baseline stage | First trace | Repeat trace |
| --- | ---: | ---: |
| App initialization body | 16.7 ms | 15.5 ms |
| PATH floor | 4.2 ms | 3.0 ms |
| Updater construction and start | 2.6 ms | 3.3 ms |
| Claude bridge, absent fixture settings | 0.33 ms | 0.19 ms |
| Launch callback | 245.6 ms | 86.1 ms |
| Switcher panel preparation | 3.5 ms | 3.4 ms |
| Markdown prewarm | 218.5 ms | 70.0 ms |

A separate CPU trace attributed about 48 one-millisecond main-thread samples to Markdown
prewarm inside the launch callback. WebKit is the clear optional pre-display cost. The retained
change wires switcher input during launch but prepares its panel after display, then allows
another main-loop turn before warming WebKit. On-demand switcher/preview creation still works.
An early preview boots only its required page; it does not also create an optional pool spare
before the scheduled warmup. A previously warmed pool still refills after a spare is killed.

Sparkle's controller is constructed early, with scheduled checks disabled in Debug as before,
but starts once after a normal or onboarding window displays. Release's initial background
check moves with it; an explicit manual check starts the updater immediately if needed.
Channel migration still precedes the first check. The PATH floor retains its required ordering
before Ghostty/environment consumers. Sentry remains early in Release for crash coverage;
it is disabled in Debug, so these traces say nothing about its Release runtime cost.

| After stage | First trace | Repeat trace |
| --- | ---: | ---: |
| Launch callback | 10.5 ms | 10.4 ms |
| Updater start, after display | 0.48 ms | 0.48 ms |
| Switcher start relative to display completion | +20.7 ms | +20.3 ms |
| Markdown prewarm start relative to display completion | +43.1 ms | +44.8 ms |
| Markdown prewarm duration, now after display | 105.8 ms | 72.0 ms |

The callback's measured blocking time is 88–96% lower. Optional work still happens; this is a
placement improvement, not a reduction in total WebKit CPU or memory. The observed after launch
intervals were 705 and 752 ms, subject to the cold/warm caveat above.

`make app-bench-startup-reads` exercises real Swift reads against owned files. Ten reads of an
enabled Claude bridge with 65,775 bytes of settings took 0.31–0.54 ms each, including its metadata
read and wrapper check. A 28,889-byte saved session with 64 panes took 0.57–0.89 ms including read,
decode and sanitization. The files were just written, so this is a warm-filesystem measurement,
not a bound for a cold disk, network home or arbitrarily large user file. The absent/disabled
session read in the UI trace is not substituted for this decode measurement. Leave these small
stages synchronous at this plateau; deferring them would introduce more restoration/state timing
for no noticeable measured benefit.

Validation: app generation, formatting, build and strict lint pass. The full app suite reports
3,515 passed, zero failed and 92 skipped; the owned startup-read benchmark passes separately.
Coverage includes the real updater becoming available after deferred start, early preview
fallback, loaded/in-flight pool pages and refill after a spare's simulated termination.
Docs-check passes. Both after traces confirm update start and warmups occur after the first
visible-window update. Stop at this placement plateau; preserve crash coverage and the small
required synchronous setup rather than expand the change without measured benefit.

## Item 14 — renderer memory and heap snapshot

`make app-bench-memory BENCH_OUT=/tmp/memory.json` owns three real terminal engines, inert
children and one window. It records task physical footprint, `vmmap -summary`, heap allocation
class summaries (`heap -s --noContent`) and the actual layer hierarchy. It hides/unmounts the
same views, shows them again, then tears them down; screen text and child cleanup must survive.
The initial text check used the scrollback-only API on a command with no history. The corrected
fixture reads the screen and passes. No personal helper sessions or program output are attached.

The successful run uses three panes of approximately 1,246×1,509 points at 2× scale on this
display. Those large dimensions matter: buffer size grows with pixel area. These are Debug test
host figures for this geometry, not a claim that every three-pane layout costs the same.

| Same owned process | Physical footprint | Resident IOSurface | Live heap allocation bytes |
| --- | ---: | ---: | ---: |
| Empty fixture window | 54.3 MiB | 0.25 MiB | 31.4 MiB |
| Three visible panes | 383.5 MiB | 259.0 MiB | 49.7 MiB |
| Hidden/unmounted panes | 83.0 MiB | 0.25 MiB | 49.7 MiB |
| Shown again | 385.5 MiB | 259.0 MiB | not captured |
| Engine teardown | 74.0 MiB | 0.25 MiB | 33.8 MiB |

An earlier cold run measured 472.7 MiB visible / 172.1 MiB hidden, with the same 259→0.25 MiB
resident IOSurface behavior. It retained more allocator/cache memory; it is not a before/after
code comparison. In the successful run, `Malloc Small` shows 113.1 MiB virtual / 65.0 MiB resident,
while the **whole** live heap is 49.7 MiB. Reserved, resident, dirty, live allocation and task
footprint counters must not be treated as interchangeable. In particular, a 152 MiB malloc
region total alone does not establish 152 MiB of live app objects.

The snapshot's largest live bucket is 32.6 MiB of untyped C allocations. Named buckets are much
smaller: approximately 1.8 MiB Swift metadata, 1.6 MiB CFStrings and 1 MiB SwiftUI platform-item
storage. Without allocation stack logging, the untyped bucket is not attributed to an app owner;
this is a heap summary, not proof of a leak or a reason to remove live state. After teardown the
live heap is only about 2.4 MiB above baseline. Framework/allocator/driver residency is not all
returned just because a renderer is freed.

The issue's proposed `maximumDrawableCount = 2` is not an applicable app-side knob. The running
layer class is `IOSurfaceLayer`, not `CAMetalLayer`. The clean upstream source matching the pin
in [project.yml](../macapp/project.yml) uses a custom CALayer-backed IOSurface target and a
compile-time `swap_chain_count = 3`; there is no public runtime buffer-count option. Reducing
that count requires an engine build/change and rendering/latency validation, not setting a
different property on the app's layer.

Occlusion reclamation is already implemented in that engine: `setVisible(false)` calls
`releaseGpuResources`, which waits for in-flight frames and frees the swap chain's targets,
atlas copies and cell/shader buffers. The live fixture verifies that resident IOSurface memory
falls by about 259 MiB and comes back on reveal without losing terminal text. Hidden snapshots
still list 86 MiB **virtual** IOSurface as empty, with only 256 KiB resident; that is not 86 MiB
of retained physical buffers.

A further experiment calls the public `malloc_zone_pressure_relief(nil, 0)` off main. It returns
zero bytes reclaimed in 0.03 ms, and footprint changes 383.5→385.4 MiB rather than improving.
Do not add a trimming callback or timer on this evidence. The earlier transient 155 MiB surface
from the issue is not reproduced or explained by this steady-geometry test.

Stop item 14 at this app-side plateau. Keep the repeatable measurement and heap snapshots;
there is no new production memory reduction in this item. Remaining visible buffer savings
need engine work, and the snapshot does not support a worthwhile retained Swift-object fix.

Validation: app generation, formatting, build and strict lint pass. The real memory benchmark
passes its screen-preservation, diagnostic-command and owned-child checks. The full app suite
reports 3,515 passed, zero failed and 93 skipped; the new opt-in benchmark is one ordinary skip.
Docs-check passes. All heap captures contain allocation-class summaries, not object contents.

## Item 15 — bundle slices, update delivery and telemetry boundary

Inspected the current downloaded Nightly, `2.2.0-nightly.2092`, rather than treating the older installed Nightly as current. The public feed's DMG is 43,399,213 bytes (41.39 MiB). It was mounted read-only, its signatures verified, then unmounted. Installed applications were only read/copied into temporary fixtures and were never modified or launched by this audit.

| Current Nightly executable | Complete universal file | arm64 slice | x86_64 slice |
| --- | ---: | ---: | ---: |
| App | 89.41 MiB | 44.04 MiB | 45.35 MiB |
| Bundled CLI | 15.97 MiB | 7.66 MiB | 8.28 MiB |
| workroomd | 10.03 MiB | 4.84 MiB | 5.17 MiB |
| Legacy attach helper | 0.25 MiB | 0.13 MiB | 0.11 MiB |

These four executables contain 58.90 MiB of x86_64 slices, excluding nested frameworks. That is an uncompressed disk measurement, not an equivalent RAM saving or compressed-download estimate. Universal binaries select the appropriate architecture at runtime and preserve native support on both kinds of Mac ([Apple's universal-binary overview](https://developer.apple.com/documentation/apple-silicon/porting-your-macos-apps-to-apple-silicon)). Keep the repository's universal-artifact contract; silently stripping Intel would remove supported functionality. The two Linux daemon architectures serve remote hosts independently of this Mac's architecture.

Both live feeds were downloaded and parsed on 2026-10-25. `appcast-nightly.xml` has one item and `appcast.xml` has 31; neither has a `sparkle:deltas` block or delta enclosure. Nightly's newest item is signed and points to the full 43.4 MB DMG. The current publishing script hand-writes full enclosures and the rolling workflow replaces the Nightly DMG, rather than retaining old application archives for delta generation. This verifies the previously unchecked delivery question.

An offline Sparkle `BinaryDelta` v4 experiment compares the signed installed Nightly `1989` (copied into a temporary fixture) with downloaded `2092`. Both have the same Nightly bundle identity, update public key and Sparkle 2.9.5. The official tools generate and apply the patch; the applied app then passes `codesign --verify --deep --strict`. All 284 file/symlink entries match the downloaded application, including regular-file bytes/permissions and symlink targets.

The full DMG's feed EdDSA signature also verifies over its actual bytes with CryptoKit's Ed25519 verifier and the older installed app's update public key. No private signing key was read or used.

| This real Nightly update pair | Measured |
| --- | ---: |
| Full DMG | 43,399,213 bytes |
| Delta | 10,905,050 bytes |
| Download reduction | 74.9% |
| Delta generation | 40.5 seconds |
| Generation peak footprint | 1.16 GiB |
| Patch application | 1.03 seconds |

This is a verified local prototype, not a published update or a prediction for every version pair. The local delta is unsigned as an update package; its reconstructed application's existing signatures remain valid. Production delta publication needs its own EdDSA signature and an enclosure for each retained source build. Sparkle supports signed deltas with full-download fallback for unsupported or unsuccessful patches, and its generator handles format compatibility ([Sparkle delta documentation](https://sparkle-project.org/documentation/delta-updates/)). Preserve the existing separate Nightly and stable/pre feeds.

Decision (2026-10-25): skip the proposed Nightly rollout of signed deltas and three-build retention. The measured benefit is a 32.5 MB smaller download for this pair; startup, CPU, RAM and installed size do not improve, and faster installation was not established. With the full installer already 43.4 MB, the saving does not justify the added generation, signing, publication and archive-retention machinery. Keep the offline proof as evidence and stop this item at that plateau. Nightly CI, architecture support and the existing full-download update pipeline remain unchanged.

Sentry's Release settings are still tracing 1.0 and profiling-session sampling 1.0 with `.trace` lifecycle. The SDK's documented source describes that lifecycle as profiling while root spans are active and stopping when none remain. Its workload duty cycle matters to daily CPU cost. Debug deliberately never starts Sentry, so the Debug measurements in this report cannot establish its Release startup, app-hang-capture or day-long runtime overhead. Item 13 added the Release startup interval for that next measurement. No representative day-long Release A/B was run, and no telemetry policy or crash coverage was changed on an unmeasured assumption.

Validation: parsed the current feeds, verified both signed input bundles and the reconstructed bundle, compared the complete file/symlink manifests, and recorded create/apply resource counters. The read-only disk image was detached. This item adds no runtime change; its measurable result is the offline delta proof and the concrete release-pipeline decision above.

### Item 15 continued — controlled Sentry SDK cost

`make app-bench-sentry BENCH_OUT=/tmp/workroom-sentry-new-run` builds an isolated macOS helper
with Swift 6, `-O`, no `DEBUG`, the app's actual Sentry options and the exact resolved Sentry
9.25.0 static framework. `SentryConfig.configure` is extracted without changing those options;
the app still gates startup out of Debug. The helper's only channel shim is the non-Nightly
environment default. It has its own bundle identity, verifies its temporary home, uses owned
caches and sends telemetry only to a localhost HTTP collector. No personal project, terminal,
session, daemon or installed application participates.

Three fresh-process arms compare SDK off, tracing/crash/hang reporting with profile sampling zero,
and the current full tracing/profile sampling. Short repeated comparisons include idle, 10 Hz
AppKit label updates without a root span, identical updates under an explicit root span, and the
post-trace tail. A separate long full-profile control waits through an entire chunk and measures
idle after it expires. The helper's window is hidden during cost phases so all arms have the same
inactive state; this does not measure visible-window rendering cost. The harness prevents App Nap,
uses absolute phase deadlines and holds the GUI lock exclusively. LaunchServices starts the helper
and restores foreground state separately for the hang check. Initial runs overlapping a build,
exhibiting idle timer coalescing, or lacking controlled activation were discarded. Early fatal
state assertions caused three helper crash reports; they were replaced with normal error exits,
verified headlessly. Build/test work finishes before the final measurements.

The evidence gate checks SDK enablement, profiler-start notifications, real transactions and hang
events received locally, and usable samples in received profile chunks. Each process deliberately
blocks its main thread for three seconds after the steady-state phases to verify hang detection
without a debugger. This is a fixture hang, not an induced hang in a user's app. CPU comes from
`getrusage`; physical footprint comes from `proc_pid_rusage`. Source/framework hashes and the
compile command accompany the raw reports.

The source audit changes the premise behind the original 1.0-sampling concern. Workroom's app
sources contain no explicit root-span creation, profiler start or `SentryTracedView`. In the exact
resolved SDK revision `d27a0ddf0cd1bc90ab038f5781fddc39b894430e`, automatic
[app-launch tracking](https://github.com/getsentry/sentry-cocoa/blob/d27a0ddf0cd1bc90ab038f5781fddc39b894430e/Sources/Swift/Integrations/AppStartTracking/SentryAppStartTrackingIntegration.swift)
and
[view-controller tracking](https://github.com/getsentry/sentry-cocoa/blob/d27a0ddf0cd1bc90ab038f5781fddc39b894430e/Sources/Swift/Integrations/Performance/SentryPerformanceTrackingIntegration.swift)
exclude macOS. Its
[network tracker](https://github.com/getsentry/sentry-cocoa/blob/d27a0ddf0cd1bc90ab038f5781fddc39b894430e/Sources/Swift/Networking/SentryNetworkTracker.swift)
adds child spans to a root already in scope, rather than creating a root for every request.
Full sampling alone therefore does not establish continuous profiling during Workroom use.

These are optimized SDK measurements, not a Release build of the entire Workroom application.
The small helper has fewer threads and a different allocation/layout workload. All arms link the
same framework, so startup differences exclude binary-loading cost from removing Sentry.
Initialization timing covers synchronous SDK startup, not first paint. Hang-and-recovery CPU
includes recovery and local sending, not an isolated stack walk or Sentry server processing.
Neither the forced-root-span duty cycle nor localhost transport represents a day of actual use.

Three observations per arm use five-second idle/UI phases and a two-second immediate tail, with
50 label updates in each UI phase. Two rotations completed in `/tmp/workroom-sentry-controlled`;
its next launch was rejected cleanly for initial focus. The final rotation completed in
`/tmp/workroom-sentry-complete` after removing that unnecessary pre-phase foreground requirement.
All cost phases retained the same inactive-state gate, timing, label updates and counter reads.
Foreground was still restored and checked for each actual hang capture.

| Optimized SDK probe, median of three | SDK off | Tracing/crash/hangs, profiling off | Current full sampling |
| --- | ---: | ---: | ---: |
| SDK initialization wall time | 0.05 ms harness overhead | 75.0 ms | 88.0 ms |
| SDK initialization CPU time | 0.05 ms harness overhead | 48.2 ms | 52.9 ms |
| Idle before a root span, % of one core | 0.26% | 0.29% | 0.28% |
| Label updates without a root span, % of one core | 2.04% | 1.98% | 1.95% |
| Label updates under a forced root span, % of one core | 2.14% same updates, no SDK span | 1.95% | 4.70% |
| Immediate two-second post-trace tail, % of one core | 0.29% | 1.01% | 3.96% |
| Physical footprint after five seconds under the root span | 20.86 MiB | 21.95 MiB | 22.33 MiB |

The profiler adds 1.86–3.09 percentage points of a core in the three paired active-root comparisons
(median 2.75 points). It never starts during the untraced idle/UI controls. The immediate tail
includes transaction serialization/local sending as well as any continuing profiler; it is not a
long-term idle rate. Initializer wall-time ranges overlap (54.8–88.7 ms profiling off,
74.9–148.2 ms full); CPU ranges also overlap. Disabling profiling alone does not establish a
repeatable startup saving here. The five-second footprint difference is small and is not a peak
memory measurement. SDK off is a measurement control, not a proposed loss of crash coverage.

All six monitored short runs received their real transaction and one fixture hang event locally.
Only full-sampling runs reported profiler starts. These runs establish the conditional profiler
cost and functioning hang coverage with profiling off; they do not establish that changing
Workroom's current sampling rates improves ordinary use.

The separate long control in `/tmp/workroom-sentry-complete/chunk-control` received a real
`profile_chunk` with 50,415 samples and 3,692,537 uncompressed payload bytes, with no collector
errors. After the five-second root ended, the 57-second chunk-tail phase averaged 2.51% of one
core; the following eight-second phase fell to 0.26%, near the idle control. Thus the short trace
does pay a longer profiling tail, but profiling does not continue indefinitely in this fixture.

That long control's physical-footprint snapshots were 22.50 MiB after the active trace, 49.61 MiB
at the end of the chunk tail, 45.56 MiB after the quiet post-chunk phase, and 23.72 MiB after
foreground hang capture/recovery. The growth coincided with profile serialization/delivery;
allocation stacks were not collected, so this is not exact attribution or a leak finding. It also
shows why the short-run footprint row must not be presented as peak profiling memory.

Stop at this measurement plateau: keep the existing tracing, profiling, crash and hang options.
Profiling has a real conditional CPU/memory cost, but no current Workroom root-span source was
found, and the untraced controls never start it. A lower sampling rate has no demonstrated ordinary
use benefit here. This does not establish zero SDK overhead: synchronous initialization remains
measurable, and the entire application's Release startup/day-long/hang-capture cost remains
unmeasured. No production policy or coverage was reduced to improve a probe's counter.

Validation: app-build, strict app-lint and docs-check pass. The full app suite reports 3,515 passed,
zero failed and 93 skipped; an isolated onboarding startup UI test passes, as do all three terminal,
split and multi-window session-restore UI tests. The repaired helper's invalid-input path exits
normally with status 2, rather than generating a crash report. Three observations per arm and the
long chunk control pass their counter/state/telemetry gates. No additional native crash reports
appeared during the repaired comparisons or these UI tests. All owned helper processes exited and
the GUI lock was released. Nothing was sent to production Sentry or pushed.
