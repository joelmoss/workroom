# Design: testing the app from several workrooms at once

Repo: joelmoss/workroom
Status: host-side isolation shipped in #261 (merged 2026-09-29, 13202838); UI tests in Tart
guests, two at a time, built as `make app-uitest-vm` (issue #274, 2026-11-07)

> **Note:** Workroom dropped Jujutsu (jj) support in #266. Passages here that describe jj
> behaviour are a record of the design as it stood then, not of the current code.

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

- **One `wr-agent` for every dev app.** Agent hand-off is on in every build (#389; until then it
  was gated to Nightly and Dev) and runs on every non-test launch (`applicationDidFinishLaunching`),
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
   *(Historical: the "Persist sessions" setting, `endsSessionsOnQuit` and `endAllSessions` were
   later removed. Quitting never ends sessions now, so this hazard no longer exists.)*
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

Two runs **in the same workroom** still share one DerivedData, so the targets that build, test or
delete it (`CHECKOUT_LOCKED_TARGETS` in `mk/app.mk`) take turns per workroom: a second one waits on
the checkout lock (`gui-lock.py checkout`) and names the run it is waiting for, rather than failing
codesign half-way through a corrupted build.

## What this does not solve

- **UI tests still own the Mac while they run.** One XCUITest run at a time per Mac, and nothing
  else should take focus during it — a dev app you launch by hand, a notification, you typing. The
  lock covers what `make` starts, not the person at the keyboard. `make app-uitest-vm` (below)
  runs them in Tart guests instead.
- **Xcode-driven builds** (⌘R/⌘U) don't go through the Makefile and always build the plain id, so a
  workroom opened in Xcode collides with the project checkout's dev app as before.
- **TCC asks again per workroom.** macOS keys permissions to the signing identity, so a workroom's
  dev app prompts afresh for notifications, Automation, the microphone or other apps' data the
  first time it needs them. Fixture-mode tests mostly don't. A UI-test launch's terminals do run a
  login shell, and its children are attributed to the app, but since #268 that shell is a hermetic zsh
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

## UI tests off the host screen: Tart guests, two at a time (built 2026-11-07, issue #274)

Only a separate GUI session lets a UI-test run leave the Mac alone, so the person using it can keep
typing. On Apple silicon that means a macOS guest. Virtualization.framework caps a Mac at two
running macOS guests (a kernel limit from the macOS licence). On this Mac (48 GB, 18 cores) two
guests of 4 CPUs / 8 GB each fit with room to spare, so `make app-uitest-vm` runs **up to two
UI-test guests at once**, from any mix of checkouts, or one run split across both (`VM_SHARDS=2`).

```
HOST                                          GUEST (APFS clone, 0.04 s)
make app-uitest-vm
 ├─ build-for-testing: app-uitest's line
 │    (Apple Development, APP_ID_FLAGS)
 └─ Scripts/uitest-vm.sh
     ├─ tar Build/Products → <run dir>/products.tar
     │    (DerivedData/Logs/TestVM/<run>)
     ├─ split -only-testing: classes over VM_SHARDS
     └─ per shard: gui-lock.py vm-slot (fail-closed,
        VM_SLOTS=2 counting lock, WR_VM_LOCK_DIR)
         └─ Scripts/uitest-vm-guest.sh
             ├─ tart clone wr-uitest-base wr-uitest-<slot>-<pid>
             │    tart set --random-mac
             ├─ tart run --no-graphics
             │    --dir=results:<run dir>  ──────►  admin auto-logged in at the console,
             │                                      Automation Mode allowed without auth
             ├─ bounded wait for `tart exec` (Tart Guest Agent; VM_BOOT_TIMEOUT=180)
             ├─ tart exec: xcodebuild -version ──►  must equal the host's
             ├─ tart exec ───────────────────────►  tar -xf products.tar -C ~/products
             │                                      xcodebuild test-without-building
             │                                        $(APP_UITEST_FLAGS) (this shard's)
             │                                        -xctestrun <SDK-matched file>
             │                                        -resultBundlePath <share>/<shard>.xcresult
             └─ trap (success, failure, INT/TERM/HUP):
                  tart stop; tart delete
     ├─ wait for every shard; rm products.tar
     └─ Tests: summary per shard, then of the merged bundle
        (xcresulttool merge); exit with the first failing xcodebuild status
```

- **Build once, on the host.** The guest tests the products `make app-uitest` builds, signed Apple
  Development (team B898J443L9). The dev-signed runner and app launch in the guest unchanged
  (measured 2026-11-07), so there is no ad-hoc fallback. Never build ad-hoc into the shared
  `DerivedData`: that replaces the signed dev products the dev app and TCC grants depend on.
- **Snapshot before queueing.** The run tars its products right after the build, because the
  person keeps working while it waits, and a `make app-run` in the same workroom rebuilds `Debug/`.
  A tar, unpacked on the guest's own disk, because the virtiofs share breaks the symlinks inside
  framework and app bundles ("Too many levels of symbolic links"): tests cannot run from the share,
  and `ditto` from it fails the same way. The tar is ~540 MB and takes ~1 s each way.
- **`tart exec`, not ssh.** Cirrus images run the Tart Guest Agent, so the host runs commands in the
  guest's logged-in session over vsock: no IP lookup, password or ssh key. Arguments reach the guest
  verbatim and the exit status comes back. It answers 17-30 s after `tart run` for a guest booting
  alone, up to 40 s when two boot at once (measured). The guest `PATH` is
  `/bin:/usr/bin:/usr/sbin:/usr/local/bin:/opt/homebrew/bin`.
- **Pick one `.xctestrun`.** `Build/Products` can hold several, one per SDK built against; the run
  takes `WorkroomAppUITests_macosx<xcrun --show-sdk-version>-<arch>.xctestrun`. Its
  `__PLATFORMS__`, `__SHAREDFRAMEWORKS__` and `__DEVELOPERUSRLIB__` resolve against the guest's
  Xcode, so the guest's `xcodebuild -version` must equal the host's; a guest that differs fails
  the run with both versions named.
- **Same test selection.** `$(APP_UITEST_FLAGS)` reaches the guest run, so the default skips and a
  caller's `-only-testing:` behave as they do on the host.
- **Two slots, failing closed.** Each guest boots holding one of `VM_SLOTS` (default 2) slots of
  `gui-lock.py vm-slot`: a flock per slot under `WR_VM_LOCK_DIR` (default
  `~/.cache/workroom/vm-locks`), shared by every checkout. A third run waits and says who holds
  the slots (`python3 macapp/Scripts/gui-lock.py vm-status`). Unlike the host GUI lock, which runs
  unlocked when its directory is unusable, the slot lock exits 75 with the reason, and it ignores
  `WR_GUI_LOCK=off`: a third `tart run` would fail to boot. The guests take no GUI lock, so host
  unit-test and UI-test runs carry on beside them. The slots count only this target's guests: a
  macOS guest started another way (a hand-run `tart run wr-uitest-base` while updating the image,
  or a UTM or Parallels VM) takes one of the Mac's two without a slot, and a run that boots beside
  two of them fails ("the guest stopped before it answered") and deletes its clone.
- **Clone names carry the slot and the pid** (`wr-uitest-<slot>-<pid>`), so two runs never pick one
  name, and a clone a SIGKILLed run left behind (its trap never ran) is recognisable: the next guest
  run deletes any such clone whose pid is gone. Nothing else is ever deleted, and the base is only
  cloned from. `tart set --random-mac` on each clone keeps two guests off one MAC address, and
  `TART_NO_AUTO_PRUNE=1` stops a clone from pruning Tart's image cache.
- **Sharding.** `VM_SHARDS=2` with `-only-testing:` classes deals the classes round-robin over two
  guests that run at once, each in its own slot. Without a class list each guest lists the suite
  itself (`xcodebuild -enumerate-tests` against the `.xctestrun`, ~3 s) and takes every second
  class of the sorted list; both list the same products with the same flags, so they agree without
  talking. Enumerating launches the test runner app, which is why it runs in the guest and never
  on the host. Each shard's bundle is reported, then `xcrun xcresulttool merge` combines them.
- **Results come home.** Each guest writes its result bundle into the read-write share, the run
  directory `macapp/DerivedData/Logs/TestVM/<run>/`; a bundle inside the guest is deleted with
  the guest. The snapshot tar is deleted when the run ends, however it ends.

Prerequisites: **disk** for the image (the Xcode 27.2 image reports 140 GB disk / 90 GB used;
clones are copy-on-write) and [tart](https://tart.run) 2.41.1 or later (Fair Source, royalty-free on
a personal workstation). Install tart from its notarized GitHub release, since the
`cirruslabs/cli` Homebrew tap's formula is broken on current Homebrew: download `tart.tar.gz` from
<https://github.com/cirruslabs/tart/releases>, move `tart.app` to `/Applications`, and link
`/Applications/tart.app/Contents/MacOS/tart` onto `PATH`. A one-time base image:

```sh
# Use the image whose Xcode matches `xcodebuild -version` (host: macOS 27.2, Xcode 27.2 27B52).
tart clone ghcr.io/cirruslabs/macos-golden-gate-xcode:27.2 wr-uitest-base
tart set wr-uitest-base --cpu 4 --memory 8192 --display 1920x1200   # fixture windows are 1450x780,
                                                                    # one test needs 1650 wide
# Homebrew bash (4.4+) for EngineBumpSmokeUITests.testBashExitStatusReachesTheApp (#465), which
# skips without it. Boot the base itself once, install, and shut it down cleanly:
tart run wr-uitest-base --no-graphics &
tart exec wr-uitest-base /bin/zsh -lc 'HOMEBREW_NO_AUTO_UPDATE=1 brew install bash'
tart exec wr-uitest-base sudo shutdown -h now
```

Nothing else to provision: Cirrus images log `admin` in at the console, already allow Automation
Mode without authentication (`templates/base.pkr.hcl` runs
`automationmodetool enable-automationmode-without-authentication`), and run the guest agent. The
app no longer shells out to `jj` (#266). `--dir=name:path[:ro]` mounts at
`/Volumes/My Shared Files/<name>`.

Two timeouts bound a guest: `VM_BOOT_TIMEOUT` (default 180 s) for the guest agent to answer, and
`VM_RUN_TIMEOUT` (default 3600 s) for everything after that (unpacking, listing the suite, the
tests), after which the guest is stopped and the run exits 124. A guest can stall without a word: in the first full-suite run one sat 75 minutes in a test's
Set Up until its VM stopped.

Measured on this Mac, 2026-11-07 (macOS 27.2, 48 GB / 18 cores; tart 2.41.1; guests 4 CPU / 8 GB):

| Run | Result |
| --- | --- |
| `SplitPaneUITests` alone | guest answered in 17 s; 14/14 in 126 s; 3m36s for the whole `make`, build included |
| Two runs at once (SplitPane, TabActions), then a third (ActivityBar) | both booted at once (35 s and 40 s); the third waited 1m27s ("waiting for a VM slot", `vm-status` 2 of 2, exit 1), took the freed slot; 14/14, 2/2, 1/1 |
| `VM_SHARDS=2` over four classes | 15 + 5 tests, merged `Tests: Passed - 20 passed, 0 failed, 0 skipped (of 20)`; 3m39s with the build |
| `VM_SHARDS=2`, whole suite (enumerated in the guests) | 49 classes, 25 / 24; guest 1 54/54 in 885 s; guest 2 52 passed and 5 failed (`ProgramStatusLiveDaemonUITests` ×2, `TerminalCodingAgentUITests` ×3), then stalled in `ThemePickerUITests` (above) |
| Memory, two guests running tests | host 58-68% free; each guest 72-84% of its 8 GB free |
| SIGTERM mid-test; SIGKILL of the run | clone stopped and deleted, snapshot removed, within 5 s (the run watchdog polls every 5 s); the killed run's clone removed by the next run |

The guest-2 failures and the stall are not yet triaged: whether they also fail on the host, or come
from something the guest lacks, is open (issue #274).

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
