# Design: testing the app from several workrooms at once

Repo: joelmoss/workroom
Status: host-side isolation IMPLEMENTED on master (13202838); one VM guest per UI-test run
PROPOSED and reviewed, not built

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
- `~/Library/Application Support/Workroom/ghostty.conf` (`GhosttyApp.themeConfigURL`) was shared by
  every identity, release included, and several unit tests and `ThemePickerUITests` write it and
  read it back. **Fixed separately in #262**, which landed first: the generated config is now
  `Workroom/<bundle id>/ghostty.conf` (`GhosttyApp.defaultThemeConfigURL`), a test process gets a
  per-pid file of its own, and `ThemePickerUITests` names the file it wants with
  `-WorkroomUITestGhosttyConfigFile` instead of computing a path. Two processes sharing ONE bundle
  id can still interleave their write and load; accepted as-is (issue #264, closed wontfix).
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
  them. Fixture-mode tests mostly don't. A UI-test launch's terminals do run a login shell, and its
  children are attributed to the app, but since #268 that shell is a hermetic zsh
  (`UITestFixture.applyHermeticShell`: `SHELL=/bin/zsh`, a `ZDOTDIR` holding only a generated
  `.zshrc`), so a developer's `~/.zshenv`, `~/.zprofile`, `~/.zshrc` and `~/.zlogin` are never read.
  Before that, a shell startup that touched a protected folder (Documents, Desktop, iCloud Drive)
  could raise a prompt during a new workroom's first UI-test run, holding the GUI session until a
  person answered it; that was never measured, and it no longer applies to UI-test launches.
  `PATH` is still developer-influenced, so this isolates startup files only.
- **A workroom's session socket lives under `/tmp`.** Its longer bundle id pushes
  `Application Support/<id>/sessions/agent.sock` past `sun_path`'s 104 bytes, so
  `PersistentSessionPaths` uses its existing fallback, `/tmp/workroom-<uid>-<id>/`. The suffix is
  capped so that path always fits (`dev-identity.sh`).
- ~~**`ghostty.conf` is still one file for every identity.**~~ **Done in #262**, both halves of the
  follow-up this listed: it is keyed by bundle id, and `ThemePickerUITests` is handed its path
  rather than computing one. What remains is narrower and accepted rather than fixed (issue #264,
  closed wontfix): two processes under the SAME bundle id (two copies of one workroom's dev app)
  can still interleave a write and a load. Transient and self-healing on the next theme apply.
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

## UI tests off the host screen: a VM per run (proposed, reviewed 2026-09-30)

Only a separate GUI session lets a UI-test run leave the Mac alone, so the person using it can keep
typing. On Apple silicon that means a macOS guest. Virtualization.framework caps a Mac at two
running macOS guests (a kernel limit from the macOS licence), but on a 16 GB / 10-core M1 Pro one
guest is the realistic ceiling: tart's default guest is 2 CPUs / 4 GB, and a guest running Xcode's
test runner plus the app likely wants ~4 CPUs / 8 GB (unmeasured). So the goal is **one UI-test
run in a guest, off the host screen**, not two in parallel.

```
HOST                                          GUEST (APFS clone, one at a time)
make app-uitest-vm
 ├─ build-for-testing: app-uitest's line
 │    (Makefile:136, Apple Development, APP_ID_FLAGS)
 ├─ cp -c -R Debug/ + SDK-matched .xctestrun
 │    into a per-run snapshot dir
 └─ gui-lock.py exclusive --fail-closed,
    own WR_GUI_LOCK_DIR (the one guest slot)
     ├─ tart clone wr-uitest-base wr-uitest-<id>
     ├─ tart run --no-graphics
     │    --dir=products:<snapshot>:ro
     │    --dir=results:<host dir>  ───────►  auto-login Aqua session,
     │                                        automation mode on
     ├─ bounded wait: tart ip, then ssh
     ├─ ssh ───────────────────────────────►  ditto products → ~/products
     │                                        xcodebuild test-without-building
     │                                          $(APP_UITEST_FLAGS)
     │                                          -xctestrun <SDK-matched file>
     │                                          -resultBundlePath <results dir>
     ├─ trap (success, failure, INT/TERM):
     │    tart stop; tart delete; rm snapshot
     └─ exit with the guest's xcodebuild status;
        results/*.xcresult stays on the host
```

- **Build once, on the host.** The guest tests the products `make app-uitest` builds, signed Apple
  Development. The only entitlement is `com.apple.security.automation.apple-events`, which needs
  no provisioning profile, so a dev-signed runner should launch in the guest; the first pass
  checks this, and falls back to an ad-hoc build in its own `-derivedDataPath DerivedData-vm` if
  it does not. Never build ad-hoc into the shared `DerivedData`: that replaces the signed dev
  products the dev app and TCC grants depend on.
- **Snapshot before queueing.** The run clones its products right after the build, because the
  person keeps working while it waits, and a `make app-run` in the same workroom rebuilds `Debug/`.
- **Pick one `.xctestrun`.** `Build/Products` can hold several (`_macosx26.5-` and `_macosx27.0-`
  here); choose the one matching `xcrun --show-sdk-version`. Its `__PLATFORMS__`,
  `__SHAREDFRAMEWORKS__` and `__DEVELOPERUSRLIB__` resolve against the guest's Xcode, so the
  guest's Xcode must match the host's.
- **Same test selection.** Pass `$(APP_UITEST_FLAGS)` to the guest run (`Makefile:102`), so the
  default skips and a caller's `-only-testing` behave as they do on the host.
- **The lock fails closed.** Unlike the host GUI lock, which runs unlocked when its directory is
  unusable (`gui-lock.py` `run_locked`), the VM slot lock exits 75 with the reason, and the VM
  target ignores `WR_GUI_LOCK=off`. A second guest on this Mac would swap it.
- **Results come home.** The result bundle is written to a read-write shared folder; a bundle
  inside the guest is deleted with the guest.

Prerequisites on this Mac (checked 2026-09-30): **~100 GB free disk** (33 GB free now; a Sonoma
Xcode image is a 54 GB compressed pull, a Tahoe Xcode image reports a 92 GB minimum disk) and
[tart](https://tart.run) (`brew install cirruslabs/cli/tart`; Fair Source, royalty-free on a
personal workstation). A one-time base image, provisioned with what the suite needs:

```sh
# Host: macOS 27.0.1, Xcode 27.0 (27A266a). Use the image whose Xcode matches
# `xcodebuild -version`.
tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:27 wr-uitest-base   # or macos-golden-gate-xcode:27
tart set wr-uitest-base --cpu 4 --memory 8192 --display 1920x1200   # fixture windows are 1450x780,
                                                                    # one test needs 1650 wide
tart run wr-uitest-base --no-graphics &
ssh admin@"$(tart ip wr-uitest-base)"   # password: admin. Then, in the guest:
  brew install jj    # the app shells out to `jj` by name; match the host's `jj --version`
  sudo shutdown -h now
```

Cirrus images already enable Automation Mode (`templates/base.pkr.hcl` runs
`automationmodetool enable-automationmode-without-authentication`), so XCUITest needs no password
in the guest. Default login is admin/admin; `--dir=name:path[:ro]` mounts at
`/Volumes/My Shared Files/<name>`.

Still open, for the first manual pass: whether the dev-signed runner launches in the guest; the
guest's real memory use during a run; whether `/opt/homebrew/bin` reaches the guest xcodebuild's
`PATH` over ssh (the app finds `jj` through it); whether tests can run straight from the shared
folder, skipping the copy; and how long a fresh clone takes to reach a logged-in session. Tracked
in issue #274.

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
