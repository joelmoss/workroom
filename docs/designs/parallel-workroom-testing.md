# Design: testing the app from several workrooms at once

Branch: claude/parallel-workroom-tests-31ovb0
Repo: joelmoss/workroom
Status: host-side isolation IMPLEMENTED (below); a VM per UI-test run PROPOSED, not built

## The problem

Developing Workroom in several workrooms at once stalled at the test step. `make app-test` and
`make app-uitest` from two workrooms interfered with each other, so tests effectively ran one
workroom at a time and every other piece of parallel work queued behind them.

Every workroom already builds into its own `macapp/DerivedData`, `vcs/target` and SwiftPM checkout,
so the builds were never the problem. What two checkouts shared was everything keyed by the app's
identity, the Mac's one GUI session, and a handful of fixed paths. This document records what was
found, what changed, and what remains — including the one thing a single Mac cannot give:
two XCUITest runs at the same time.

## What two workrooms shared

Every claim below was read in the code; the symbol is named so it can be checked.

### 1. One app identity for every checkout

`project.yml` gave the Debug build one literal bundle id, `com.developwithstyle.workroom.dev`, so
every checkout produced the same app as far as macOS and the app itself are concerned. Keyed by it:
the session helpers' sockets (`PersistentSessionPaths.preferredSocketPath`,
`Application Support/<bundle id>/sessions/{agent,session}.sock`), the saved session
(`SessionStore.defaultURL`), the `.standard` preferences domain, notifications, and what
LaunchServices and XCUITest consider "that app is already running". The consequences:

- **One `wr-agent` for every dev app.** Agent hand-off is on for Debug (`AgentHandOff.isEnabled`
  returns true under `DEBUG`) and runs on every non-test launch (`applicationDidFinishLaunching`),
  asking the agent on the shared socket to exec *this copy's* `wr-agent`. The agent accepts any
  binary whose digest differs (`handoff.rs`), so two workrooms' dev apps pass the one agent back and
  forth between their builds on each launch, and every pane attached at that moment ends, because
  the exec closes its connections.
- **A UI-test quit ended other apps' sessions.** Fixture mode pins `backgroundSessions` off
  (`UITestFixture.applyFixtureDefaults`), and the SIGTERM handler — the path
  `XCUIApplication.terminate()` takes — then called `PersistentSessionService.endAllSessions()`,
  which sends `killAll()` to every live helper on the bundle id's sockets. A fixture launch never
  creates a persistent session (`TerminalPersistentSessionPolicy.usesPersistentSession` excludes
  it), so everything it killed belonged to a real Workroom Dev.
- **"Already running" meant another workroom's copy.** Apple documents `XCUIApplication.launch()` as
  terminating an already-running instance; `OnboardingUITests` records it re-activating a leftover
  instance instead of starting fresh. Either way the copy at risk is keyed by identity, not by path.
- **`make app-run` killed by name.** `pkill -x "Workroom Dev"` and
  `pkill -f "Workroom Dev.app/Contents/MacOS/wr-agent"` stopped every workroom's dev app, unit-test
  host instances, XCUITest app and session helpers — all are called "Workroom Dev".

### 2. One GUI session

- XCUITest drives the real pointer and keyboard. Every fixture window opens at the same size,
  centred (`AppStore.attachWindow`), so two runs' windows stack exactly and a synthesised click
  lands on whichever is in front; tests wait for `.runningForeground` (74 sites) and `typeText`
  into the focused app.
- A hosted unit run boots the whole app, and its real `WindowGroup` window renders under XCTest
  (the `.task` bootstrap guard in `WorkroomApp.swift` says so), one per parallel-testing worker.

So two UI-test runs cannot overlap, and neither can a UI-test run and a hosted unit run. Unit runs
can overlap each other freely.

**Known window: `make app-run` drops its lock before the app is up.** The launch step holds the lock
across `stop-dev-app.sh` and `open`, and `open` returns once LaunchServices has accepted the request
— not once the app is frontmost. A UI-test run queued behind it can take the exclusive lock while
the dev app is still activating, and the app then takes focus from the test. Deliberately left: the
`-W` flag waits for the app to EXIT rather than to activate, and the only real "is it frontmost yet"
signal is System Events, which costs an automation prompt and a dependency to close a window of a
second or two. It shows up as one flaky UI test immediately after an `app-run`, so it is worth
recognising rather than chasing.

### 3. Fixed names that are not keyed by identity

- The XCUITest preferences suite is one stable name, `com.developwithstyle.workroom.tests`
  (`UserDefaults.app`), never wiped. `runCommands`, `hasCompletedOnboarding`, `vcsLastFetch`,
  `showInspector`, `diffViewMode` and `themeFamily` are last-writer-wins between concurrent runs.
- The fixture tree is `$TMPDIR/workroom-uitest` (`UITestFixture.projects`), per user, not per app.
- `~/Library/Application Support/Workroom/ghostty.conf` (`GhosttyApp.themeConfigURL`) is shared by
  every identity, release included. Several unit tests and `ThemePickerUITests` write it and read it
  back.
- `ShellEnvironmentTests.testProbeTimesOutAndKillsTheChild` ran `pgrep -f wedged-shell` against the
  whole machine, so it could find the same test's stub from another checkout's run.

### 4. Already isolated

Hosted unit runs were close to hermetic already: a per-pid preferences suite (`UserDefaults.app`),
a disabled session store, a per-pid `JJ_CONFIG`, UUID temp directories, port-0 listeners and
UUID-named agent sockets (`AgentHarness`). Builds are per checkout. None of that needed changing.

## What changed

1. **One Debug identity per workroom.** `macapp/Scripts/dev-identity.sh` prints a bundle-id suffix
   for a workroom — a linked git worktree (`.git` is a file) or a secondary jj workspace
   (`.jj/repo` is a file) — and nothing for the project's own checkout. The Makefile passes it to
   every xcodebuild that builds the app as `WORKROOM_DEV_ID_SUFFIX`, and `project.yml` appends it to
   the Debug bundle id only: `com.developwithstyle.workroom.dev.wr-<name>-<hash>`. Preferences,
   session sockets (so each workroom's dev app has its own `wr-agent`), the saved session and
   "already running" all separate at once. The project checkout keeps the plain id, so its
   preferences, TCC grants and sessions are untouched. `make app-identity` prints the id;
   `APP_DEV_ID_SUFFIX=` forces the plain one.
2. **A lock on the GUI session.** `macapp/Scripts/gui-lock.py` runs a command holding a machine-wide
   `flock`: `make app-test` holds it shared, `make app-uitest` exclusively. Any number of unit runs
   overlap; a UI-test run waits for them to drain and then has the screen to itself; unit runs that
   arrive while it is queued or running wait behind it (a turnstile gives queued UI runs priority,
   so a stream of unit runs cannot starve one). A kernel lock goes away with its holder however it
   dies, and its descriptors are not inheritable, so nothing the tests leave running keeps the
   session locked. A waiting run prints who holds the session and for how long;
   `python3 macapp/Scripts/gui-lock.py status` shows it on demand. `WR_GUI_LOCK=off` bypasses it;
   `WR_GUI_LOCK_TIMEOUT=<secs>` gives up with exit 75.
3. **Only test execution is locked.** `app-test` and `app-uitest` now `build-for-testing`, then
   `test-without-building` under the lock, so a build never waits on another workroom's tests and
   never makes them wait.
4. **`make app-run` stops by identity.** `macapp/Scripts/stop-dev-app.sh` stops every running copy
   whose bundle id matches the one being launched (an Xcode-built copy of the same id included) and
   the session helpers serving that id, and nothing else. A helper's id is the one its socket names
   (`wr-agent serve --socket …`), not the bundle its binary lives in: an agent runs whichever copy
   spawned it or last handed it off, so one still serving the plain id can live in a workroom's
   bundle. Stop and relaunch happen inside one hold of the shared lock, so waiting out a UI-test run
   never leaves the app down.
5. **A test launch never ends sessions at quit.**
   `TerminalPersistentSessionPolicy.endsSessionsOnQuit` now backs both quit paths and is false for
   a hosted unit run or an XCUITest launch, which cannot own a persistent session.
6. **`ShellEnvironmentTests`** matches its own UUID-scoped stub path instead of a bare name.

`test-invariants_test.sh` pins the Makefile and `project.yml` halves (the suffix reaches the Debug
id and nothing else; every build carries it; both test targets run under the right lock mode;
`app-run` never kills by name). `dev-identity_test.sh`, `stop-dev-app_test.sh` and
`gui-lock_test.py` run in `make app-test-scripts`, each with a negative control that was confirmed
to fail against the behaviour it replaces.

## How runs interact now

| While another workroom is… | `make app-test` here | `make app-uitest` here | `make app-run` here |
| --- | --- | --- | --- |
| building anything | runs | runs | runs |
| running unit tests | runs alongside | builds, then waits for the GUI | runs |
| running UI tests | builds, then waits | builds, then queues | builds, then waits to relaunch |
| running its dev app | runs | runs — but see below | runs (separate app) |

Two runs **in the same workroom** still share one DerivedData, so run one `make app-*` at a time
per workroom; Xcode's build-database lock rejects a second concurrent build there.

## What this does not solve

- **UI tests still own the Mac while they run.** One XCUITest run at a time per Mac, and nothing
  else should take focus during it — a dev app you launch by hand, a notification, you typing. The
  lock covers what `make` starts, not the person at the keyboard. See the VM route below.
- **Xcode-driven builds** (⌘R/⌘U) don't go through the Makefile and always build the plain id, so a
  workroom opened in Xcode collides with the project checkout's dev app as before.
- **TCC asks again per workroom.** macOS keys permissions to the signing identity, so a workroom's
  dev app prompts afresh for notifications, Automation or other apps' data the first time it needs
  them. Fixture-mode tests mostly don't, but a fixture terminal runs your real login shell, and its
  children are attributed to the app: a shell startup that touches a protected folder (Documents,
  Desktop, iCloud Drive) raises a prompt during a new workroom's first UI-test run. That run holds
  the GUI session until it finishes, and the prompt waits for a person to answer it.
- **A workroom's session socket lives under `/tmp`.** Its longer bundle id pushes
  `Application Support/<id>/sessions/agent.sock` past `sun_path`'s 104 bytes, so
  `PersistentSessionPaths` uses its existing fallback, `/tmp/workroom-<uid>-<id>/`. The suffix is
  capped so that path always fits (`dev-identity.sh`).
- **`ghostty.conf` is still one file for every identity.** Test runs no longer overlap in a way
  that can race on it except unit runs with each other, where the write-then-read window is tiny.
  Follow-up: key it by bundle id, and have `ThemePickerUITests` read the app's own path.
- **`WorkroomWorkflowUITests.testAppLaunchesWithChrome`** launches without fixture mode and reads
  and writes the real session file of its identity (`SessionStore.forCurrentEnvironment` checks
  only `isActive`). Now contained to the identity of the checkout that runs it; still worth closing.
- **Cold `ghostty-vt` cache.** `vcs/scripts/build-ghostty-vt.sh` shares `~/.cache/workroom` between
  checkouts; two builds that both miss it right after an engine bump can race on the clone and the
  publish. Rare, and a rerun fixes it; a lock around its slow path would close it.
- **CPU.** Parallel runs slow each other. The timing-sensitive UI tests (`HistoryStressUITests`'
  two-second budget, the short-lived "Busy"/"Pushing" states) are the first to feel it.
- **Leftovers.** A deleted workroom's identity leaves its preferences plist, its Application Support
  directories and its socket directory behind: `defaults delete <id>`,
  `rm -rf ~/Library/Application\ Support/<id> ~/Library/Application\ Support/Workroom/<id>
  /tmp/workroom-$(id -u)-<id>`, and `tccutil reset All <id>` clear them (stop its dev app first).

## True parallel UI tests: a VM per run (proposed)

Only a separate GUI session makes two XCUITest runs independent, and it also gives the Mac back to
the person using it. On Apple silicon that means a macOS guest, and Virtualization.framework allows
at most two running at once, so this buys up to two UI-test runs alongside whatever the host is
doing. The pieces this change already provides make it mostly plumbing:

- The build stays on the host, where DerivedData is warm: `build-for-testing` is already its own
  step. Only `test-without-building` moves into the guest, against the `.xctestrun` the build wrote
  (`__TESTROOT__`-relative, so the products directory can be mounted anywhere).
- The guest has its own GUI session, so it runs with `WR_GUI_LOCK=off`; the host needs a two-slot
  lock instead, for the two guests.
- Each run gets an APFS clone of one base image, discarded afterwards.

A manual first pass to validate, with [tart](https://tart.run) (`brew install cirruslabs/cli/tart`)
and an image whose Xcode matches the host's `xcodebuild -version`:

```sh
# Once: a base image (~60 GB).
tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest wr-uitest-base

# Per run, on the host, from macapp/ after `make app-vcs` and `xcodegen generate`: the build half of
# `make app-uitest`, ad-hoc signed as CI does, so the guest needs no certificate.
xcodebuild -project WorkroomApp.xcodeproj -scheme WorkroomAppUITests -configuration Debug \
  -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages \
  -destination 'platform=macOS' build-for-testing \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM=
tart clone wr-uitest-base wr-uitest-1
tart run wr-uitest-1 --no-graphics --dir=products:"$PWD/DerivedData/Build/Products":ro &
ssh admin@"$(tart ip wr-uitest-1)"   # password: admin. Then, in the guest:
  ditto "/Volumes/My Shared Files/products" ~/products
  xcodebuild test-without-building -destination 'platform=macOS' \
    -xctestrun ~/products/WorkroomAppUITests_*.xctestrun -resultBundlePath ~/uitest.xcresult
tart stop wr-uitest-1; tart delete wr-uitest-1
```

Open questions before scripting it as `make app-uitest-vm`: whether the image's UI-automation
permission is pre-granted (`automationmodetool enable-automationmode-without-authentication`
inside the guest, otherwise); whether running straight from the shared folder works or the copy
is needed; and how long a fresh clone takes to reach a logged-in session.

## Validation

Done on Linux, where this was written: the three script tests and `test-invariants_test.sh` pass,
and each was confirmed to fail against a deliberately broken copy (inheritable lock descriptors
without `close_fds`, no turnstile, `SIG_IGN` instead of a handler, the old `pkill` logic, jj
detection removed, a path-free checksum, a 40-character name cap, the suffix dropped from a build
or the bundle id, and helpers judged by their bundle instead of the socket they serve). The
Makefile was dry-run (`make -n`) under GNU Make 3.81 and 4.3, from this checkout and from a real
linked git worktree; `make app-test`, `app-uitest` and `app-run` were run end to end with stub
`xcodebuild`/`open`, and `project.yml` parsed. An independent adversarial review found nothing
blocking; its three findings (helpers stopped by bundle, `app-run` stopping before it waited,
an overstated claim about permission prompts) are fixed above. Not run here: xcodebuild,
swift-format, and the Swift tests.

To check on a Mac:

1. `make app-lint` and `make app-test` in the project checkout (plain id; `make app-identity`).
2. `make app-identity` in a workroom prints `….dev.wr-<name>-<hash>`, and `make app-build` there
   signs without asking for a provisioning profile.
3. `make app-test` in two workrooms at once: both pass.
4. `make app-uitest` in two workrooms at once: the second prints who it is waiting for, then runs.
5. `make app-run` in workroom A while workroom B's dev app runs: B's app, and B's panes, survive.
6. With a dev app running, `make app-uitest` in any checkout leaves that app's terminal sessions
   alive.
