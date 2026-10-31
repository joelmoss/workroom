# App identity, preferences and terminal runtime

Paths beginning `Core/`, `Packages/`, `Resources/` and `Scripts/` are relative to `macapp/`.
Release channels and Sparkle feeds are documented in
[CONTRIBUTING](../../CONTRIBUTING.md#release-channels); `project.yml` owns the live settings.

- **Debug builds run side by side with the release build.** The Debug config has a distinct
  identity — bundle id `com.developwithstyle.workroom.dev`, product/display name `Workroom Dev`,
  and the orange-badged `AppIcon-Dev` icon set — so a local build doesn't fight the installed release
  `Workroom` for activation, the key window, preferences (separate UserDefaults domain via the
  bundle id), or the system-wide ⌘§ hotkey. The Debug build deliberately **doesn't register ⌘§**
  and **doesn't run Sparkle scheduled checks** (`#if DEBUG` in `WorkroomApp.swift` / `Updater.swift`)
  so it can't grab the global hotkey or try to "update" itself to the release DMG. Release and
  Nightly share the CLI config at `~/.config/workroom/config.json`. A Dev build
  keeps its own config, at `Application Support/Workroom/<bundle id>/config.json`, so what it makes
  never shows in the other builds. The app passes that path to the CLI as `$WORKROOM_CONFIG`
  (`WorkroomCLI.configPath`). At each launch a Dev build runs the hidden `workroom claim-provisioned`
  command, which moves the remote entries it made out of the shared config. `make app-run` only stops copies
  of the identity it is launching — never your release build, and never another workroom's dev app,
  which `make` builds under its own id (see "Several workrooms at once"). The three app icons
  (`make app-icon` renders all of them) share the yellow blocked mark; Dev and Nightly overlay their
  channel labels.

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

- **The terminal is libghostty** (the `GhosttyKit` xcframework, built from stock upstream with no
  patches; ADR 0061). The embedding C API is not yet stable, so the engine is pinned to one commit.
  **`GHOSTTY_SHA` in `vcs/scripts/build-ghostty-vt.sh` is the single source of truth for the engine
  the app and the daemon ship** — read it there rather than trusting a version quoted anywhere else.
  Bumping it is not a one-line change (see the procedure under §N of `macapp/QA-libghostty.md`). The
  build needs Zig and Xcode's Metal toolchain; `xcodegen generate` runs it. The terminal surface
  (`Core/GhosttySurfaceView.swift`) + runtime (`GhosttyApp`/`GhosttyRuntimeAdapter`) are ours; the
  bundled `Resources/ghostty` (terminfo + shell-integration) must ship for the engine to start.

- **The child environment has two layers, and only one of them is reliable** (`WorkroomSystem/ShellEnvironment.swift`).
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
  `.environment()` (the full environment, for setup/teardown scripts). **UI-test launches** are the
  exception to "one `setenv`, PATH only": `UITestFixture.applyHermeticShell()` also sets `SHELL` and
  `ZDOTDIR` in `init` (a hermetic zsh with Ghostty's integration and none of the developer's rc
  files, #268), and the launch probe is skipped. The on-demand `refresh()` calls in `WorkroomCLI`
  and `NewWorkroomDialog` still run there, against that hermetic shell, so `PATH` stays the floor.
  A `fixture: false` UI launch (`WorkroomWorkflowUITests`, real projects) is hermetic too: its run tabs
  no longer see rc-only `PATH` entries.
