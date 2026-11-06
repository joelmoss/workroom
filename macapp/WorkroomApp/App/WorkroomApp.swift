import AppKit
import Defaults
import SwiftUI
import UserNotifications
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import os

// No `@main`: the entry point is `main.swift`, which dispatches Ghostty's `+action` CLI when this
// binary is invoked through the `Contents/MacOS/ghostty` symlink, and calls `WorkroomApp.main()`
// otherwise. Everything below runs on the app path only.
struct WorkroomApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var updater = Updater()
  // The shared instances, so a detached pane's window can inject the SAME objects (issue #172):
  // environment does not cross an `NSHostingView`, so that window cannot inherit these from the scene.
  @StateObject private var codingAgentUsage = CodingAgentUsageMonitor.shared
  @StateObject private var claudeUsageBridge = ClaudeUsageBridge.shared
  /// Fetches release notes for the "What's New" dialog (shown automatically on the first launch
  /// after an update). One instance shared across windows; presentation is owned window-side,
  /// gated to the launch/restore window.
  @StateObject private var whatsNew = WhatsNewService(fetcher: GitHubReleasesClient())

  init() {
    let interval = LaunchSignposts.begin("App initialization")
    defer { LaunchSignposts.end("App initialization", interval) }
    // Start Sentry first, before anything else can crash — the crash handler must be
    // installed as early as possible. Runs on the main thread (App.init does), as the SDK
    // requires. macOS-trimmed option set: see SentryConfig.start().
    SentryConfig.start()

    // Ensure the in-process environment (inherited by the bundled `workroom`
    // binary and the terminals) can find git, which a Finder-launched .app's
    // minimal PATH excludes. This is the PATH floor — `/etc/paths` + `/etc/paths.d`
    // + well-known tool dirs — so it is already correct, just not yet enriched.
    //
    // The ONLY `setenv` for PATH in the app's lifetime, and it runs here because
    // `init` is single-threaded: `setenv` can reallocate `environ`, and the status
    // sweep reads `ProcessInfo.processInfo.environment` from background threads
    // constantly. A later write would be a use-after-free race. Everything that
    // needs the enriched value reads `ShellEnvironment.path()` / `.environment()`.
    let pathInterval = LaunchSignposts.begin("Initial PATH floor")
    setenv("PATH", ShellEnvironment.path(), 1)
    LaunchSignposts.end("Initial PATH floor", pathInterval)
    // A Dev build's own config, for the bundled CLI and for `workroom` in its terminals, which
    // inherit this environment. Set here for the same reason as PATH above.
    if let config = WorkroomCLI.configPath() { setenv("WORKROOM_CONFIG", config, 1) }

    // UI-test launches only: a shell with Ghostty's integration but none of the developer's rc
    // files, so a test never depends on (or runs) someone's dotfiles. It is a `setenv`, so it
    // belongs here with the one above: `init` is single-threaded, and it must land before the probe
    // below starts reading the environment. `applyFixtureDefaults()` at the end of `init` runs
    // after that probe, so it is the wrong home. A failure crashes the launch: carrying on would
    // run the real rc files, which is what this prevents. Inert in production (DEBUG-only).
    #if DEBUG
      do {
        try UITestFixture.applyHermeticShell()
      } catch {
        preconditionFailure("could not prepare the hermetic UI-test shell: \(error)")
      }
    #endif

    // Enrich it in the background: one `$SHELL -ilc` for what only an interactive
    // login shell knows (`.zshrc`-exported PATH entries, version-manager shims).
    // Detached so launch never waits on someone's dotfiles; the floor above holds
    // until it lands, and holds permanently if the probe fails.
    //
    // Skipped in hosted unit runs and in UI-test launches: see `runsLaunchShellProbe`, which
    // carries both reasons. Only the LAUNCH probe is skipped in a UI-test launch: `WorkroomCLI`
    // (create/remove/scripts) and `NewWorkroomDialog` still call `refresh()` on demand, under the
    // `SHELL`/`ZDOTDIR` set above, so they read no developer rc files either — which is why that
    // `setenv` must land before anything can call `refresh()`.
    if AppEnvironment.runsLaunchShellProbe() {
      Task.detached(priority: .utility) { await ShellEnvironment.refresh() }
    }

    // UI-test fixture mode only: park the pref-driven UI state (inspector open on the requested
    // section, diff viewer in the requested layout) in a known state before the first `AppStore`
    // seeds `activeInspectorSection` from `Defaults`. Inert in production — a real user never passes
    // the flag. See `UITestFixture.applyFixtureDefaults`.
    #if DEBUG
      UITestFixture.applyFixtureDefaults()
      UITestFixture.endLiveDaemonWhenTheAppExits()
    #endif

    // The app's services, chosen once (ADR 0022): every window's `AppStore`, and the views under
    // it, use these. Before any store is built.
    #if DEBUG
      AppServices.current = AppEnvironment.current.isFixture ? .fixture : .live
    #else
      AppServices.current = .live
    #endif
  }

  var body: some Scene {
    // First-run onboarding (issue #151): computed once per `body` evaluation (effectively once, at
    // launch — nothing here is `@Default`-observed, so this doesn't re-run reactively later), and
    // used to flip BOTH scenes' `.defaultLaunchBehavior` below so that at genuine app launch, EXACTLY
    // ONE of them auto-opens: the wizard while onboarding might still be needed, the normal main
    // window once it's done. `projectsEmpty` isn't knowable this early (it needs the async
    // project-list load), so `mightShow` is a synchronous approximation — `OnboardingWindow`'s own
    // `.task` double-checks the real gate once it can, and corrects course if this guess was wrong
    // (an existing install with projects that just never completed onboarding).
    let onboardingMightShow = OnboardingGate.mightShow(
      hasCompleted: Defaults[.hasCompletedOnboarding])

    // Value-based scene (issue #70): SwiftUI mints one window — and one fresh `AppStore` — per
    // `WindowSeed`, guaranteeing independent per-window state (and sidestepping the documented
    // `@StateObject`-in-`WindowGroup` cross-window sharing bug). ⌘N opens a new seed; the launch
    // window gets `.launch` (restores the saved selection).
    WindowGroup(for: WindowSeed.self) { $seed in
      RootWindow(seed: seed ?? .launch)
        .background(
          WindowDisplayObserver {
            didDisplayWindow()
            codingAgentUsage.startPollingAfterDisplay()
          }
        )
        .environmentObject(updater)
        .environmentObject(whatsNew)
        .environmentObject(codingAgentUsage)
        .environmentObject(claudeUsageBridge)
    }
    // The taller single-row title bar (with AppKit centering the traffic lights in it — the
    // "breathing room" above/below the chrome, issue #23) comes from an EMPTY, AppKit-owned
    // `.unifiedCompact` toolbar set in `WindowBackgroundThemer`, NOT a SwiftUI `.windowToolbarStyle` +
    // `.toolbar` item. A SwiftUI-managed toolbar item forces the overflow `menuFormRepresentation`
    // recompute that caused the macOS-26 AppHangs (see WindowBackgroundThemer). The chrome lives in a
    // full-width `.left` titlebar accessory (never overflows).
    .commands { WorkroomCommands(updater: updater) }
    // Suppressed while onboarding might still be needed — an `orderOut(nil)` in `RootWindow`'s
    // `WindowAccessor` was tried first and doesn't reliably stick (SwiftUI's own WindowGroup launch
    // machinery re-asserts the window's visibility after that callback runs); `.defaultLaunchBehavior`
    // is the actual, Apple-provided lever for "don't auto-open this scene's window at launch."
    // Explicit `openWindow(value:)` calls later (from `OnboardingWindow`, once it's done) are
    // unaffected by this — it only governs automatic launch behavior.
    .defaultLaunchBehavior(onboardingMightShow ? .suppressed : .automatic)
    // `session.json` reopens the windows; macOS restoring one too adds a window. See
    // `AppStore.attachWindow` for why `isRestorable = false` isn't enough on its own.
    .restorationBehavior(.disabled)

    Settings {
      SettingsView()
        .environmentObject(updater)
        .environmentObject(codingAgentUsage)
        .environmentObject(claudeUsageBridge)
    }
    .windowResizability(.contentMinSize)
    .restorationBehavior(.disabled)

    // The first-run onboarding wizard (issue #151). A plain `Window` scene, like `Settings` — no
    // `AppStore`, so it falls through the same aux-window carve-outs (⌘W fallback, shortcut/switcher
    // no-ops, quit/window-count exclusion, ⌘` cycle exclusion) for free; see `OnboardingWindow`'s doc
    // comment. `.windowResizability(.contentSize)` is required because — unlike `Settings`, whose
    // non-resizability comes from the scene TYPE — a plain `Window` defaults to user-resizable
    // regardless of a fixed content `.frame()`.
    //
    // `.presented` forces this scene to auto-open at launch instead of `WindowGroup`'s suppressed
    // one, exactly when `onboardingMightShow` — so a genuinely fresh launch shows ONLY the wizard,
    // not the (empty) main window underneath it. See `OnboardingWindow`'s own `.task` for what
    // happens if this guess turns out wrong, and its close-notification handler for bringing the main
    // window up once the wizard is dismissed or finished, by any path.
    //
    // `.commandsRemoved()` drops this scene's auto Window-menu entry ("Welcome to Workroom") —
    // reopening it is still possible via the explicit `openWindow(value:)` calls above, unaffected.
    Window("Welcome to Workroom", id: OnboardingWindow.sceneID) {
      OnboardingWindow()
        .background(WindowDisplayObserver { didDisplayWindow() })
    }
    .windowResizability(.contentSize)
    .windowStyle(.hiddenTitleBar)
    .defaultLaunchBehavior(onboardingMightShow ? .presented : .suppressed)
    .commandsRemoved()

    // The system menu-bar item (issue #33) is hand-managed by `AppDelegate`'s `MenuBarController`
    // (an `NSStatusItem`), not a SwiftUI `MenuBarExtra`, so a click with no pending notifications can
    // simply focus the app instead of opening an empty popover — `MenuBarExtra` gives no hook to
    // intercept its click. See `MenuBarController`.
  }

  private func didDisplayWindow() {
    LaunchSignposts.didDisplayWindow()
    updater.startAfterDisplay()
    appDelegate.prewarmAfterDisplay()
  }
}

/// Identity for a window scene (issue #70). `restore` is true only for the window SwiftUI brings up
/// at launch — combined with `ProjectStore.consumeInitialRestore()` that single window reapplies the
/// persisted selection; every ⌘N window carries a fresh `restore == false` seed and opens blank.
struct WindowSeed: Codable, Hashable {
  let id: UUID
  /// Whether this window may adopt a saved session — true for the launch window and for each sibling
  /// it reopens (issue #46), false for every ⌘N window, which always starts blank.
  let restore: Bool
  /// Whether this is THE launch window, as opposed to a sibling reopened from the saved session.
  ///
  /// Separate from `restore` because the two answer different questions and both siblings and the
  /// launch window restore. Only the launch window runs the What's-New auto-check and fans the
  /// siblings out — without this distinction every restored window would pop that dialog.
  var isLaunch = false
  /// A workroom this window opens to take from another (issue #444): a `WorkroomHandOffs` request,
  /// completed once the window is up. Nil for every other window.
  var handOff: UUID? = nil

  /// The launch window: a fresh id allowed to restore the saved session.
  static var launch: WindowSeed { WindowSeed(id: UUID(), restore: true, isLaunch: true) }

  /// A window reopened from the saved session, keyed on the session it will claim.
  static func restoring(key: UUID) -> WindowSeed {
    WindowSeed(id: key, restore: true, isLaunch: false)
  }
}

/// One window's root. The value-based `WindowGroup` gives each window its own `RootWindow`, so the
/// `@StateObject` below is a fresh per-window `AppStore` sharing the one `ProjectStore`. It injects
/// that store into the environment, exposes it to menu commands via `focusedSceneValue`, and
/// registers the window↔store pair with `WindowRegistry` (issue #70).
struct RootWindow: View {
  let seed: WindowSeed
  @StateObject private var store: AppStore
  @Environment(\.openWindow) private var openWindow

  init(seed: WindowSeed) {
    self.seed = seed
    // Every window shows the app's one notification list (ADR 0064).
    let store = AppStore(projectStore: .shared, notifications: WindowRegistry.shared.notifications)
    // Capture the current window's size ONCE, at this window's creation, so the new window can be
    // sized to match it before it's shown (issue #70). nil for the launch window.
    store.pendingInitialWindowSize = WindowRegistry.shared.preferredNewWindowSize
    // A window opened for a moved workroom opens where it was dropped, at the standard size (#444).
    if let request = seed.handOff.flatMap(WorkroomHandOffs.shared.request(for:)) {
      store.opensForHandOff = true
      store.pendingInitialWindowTopLeft = request.topLeft
    }
    // Only the launch window runs the What's-New auto-check (see RootView). Sibling windows reopened
    // from the saved session also carry `restore: true`, so gating on that would pop the dialog once
    // per restored window (issue #46).
    store.isRestoreWindow = seed.isLaunch
    // Which saved window this one adopts. The launch window takes the first unclaimed session; a
    // sibling was opened FOR a specific key and claims exactly that one.
    store.sessionKey = seed.id
    store.claimsSavedSession = seed.restore
    _store = StateObject(wrappedValue: store)
  }

  var body: some View {
    RootView()
      .background(WindowDisplayObserver { store.windowDidDisplay() })
      .environmentObject(store)
      .environmentObject(store.runCommand)
      .environmentObject(store.notifications)
      .environmentObject(store.terminals)
      .environmentObject(store.terminals.codingAgentManager)
      .environmentObject(store.remoteState)
      .focusedSceneValue(store)
      .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
      .background(
        WindowAccessor { window in
          WindowRegistry.shared.register(window: window, store: store)
          store.attachWindow(window)
        }
      )
      // The action alone: a closure over `openWindow` would hold this view, and with it this
      // window's store and terminals, for as long as the registry keeps it.
      .onAppear { [openWindow] in WindowRegistry.shared.openWindow = { openWindow(value: $0) } }
      .task(id: store.hostWindow != nil) {
        // Not under XCTest: `WorkroomAppTests` hosts this app to get `@testable import Workroom`,
        // which means this real WindowGroup scene renders too — and without this guard, its `.task`
        // ran on every `make app-test`, unconditionally `bootstrap()`ing the SHARED, non-fake
        // `AppStore` (production default `cli: WorkroomCLI.shared`) against the developer's REAL
        // `~/.config/workroom/config.json`, then opening a REAL terminal in a REAL project
        // directory for whatever it found. Same guard, same reasoning, as the `ShellEnvironment`
        // skip in `init` above. Unit tests construct their own isolated `AppStore()`s and never see
        // this window at all, so skipping its bootstrap breaks nothing under test.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
          return
        }
        // Everything below reads what `attachWindow` claims, and a window opened as the onboarding
        // window closes gets here first. Going on would reopen this window's own saved session as a
        // sibling and leave this one blank.
        guard store.hostWindow != nil else { return }
        // Again now it shows: SwiftUI has placed it by now, over where it was set up to go.
        // Once: a `.task` that re-fires must not put back a window the user has since moved.
        if store.opensForHandOff, let window = store.hostWindow {
          store.placeHandOffWindow(window)
          store.opensForHandOff = false
        }
        store.applyRestoredFrame()
        // The store's flags, not the seed's: `attachWindow` may have given this window the launch
        // role (`ProjectStore.takeLaunchRole`).
        await store.bootstrap(restore: store.claimsSavedSession)
        if let handOff = seed.handOff { WorkroomHandOffs.shared.complete(handOff, into: store) }
        // Reopen the windows that were open at the last quit (issue #46). Only the launch window
        // fans out, and each key is handed out once, so a `.task` re-fire cannot double-open.
        guard store.isRestoreWindow else { return }
        for key in ProjectStore.shared.pendingSessionKeys() {
          openWindow(value: WindowSeed.restoring(key: key))
        }
      }
  }
}
