import AppKit
import Defaults
import SwiftUI
import UserNotifications

@main
struct WorkroomApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var updater = Updater()
  /// Fetches release notes for the "What's New" dialog (shown automatically on the first launch
  /// after an update). One instance shared across windows; presentation is owned window-side,
  /// gated to the launch/restore window.
  @StateObject private var whatsNew = WhatsNewService(fetcher: GitHubReleasesClient())

  init() {
    // Start Sentry first, before anything else can crash — the crash handler must be
    // installed as early as possible. Runs on the main thread (App.init does), as the SDK
    // requires. macOS-trimmed option set: see SentryConfig.start().
    SentryConfig.start()

    // Ensure the in-process environment (inherited by the bundled `workroom`
    // binary and the terminals) can find git/jj, which a Finder-launched .app's
    // minimal PATH excludes. This is the PATH floor — `/etc/paths` + `/etc/paths.d`
    // + well-known tool dirs — so it is already correct, just not yet enriched.
    //
    // The ONLY `setenv` for PATH in the app's lifetime, and it runs here because
    // `init` is single-threaded: `setenv` can reallocate `environ`, and the status
    // sweep reads `ProcessInfo.processInfo.environment` from background threads
    // constantly. A later write would be a use-after-free race. Everything that
    // needs the enriched value reads `ShellEnvironment.path()` / `.environment()`.
    setenv("PATH", ShellEnvironment.path(), 1)

    // Enrich it in the background: one `$SHELL -ilc` for what only an interactive
    // login shell knows (`.zshrc`-exported PATH entries, version-manager shims).
    // Detached so launch never waits on someone's dotfiles; the floor above holds
    // until it lands, and holds permanently if the probe fails.
    //
    // Not under XCTest: the test bundle is hosted by this app, so this would spawn
    // a real login shell that lands at an arbitrary point and overwrites the cache
    // mid-test — `ShellEnvironmentTests` drives the probe against stub shells and
    // needs the cache to hold only what it put there.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
      Task.detached(priority: .utility) { await ShellEnvironment.refresh() }
    }

    // UI-test fixture mode only: park the pref-driven UI state (inspector open on the requested
    // section, diff viewer in the requested layout) in a known state before the first `AppStore`
    // seeds `activeInspectorSection` from `Defaults`. Inert in production — a real user never passes
    // the flag. See `UITestFixture.applyFixtureDefaults`.
    UITestFixture.applyFixtureDefaults()
  }

  var body: some Scene {
    // Value-based scene (issue #70): SwiftUI mints one window — and one fresh `AppStore` — per
    // `WindowSeed`, guaranteeing independent per-window state (and sidestepping the documented
    // `@StateObject`-in-`WindowGroup` cross-window sharing bug). ⌘N opens a new seed; the launch
    // window gets `.launch` (restores the saved selection).
    WindowGroup(for: WindowSeed.self) { $seed in
      RootWindow(seed: seed ?? .launch)
        .environmentObject(updater)
        .environmentObject(whatsNew)
    }
    // The taller single-row title bar (with AppKit centering the traffic lights in it — the
    // "breathing room" above/below the chrome, issue #23) comes from an EMPTY, AppKit-owned
    // `.unifiedCompact` toolbar set in `WindowBackgroundThemer`, NOT a SwiftUI `.windowToolbarStyle` +
    // `.toolbar` item. A SwiftUI-managed toolbar item forces the overflow `menuFormRepresentation`
    // recompute that caused the macOS-26 AppHangs (see WindowBackgroundThemer). The chrome lives in a
    // full-width `.left` titlebar accessory (never overflows).
    .commands { WorkroomCommands(updater: updater) }

    Settings {
      SettingsView()
        .environmentObject(updater)
    }

    // The system menu-bar item (issue #33) is hand-managed by `AppDelegate`'s `MenuBarController`
    // (an `NSStatusItem`), not a SwiftUI `MenuBarExtra`, so a click with no pending notifications can
    // simply focus the app instead of opening an empty popover — `MenuBarExtra` gives no hook to
    // intercept its click. See `MenuBarController`.
  }
}

/// Identity for a window scene (issue #70). `restore` is true only for the window SwiftUI brings up
/// at launch — combined with `ProjectStore.consumeInitialRestore()` that single window reapplies the
/// persisted selection; every ⌘N window carries a fresh `restore == false` seed and opens blank.
struct WindowSeed: Codable, Hashable {
  let id: UUID
  let restore: Bool
  /// The launch window: a fresh id allowed to restore the saved selection.
  static var launch: WindowSeed { WindowSeed(id: UUID(), restore: true) }
}

/// One window's root. The value-based `WindowGroup` gives each window its own `RootWindow`, so the
/// `@StateObject` below is a fresh per-window `AppStore` sharing the one `ProjectStore`. It injects
/// that store into the environment, exposes it to menu commands via `focusedSceneObject`, and
/// registers the window↔store pair with `WindowRegistry` (issue #70).
struct RootWindow: View {
  let seed: WindowSeed
  @StateObject private var store: AppStore

  init(seed: WindowSeed) {
    self.seed = seed
    let store = AppStore(projectStore: .shared)
    // Capture the current window's size ONCE, at this window's creation, so the new window can be
    // sized to match it before it's shown (issue #70). nil for the launch window.
    store.pendingInitialWindowSize = WindowRegistry.shared.preferredNewWindowSize
    // Only the launch window runs the What's-New auto-check (see RootView), so restored ⌘N windows
    // don't each pop the dialog.
    store.isRestoreWindow = seed.restore
    _store = StateObject(wrappedValue: store)
  }

  var body: some View {
    RootView()
      .environmentObject(store)
      .environmentObject(store.notifications)
      .environmentObject(store.terminals)
      .environmentObject(store.terminals.agentManager)
      .focusedSceneObject(store)
      .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
      .background(
        WindowAccessor { window in
          WindowRegistry.shared.register(window: window, store: store)
          store.attachWindow(window)
        }
      )
      .task { await store.bootstrap(restore: seed.restore) }
  }
}

/// Installs a local key monitor for ⌘1…⌘9 to focus the workroom's Nth terminal tab.
/// Handled here (rather than as menu items) so the shortcuts work without cluttering the
/// menu, and the monitor sees the keys before the focused terminal does.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private var monitor: Any?
  /// The global ⌘§ show/hide shortcut while enabled, else nil (issue #13). Registered/torn down by
  /// `updateGlobalHotkey()` to follow the `globalHotkey` setting.
  private var showHideHotkey: GlobalHotkey?
  /// The global ⌥§ quick-terminal shortcut while enabled, else nil (issue #39). Registered/torn down
  /// alongside `showHideHotkey` by `updateGlobalHotkey()` under the same `globalHotkey` setting.
  private var quickTerminalHotkey: GlobalHotkey?
  /// The quick terminal (issue #39) — a ~/ shell in its own chrome-less window. One persistent
  /// controller; its window/surface come and go as it's summoned/closed.
  private let quickTerminal = QuickTerminalController()
  /// Retains the `.showQuickTerminal` observer (posted by the toolbar button) for the app's lifetime.
  private var quickTerminalObserver: NSObjectProtocol?
  /// Observes the `globalHotkey` setting so toggling it takes effect immediately.
  private var hotkeyObservation: Task<Void, Never>?
  /// The system menu-bar item (issue #33) — an `NSStatusItem` owned here so a click can branch on the
  /// notification count (open the list, or just focus the app when there's nothing pending). Retained
  /// for the app's lifetime; created in `applicationDidFinishLaunching`.
  private var menuBarController: MenuBarController?
  /// Catches SIGTERM so a signalled quit stops run commands gracefully (issue #7). Retained so the
  /// `DispatchSource` stays alive for the process's lifetime.
  private var sigtermSource: DispatchSourceSignal?

  deinit { hotkeyObservation?.cancel() }

  /// The store a shortcut in the key monitor below may act on: the one owning the window the event is
  /// actually headed for, and only while that window has no command-palette dialog up.
  ///
  /// Deliberately **not** `WindowRegistry.keyStore`. That resolves
  /// `store(for: NSApp.keyWindow) ?? lastActiveStore ?? allStores.first` (WindowRegistry.swift:113),
  /// so it falls back *past* a foreign key window — which is right for its other three callers (the
  /// menu-bar popover, where `store(for:)` is legitimately nil; notification-click routing; the
  /// terminal context menu) but wrong here: it fires ⌘R / ⌘1-9 / ⌥⌘S into a *background* workroom
  /// whenever a sheet, Settings, About, Sparkle's updater or the quick terminal is key. Those windows
  /// are all unregistered, so `store(for:)` returns nil for them with no extra checks — which is what
  /// lets every branch below simply no-op instead of needing a swallow-with-allowlist (an allowlist
  /// was the first design; it was the sole source of a ⌘⌫ gap, broken ⌘V on non-Latin layouts, and a
  /// ⌘↑/⌘↓ collision with the Scroll to Top/Bottom menu items).
  /// `registry` is injectable purely so tests don't have to mutate the `WindowRegistry.shared`
  /// singleton — registering on it leaks window registrations into later tests unless every test pairs
  /// its cleanup in tearDown. Production always takes the default.
  @MainActor static func shortcutStore(
    for window: NSWindow?, in registry: WindowRegistry = .shared
  ) -> AppStore? {
    guard let store = registry.store(for: window), store.activePicker == nil else { return nil }
    return store
  }

  /// Whether `window` is one of ours *and* has a command-palette dialog open — the case where a
  /// shortcut must be actively swallowed rather than merely no-op'd, because the branch doesn't
  /// consult a store at all (⌘` window cycling).
  @MainActor static func hasModalPicker(
    _ window: NSWindow?, in registry: WindowRegistry = .shared
  ) -> Bool {
    registry.store(for: window)?.activePicker != nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Disable native macOS window tabbing. It tabs whole app windows (each with its own
    // sidebar) — a level above our per-workroom terminal tabs and a poor fit for a
    // single-window, sidebar-driven app. Off, it also drops the auto-injected
    // "Show/Hide Tab Bar" + "Show All Tabs" View-menu items that otherwise read as if they
    // control the terminal tabs.
    NSWindow.allowsAutomaticWindowTabbing = false

    // Receive notification clicks (authorization is requested lazily on first post).
    UNUserNotificationCenter.current().delegate = self

    // Install the menu-bar item (issue #33). Creating it here also forces `WindowRegistry.shared`
    // into existence early, so its key-window observer is live before the first window appears.
    menuBarController = MenuBarController(registry: .shared)

    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
      // ⌘W closes the quick terminal (issue #39) when its window is key. The menu's "Close Terminal"
      // ⌘W targets the main window's tabs and would otherwise win, so catch it here (like ⌘R / ⌘1–9
      // above) and route to the quick-terminal window — its delegate (QuickTerminalController) tears
      // the surface down. Gated on the key window being a QuickTerminalWindow, so ⌘W still closes a
      // main-window terminal tab everywhere else.
      if flags == .command, event.charactersIgnoringModifiers == "w",
        let quickTerminalWindow = (event.window ?? NSApp.keyWindow) as? QuickTerminalWindow
      {
        quickTerminalWindow.performClose(nil)
        return nil
      }
      // ⌘W on an auxiliary window (Settings, About) — a window with no AppStore (not a workroom
      // window). The menu's "Close Terminal" owns ⌘W app-wide but is disabled there (no focused
      // terminal), so ⌘W would otherwise just beep. Close the window, as the standard File ▸ Close
      // would. Workroom windows (store != nil) fall through so their "Close Terminal" still fires.
      if flags == .command, event.charactersIgnoringModifiers == "w",
        let keyWindow = event.window ?? NSApp.keyWindow,
        MainActor.assumeIsolated({ WindowRegistry.shared.store(for: keyWindow) }) == nil
      {
        keyWindow.performClose(nil)
        return nil
      }
      // The window this event is headed for, resolved once for every branch below. `event.window` is
      // nil for ⌘ key-equivalents, hence the `?? NSApp.keyWindow` — same idiom as the two ⌘W branches
      // above. Those two run BEFORE this point on purpose: ⌘W acts on the modal in front (a sheet, the
      // quick terminal), not on the window behind it, so it must keep working while a dialog is up.
      let window = event.window ?? NSApp.keyWindow
      // ⌘` / ⇧⌘`: cycle key focus through the app's windows incl. the quick terminal (issue #87) —
      // the standard "Move focus to next window" shortcut. Caught here, like ⌘1–9, so the focused
      // terminal surface doesn't swallow the backtick as input. keyCode 50 is the grave (`) key,
      // matched by code (not char) so it's layout-stable and ⇧⌘` reads as backward despite the "~".
      // Consumed regardless (window cycling has no terminal use we want to preserve).
      if event.keyCode == 50, flags == .command || flags == [.command, .shift] {
        // Alone among the branches here this one consults no store, so `shortcutStore` returning nil
        // wouldn't stop it — swallow explicitly while a dialog is up.
        if MainActor.assumeIsolated({ Self.hasModalPicker(window) }) { return nil }
        let forward = flags == .command
        MainActor.assumeIsolated { WindowRegistry.shared.cycleWindows(forward: forward) }
        return nil
      }
      // ⌘1–9: focus the Nth tab (caught here so it fires before the terminal swallows the digit).
      if flags == .command, let chars = event.charactersIgnoringModifiers,
        let digit = Int(chars), (1...9).contains(digit)
      {
        Task { @MainActor in Self.shortcutStore(for: window)?.focusTerminalTab(at: digit - 1) }
        return nil  // consume so it doesn't reach the terminal
      }
      // ⌥⌘1–9: switch to the Nth workroom tab (issue #23), the workroom-level counterpart to ⌘1–9.
      // Caught here (like ⌘1–9) so it fires before the terminal. Consumed only when there's an Nth tab
      // to switch to (focusWorkroomTab returns true), so ⌥⌘digit still reaches the terminal otherwise.
      // (Digit chars don't collide with the ⌥⌘R / arrow-key checks below.)
      if flags == [.command, .option], let chars = event.charactersIgnoringModifiers,
        let digit = Int(chars), (1...9).contains(digit),
        MainActor.assumeIsolated({
          Self.shortcutStore(for: window)?.focusWorkroomTab(at: digit - 1) ?? false
        })
      {
        return nil
      }
      // ⌘R: run-or-focus the selected workroom's run command (issue #7) — caught here so it fires
      // before the terminal swallows it, like ⌘1–9. Consumed unconditionally (⌘R has no terminal use
      // we want to preserve); a no-op when nothing's selected, but no command configured now opens the
      // Project Settings sheet with a warning instead of doing nothing (issue #127).
      if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "r" {
        Task { @MainActor in Self.shortcutStore(for: window)?.runOrFocusRunCommand() }
        return nil
      }
      // ⇧⌘R: stop the selected workroom's run command if it's running (issue #7). Caught here (not
      // just the menu key-equivalent) so it fires reliably before the terminal, like ⌘R. No-op when
      // nothing's running; consumed regardless (it's reserved in `isAppShortcut` anyway).
      if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "r" {
        Task { @MainActor in Self.shortcutStore(for: window)?.stopSelectedRunCommand() }
        return nil
      }
      // ⌥⌘R: restart the selected workroom's run command if it's running (issue #7). Caught here for
      // reliability, like ⌘R/⇧⌘R. No-op when nothing's running. (The arrow-key checks below match by
      // keyCode, so "r" doesn't collide with tab/pane navigation.)
      if flags == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "r" {
        Task { @MainActor in Self.shortcutStore(for: window)?.restartSelectedRunCommand() }
        return nil
      }
      // ⌥⌘←/→: previous/next terminal tab (issue #29). Caught here like ⌘1–9 so it fires before the
      // terminal; consumed when it switches a tab, and reserved in `isAppShortcut` anyway so it never
      // reaches the terminal as input. (⌥⌘↑/↓ are unbound — they pass through to the terminal.)
      if flags == [.command, .option], event.keyCode == 123 || event.keyCode == 124,
        MainActor.assumeIsolated({
          Self.shortcutStore(for: window)?.cycleTerminalTab(forward: event.keyCode == 124) ?? false
        })
      {
        return nil
      }
      // ⇧⌥⌘←/→: previous/next workroom tab (issue #29), the workroom-level counterpart to ⌥⌘←/→.
      // Consumed when it switches; reserved in `isAppShortcut` anyway, like ⌥⌘←/→.
      if flags == [.command, .option, .shift], event.keyCode == 123 || event.keyCode == 124,
        MainActor.assumeIsolated({
          Self.shortcutStore(for: window)?.cycleWorkroomTab(forward: event.keyCode == 124) ?? false
        })
      {
        return nil
      }
      // ⌃⌘arrows: move focus between split panes (issue #3) — moved off ⌥⌘arrows, which now cycles
      // terminal tabs (issue #29). Consumed only when focus actually moves, so the keys still reach
      // the terminal when there's no split to navigate. (Virtual keycodes: left 123 / right 124 /
      // down 125 / up 126.)
      let arrows: [UInt16: PaneDirection] = [123: .left, 124: .right, 125: .down, 126: .up]
      if flags == [.command, .control], let direction = arrows[event.keyCode],
        MainActor.assumeIsolated({ Self.shortcutStore(for: window)?.focusPane(direction) ?? false })
      {
        return nil
      }
      // ⌃⌘S: toggle the Projects sidebar (issue #128). Caught here — not just left to the menu's
      // key-equivalent — so it fires reliably even with a focused TUI (like ⌘1-9 above).
      if flags == [.command, .control], event.charactersIgnoringModifiers?.lowercased() == "s" {
        Task { @MainActor in Self.shortcutStore(for: window)?.sidebarVisible.toggle() }
        return nil
      }
      // ⌥⌘S: the OS-standard "Toggle Sidebar" shortcut (Finder, Notes, etc. — AppKit's
      // `toggleSidebar:` first-responder action). We don't bind it to our own "Projects" menu item
      // (that's ⌃⌘S, above), but RootView's NavigationSplitView still keeps a REAL native sidebar
      // column, forced `.detailOnly`, purely for toolbar/title-bar layering (see RootView) — and
      // AppKit auto-wires ITS default toggle to that column regardless of what our menu does. Left
      // alone, ⌥⌘S pops that column open: truly empty (`Color.clear.frame(width: 0)`), which is the
      // "opens the sidebar as a thinner bar, with nothing in it" bug (issue #128). Catching it here
      // and consuming the event stops it from ever reaching AppKit's responder chain; since users
      // expect ⌥⌘S to mean "toggle the sidebar" regardless of which one, map it onto our real
      // `sidebarVisible` toggle rather than just swallowing it.
      if flags == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "s" {
        Task { @MainActor in Self.shortcutStore(for: window)?.sidebarVisible.toggle() }
        return nil
      }
      // ⌥⌘B: secondary "Projects" sidebar toggle, mirroring ⌃⌘S above — caught here (not just left
      // to a menu key-equivalent) so it fires reliably with a focused TUI too (issue #128).
      if flags == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "b" {
        Task { @MainActor in Self.shortcutStore(for: window)?.sidebarVisible.toggle() }
        return nil
      }
      return event
    }

    // ⌘-click-to-open-in-editor and copy-on-select now live inside GhosttySurfaceView (we own the
    // NSView), so the SwiftTerm-era NSEvent monitors that worked around its public-not-open methods
    // are gone.

    // Global ⌘§ to show/hide Workroom from anywhere (issue #13), gated by the `globalHotkey`
    // setting. Register now, then re-run on each change of *that* key (scoped, unlike the old
    // blanket didChangeNotification observer) so toggling the setting registers/unregisters it live.
    updateGlobalHotkey()
    hotkeyObservation = Task { @MainActor [weak self] in
      for await _ in Defaults.updates(.globalHotkey, initial: false) {
        self?.updateGlobalHotkey()
      }
    }

    // The main-toolbar Quick-Terminal button (issue #39) posts this; the controller lives here, out
    // of the SwiftUI view's reach. The ⌥§ hotkey calls the controller directly (see updateGlobalHotkey).
    quickTerminalObserver = NotificationCenter.default.addObserver(
      forName: .showQuickTerminal, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.quickTerminal.show() }
    }

    installSigtermHandler()
  }

  /// Stop run commands gracefully on SIGTERM, then exit. macOS routes only a real ⌘Q / Quit
  /// Apple-event through `applicationShouldTerminate`, NOT a signal — so without this, a `kill`,
  /// `pkill`, or `make app-run` replacing the dev instance would skip the graceful stop and orphan
  /// the dev server (a PTY hangup Puma ignores → "A server is already running" later, issue #7). A
  /// `DispatchSource` handler runs on the main queue, so it can safely touch the store (a raw signal
  /// handler can't); `SIG_IGN` disables the default terminate so the source receives it instead. We
  /// `exit()` rather than `NSApp.terminate` to avoid re-entering the quit confirmation, and only
  /// after the run commands are gone — the OS then reclaims libghostty as on any quit. SIGKILL /
  /// force-quit still can't be caught by anything.
  private func installSigtermHandler() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
      // The source fires on the main queue, so we're main-actor-isolated in practice (same pattern
      // as the NSEvent monitor above) — assert it so we can touch the store synchronously.
      MainActor.assumeIsolated {
        WindowRegistry.shared.gracefullyStopAllWindows(timeout: 4) {
          exit(EXIT_SUCCESS)
        }
      }
    }
    source.resume()
    sigtermSource = source
  }

  /// Register or tear down the global hotkeys — ⌘§ show/hide (issue #13) and ⌥§ quick terminal
  /// (issue #39) — to match the `globalHotkey` setting. Idempotent — only (un)registers when the
  /// desired state differs from the current one — so it's safe to call on launch and on every change.
  /// Carbon's RegisterEventHotKey is system-wide and needs no permission; the key/modifiers live in
  /// `GlobalHotkey.commandSection` / `.optionSection` (each with a distinct hotkey id so they coexist).
  private func updateGlobalHotkey() {
    // The "Workroom Dev" build runs alongside the release build, and a Carbon hotkey is
    // system-wide — two instances registering the same combo would fight over it. The release build
    // owns the global hotkeys; the Debug build never claims them (so ⌥§ is button-only in Debug).
    // Compiling the body out (rather than an early `return`) keeps both configs warning-clean and
    // covers launch + the Settings toggle + the `globalHotkey` observer, which all route through here.
    #if !DEBUG
      if Defaults[.globalHotkey] {
        if showHideHotkey == nil {
          showHideHotkey = GlobalHotkey.commandSection { AppDelegate.toggleAppVisibility() }
        }
        if quickTerminalHotkey == nil {
          quickTerminalHotkey = GlobalHotkey.optionSection { [weak self] in
            MainActor.assumeIsolated { self?.quickTerminal.toggle() }
          }
        }
      } else {
        showHideHotkey = nil  // GlobalHotkey.deinit unregisters
        quickTerminalHotkey = nil
      }
    #endif
  }

  /// Show/hide Workroom for the global hotkey: hide when we're frontmost, otherwise unhide and pull
  /// the app forward. Runs on the main thread (Carbon delivers hot-key events there).
  private static func toggleAppVisibility() {
    if NSApp.isActive {
      NSApp.hide(nil)
    } else {
      NSApp.unhide(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  /// A notification was clicked: route to its terminal (the ids ride in `userInfo`). Reuses the
  /// same `openTerminal` path as an in-app panel tap, so there's one routing implementation.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    if let targetID = info["targetID"] as? String {
      let tabID = (info["tabID"] as? String).flatMap(UUID.init(uuidString:))
      let notifID = (info["notifID"] as? String).flatMap(UUID.init(uuidString:))
      Task { @MainActor in
        // Route to the window that owns this tab (tab ids are unique across windows, issue #70),
        // falling back to the key window; bring it forward, then open the terminal there.
        let registry = WindowRegistry.shared
        let store = tabID.flatMap { registry.ownerOf(tabID: $0) } ?? registry.keyStore
        store?.hostWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store?.openTerminal(targetID: targetID, tabID: tabID, notifID: notifID)
      }
    }
    completionHandler()
  }

  /// Confirm before quitting unless the user turned it off (`confirmOnQuit`, default on): quitting
  /// tears down every terminal (and anything running in them) at once, with no undo. The dialog's
  /// "Don't ask me again" checkbox turns the setting off (same key as the menu/Settings toggles).
  /// `@MainActor` so the `NSAlert` (a main-actor AppKit type) call is clean — AppKit always invokes
  /// this on the main thread. Closing a window doesn't quit the app, so this fires only on a quit.
  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // UI-test fixture quits cleanly (no modal, no waiting) so XCUITest teardown never blocks.
    if UITestFixture.isActive { return .terminateNow }
    if Defaults[.confirmOnQuit] {
      let alert = NSAlert()
      alert.messageText = "Quit Workroom?"
      alert.informativeText = "Quitting closes all terminals and stops any running processes."
      alert.addButton(withTitle: "Quit")
      alert.addButton(withTitle: "Cancel")
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Don't ask me again"
      let shouldQuit = alert.runModal() == .alertFirstButtonReturn
      // Ticking the box stops future confirmations — whether they Quit or Cancel, the checkbox
      // means "stop asking". Writes the same key the menu/Settings toggles bind to.
      if alert.suppressionButton?.state == .on {
        Defaults[.confirmOnQuit] = false
      }
      guard shouldQuit else { return .terminateCancel }
    }
    return stopRunCommandsThenTerminate(sender)
  }

  /// Ctrl-C any live run commands and let them exit before the process dies, so dev servers clean up
  /// (release their port + pidfile) instead of being orphaned by the OS hangup on exit — a SIGHUP
  /// that Puma ignores, surfacing as "A server is already running" on the next launch (issue #7).
  /// Sends only key events — never frees a surface — so the no-mass-free-on-quit rationale in
  /// `applicationWillTerminate` still holds. Bounded so a wedged server can't block the quit.
  @MainActor
  private func stopRunCommandsThenTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply
  {
    let registry = WindowRegistry.shared
    // Mark the app as terminating so a window's own close handler doesn't also prompt/stop (#70).
    registry.isTerminating = true
    guard registry.hasAnyLiveRunCommand else { return .terminateNow }
    // Stop every window's run commands, not just the focused one's.
    registry.gracefullyStopAllWindows(timeout: 5) {
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Reactivation (Dock click, or clicking a notification while the app is inactive): bring an
  /// EXISTING window forward rather than letting AppKit open a brand-new one (issue #70). A
  /// value-based `WindowGroup` otherwise spawns a fresh window on reopen — so a notification click
  /// would pop a new window instead of returning to the window where the event happened (the
  /// notification handler then brings that specific owner window forward). Only ask AppKit to create
  /// a window when none exists.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    let registry = WindowRegistry.shared
    if let window = registry.lastActiveStore?.hostWindow ?? registry.allStores.first?.hostWindow {
      window.makeKeyAndOrderFront(nil)
      return false
    }
    return true
  }

  /// Deliberately does NOT tear down libghostty on quit. Freeing surfaces (or the app) while their
  /// IO/render is still active races libghostty's surface teardown and crashes — EXC_BAD_ACCESS in
  /// `Surface.deinit`, or `os_unfair_lock` corruption in `Surface.handleMessage` — most readily when a
  /// run command's dev server (issue #7) is still busy. The process is exiting anyway: the OS reclaims
  /// libghostty's memory and closes the PTYs, so every child shell/server gets SIGHUP exactly as a
  /// manual `ghostty_surface_free` would deliver. (The per-workroom delete path still reaps a single
  /// steady-state surface — that's not a mass-free racing termination.)
  ///
  /// Run commands are the exception that SIGHUP doesn't safely cover: a dev server like Puma ignores
  /// the hangup and is left orphaned on its port/pidfile. So `applicationShouldTerminate` Ctrl-Cs
  /// every live run command and waits for it to exit *before* returning — sending key events only,
  /// never freeing a surface, so the no-mass-free rationale above still holds (issue #7, Option B).
  @MainActor
  func applicationWillTerminate(_ notification: Notification) {}
}

/// Whether the focused window has a usable terminal target selected (a root or a workroom,
/// and not a missing directory). Published via `focusedSceneValue` (see RootView) so menu
/// commands can enable/disable against it — a Commands body doesn't re-evaluate when the
/// shared store changes directly, but it does track focused values.
struct WorkroomSelectedKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected workroom has at least one open terminal — published by
/// WorkroomTerminalsView (which observes the sessions), so "Close Terminal" can disable
/// when there's nothing to close.
struct HasTerminalKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether there are any pending notifications — published by RootView (which observes the
/// store), so "Next Notification" can disable when the history is empty.
struct HasNotificationsKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the app has at least one project — published by RootView, so "New Workroom" (⌘N, issue
/// #81) disables when there's nothing to pick (a fresh install): ⌘N is then a silent no-op rather
/// than opening an empty dialog.
struct HasProjectsKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether back/forward navigation can move (issue #26) — published by RootView, so the Go-menu
/// Back/Forward commands disable at the ends of history.
struct CanNavigateBackKey: FocusedValueKey {
  typealias Value = Bool
}

struct CanNavigateForwardKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected workroom's project has a non-empty run command (issue #7) — published by
/// RootView (observes the store), so the Run menu item disables when there's nothing to run.
struct HasRunCommandKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected workroom's run command is currently running (issue #7) — published by
/// RootView, so the menu shows Run vs Stop/Restart enablement.
struct RunCommandActiveKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether any run terminal exists to jump to (issue #7) — published by RootView, so the
/// View ▸ Run Terminal item disables when there's none.
struct HasRunTerminalKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected target has more than one terminal tab (issue #29) — published by
/// WorkroomTerminalsView, so the Go-menu Previous/Next Terminal Tab items disable when there's
/// nothing to cycle between.
struct MultipleTerminalTabsKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether there's more than one workroom tab (issue #29) — published by RootView, so the Go-menu
/// Previous/Next Workroom Tab items disable when there's nothing to cycle between.
struct MultipleWorkroomTabsKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected target can be opened in an external editor — published by RootView, so the
/// Go-menu "Open in…" item (⌘O) disables when there's no selection / a missing dir / no editor.
struct CanOpenInEditorKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the focused target's terminal split is currently visible (issue #83) — published by
/// WorkroomTerminalsView, which mounts only in the single-workroom path and only once a blocking
/// setup script is dismissed, so "Resize Splits Evenly" enables only when a real terminal split is
/// on screen (never behind a setup overlay, never in workroom-into-workroom split mode).
struct TerminalSplitVisibleKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether the selected workroom is part of a visible workroom-into-workroom split (issue #83) —
/// published by RootView, so "Resize Workroom Splits Evenly" enables only when it's a live member.
struct WorkroomSplitVisibleKey: FocusedValueKey {
  typealias Value = Bool
}

/// Whether a modal presentation owns the focused window (`AppStore.hasModalPresentation`). Backs the
/// menu items that have no other enablement boolean to fold it into — the `@Default`-bound toggles
/// (⌘B, ⌥⌘C/F/Y/P, ⇧⌘K, ⇧⌘L) and Quick Terminal, which is "always enabled" and whose ⌥§ carries no
/// ⌘ at all, so nothing in the key monitor would ever gate it.
struct ModalPresentedKey: FocusedValueKey {
  typealias Value = Bool
}

extension FocusedValues {
  var workroomSelected: Bool? {
    get { self[WorkroomSelectedKey.self] }
    set { self[WorkroomSelectedKey.self] = newValue }
  }
  var hasTerminal: Bool? {
    get { self[HasTerminalKey.self] }
    set { self[HasTerminalKey.self] = newValue }
  }
  var hasNotifications: Bool? {
    get { self[HasNotificationsKey.self] }
    set { self[HasNotificationsKey.self] = newValue }
  }
  var hasProjects: Bool? {
    get { self[HasProjectsKey.self] }
    set { self[HasProjectsKey.self] = newValue }
  }
  var canNavigateBack: Bool? {
    get { self[CanNavigateBackKey.self] }
    set { self[CanNavigateBackKey.self] = newValue }
  }
  var canNavigateForward: Bool? {
    get { self[CanNavigateForwardKey.self] }
    set { self[CanNavigateForwardKey.self] = newValue }
  }
  var hasRunCommand: Bool? {
    get { self[HasRunCommandKey.self] }
    set { self[HasRunCommandKey.self] = newValue }
  }
  var runCommandActive: Bool? {
    get { self[RunCommandActiveKey.self] }
    set { self[RunCommandActiveKey.self] = newValue }
  }
  var hasRunTerminal: Bool? {
    get { self[HasRunTerminalKey.self] }
    set { self[HasRunTerminalKey.self] = newValue }
  }
  var multipleTerminalTabs: Bool? {
    get { self[MultipleTerminalTabsKey.self] }
    set { self[MultipleTerminalTabsKey.self] = newValue }
  }
  var multipleWorkroomTabs: Bool? {
    get { self[MultipleWorkroomTabsKey.self] }
    set { self[MultipleWorkroomTabsKey.self] = newValue }
  }
  var canOpenInEditor: Bool? {
    get { self[CanOpenInEditorKey.self] }
    set { self[CanOpenInEditorKey.self] = newValue }
  }
  var modalPresented: Bool? {
    get { self[ModalPresentedKey.self] }
    set { self[ModalPresentedKey.self] = newValue }
  }
  var terminalSplitVisible: Bool? {
    get { self[TerminalSplitVisibleKey.self] }
    set { self[TerminalSplitVisibleKey.self] = newValue }
  }
  var workroomSplitVisible: Bool? {
    get { self[WorkroomSplitVisibleKey.self] }
    set { self[WorkroomSplitVisibleKey.self] = newValue }
  }
}

/// Menu-bar commands + keyboard shortcuts. They act on the shared store so they work
/// regardless of which pane has focus.
struct WorkroomCommands: Commands {
  @ObservedObject var updater: Updater
  /// The focused window's store (issue #70). Optional — nil when no Workroom window is key, in which
  /// case actions no-op and toggle bindings read false.
  ///
  /// It does **NOT** go nil merely because a dialog is up, contrary to what this comment used to
  /// claim: verified on the real build, with the Add Project sheet attached every File-menu item still
  /// read `enabled=true` and ⌘T created a second terminal tab behind it. That is why enablement has to
  /// AND in `AppStore.hasModalPresentation` explicitly (see `modalBlocked` and `MenuStateValues`).
  /// `@FocusedObject`
  /// re-evaluates this `Commands` body when the focused store changes, so checkmarks like Projects
  /// track the focused window's `sidebarVisible` live (the role the old `@ObservedObject` played).
  @FocusedObject private var store: AppStore?
  @FocusedValue(\.workroomSelected) private var workroomSelected
  @FocusedValue(\.hasTerminal) private var hasTerminal
  @FocusedValue(\.hasNotifications) private var hasNotifications
  @FocusedValue(\.hasProjects) private var hasProjects
  @FocusedValue(\.canNavigateBack) private var canNavigateBack
  @FocusedValue(\.canNavigateForward) private var canNavigateForward
  @FocusedValue(\.hasRunCommand) private var hasRunCommand
  @FocusedValue(\.runCommandActive) private var runCommandActive
  @FocusedValue(\.hasRunTerminal) private var hasRunTerminal
  @FocusedValue(\.multipleTerminalTabs) private var multipleTerminalTabs
  @FocusedValue(\.multipleWorkroomTabs) private var multipleWorkroomTabs
  @FocusedValue(\.canOpenInEditor) private var canOpenInEditor
  @FocusedValue(\.terminalSplitVisible) private var terminalSplitVisible
  @FocusedValue(\.workroomSplitVisible) private var workroomSplitVisible
  @FocusedValue(\.modalPresented) private var modalPresented
  // Shared with RootView's inspector + toolbar toggle (same key) so all three stay in sync.
  @Default(.showInspector) private var showInspector
  // Same key as the Settings checkbox so the two stay in sync; GhosttySurfaceView reads it
  // on each selection, so toggling here takes effect on the next drag.
  @Default(.copyOnSelect) private var copyOnSelect
  // Gate the quit-confirmation alert. Same key as the Settings checkbox so the two stay in sync;
  // AppDelegate reads it in applicationShouldTerminate.
  @Default(.confirmOnQuit) private var confirmOnQuit
  // Gate the close-terminal confirmation (default on). Same key as the Settings checkbox and the
  // dialog's "Don't ask me again", so the File-menu checkmark reflects — and drives — all three;
  // AppStore reads it in requestCloseTerminalTab.
  @Default(.confirmOnCloseTerminal) private var confirmOnCloseTerminal
  // Drives the quick dark/light toggle (⌘⇧L, issue #57). RootView's `.onChange(of: theme)` applies
  // it through the single theme chokepoint; same key as the sidebar's 3-state cycle button.
  @Default(.theme) private var theme
  /// Opens a new Workroom window (issue #70) — a fresh `WindowSeed` so the window starts blank.
  @Environment(\.openWindow) private var openWindow

  /// A `Binding<Bool>` onto a `Bool` property of the focused store — reads false and ignores writes
  /// when no window is focused (issue #70). Backs the menu toggles that drive per-window state.
  /// True while a modal presentation owns the focused window. Items whose enablement flows through a
  /// `MenuStateValues` boolean already have this ANDed in at the publication site; the ones below have
  /// no such boolean (the `@Default`-bound View-menu toggles, and Quick Terminal, which is documented
  /// "always enabled"), so they AND it in here. Without this their key equivalents fire straight
  /// through a dialog — verified: ⌘T behind the Add Project sheet really did open a terminal tab.
  private var modalBlocked: Bool { modalPresented == true }

  private func storeFlag(_ keyPath: ReferenceWritableKeyPath<AppStore, Bool>) -> Binding<Bool> {
    Binding(
      get: { store?[keyPath: keyPath] ?? false },
      set: { store?[keyPath: keyPath] = $0 })
  }

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      // Sparkle update check, sitting directly beneath "About Workroom". Disabled while a check is
      // already running. See Core/Updater.swift.
      Button("Check for Updates…") { updater.checkForUpdates() }
        .disabled(!updater.canCheckForUpdates)
    }

    // App menu: the "Install workroom Command" + "Keyboard Shortcuts…" items, sitting just below
    // Settings… and above Services. Anchored `before: .systemServices`, NOT `after: .appSettings`:
    // the `Settings` scene injects the "Settings…" item at the END of the appSettings group, so
    // `after: .appSettings` lands ABOVE Settings… — anchoring before Services is the documented way
    // to sit just below it. Keyboard Shortcuts has no accelerator (a ⌘-key would need reserving from
    // the terminal in GhosttySurfaceView.isAppShortcut; the menu item is discovery enough) and posts
    // a notification RootView observes to present the sheet (a menu command can't anchor one — same
    // pattern as Theme… below).
    CommandGroup(before: .systemServices) {
      // App menu: symlink the bundled CLI into the user's PATH (like VS Code's "Install 'code'
      // command"). Prompts for admin only if the target dir needs it. See CommandLineInstaller.
      Button("Install ‘workroom’ Command in PATH…") {
        Task { await CommandLineInstaller.runFromMenu() }
      }
      Button("Keyboard Shortcuts…") {
        NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
      }
    }

    // Sit the quit-confirmation toggle just above Quit (default on): `.appVisibility` is the
    // Hide/Show All group, the last thing before Quit, so `after:` lands between it and Quit. A
    // divider separates it from that group; mirrored by the Settings checkbox.
    CommandGroup(after: .appVisibility) {
      Divider()
      Toggle("Confirm Before Quitting", isOn: $confirmOnQuit)
    }

    // Replace the default "Show/Hide Sidebar" with a clearer "Projects" label — it's the projects
    // sidebar. A `Toggle` (not a plain `toggleSidebar` Button) so the menu shows a checkmark when the
    // sidebar is visible; it binds `store.sidebarVisible`, which drives the split view's column
    // visibility. Keeps the conventional ⌃⌘S shortcut.
    CommandGroup(replacing: .sidebar) {
      Toggle("Projects", isOn: storeFlag(\.sidebarVisible))
        .keyboardShortcut("s", modifiers: [.command, .control])
        .disabled(modalBlocked)
    }

    CommandGroup(after: .sidebar) {
      // View menu: toggle the right-hand inspector panel as a whole (⌘B), independent of which
      // section is active — the Changes/Files/History/Pull Request toggles below select a section
      // AND open the inspector; this one just shows/hides whatever section was last active.
      Toggle("Inspector", isOn: $showInspector)
        .keyboardShortcut("b", modifiers: [.command])
        .disabled(modalBlocked)

      // View menu: reveal the Changes view. Changes and Pull Request share the **Changes** activity-bar
      // pane (a stack), so "showing" Changes means selecting that pane, opening the inspector, and
      // expanding the Changes sub-section; the checkmark is on only when all three hold. Turning it off
      // just collapses the sub-section (the pane stays open if Pull Request is still showing).
      Toggle(
        "Changes",
        isOn: Binding(
          get: {
            showInspector && store?.activeInspectorSection == .changes
              && !(store?.changesSectionCollapsed ?? true)
          },
          set: { on in
            if on {
              store?.activeInspectorSection = .changes
              showInspector = true
              store?.changesSectionCollapsed = false
            } else {
              store?.changesSectionCollapsed = true
            }
          })
      )
      .keyboardShortcut("c", modifiers: [.command, .option])
      .disabled(modalBlocked)

      // View menu: reveal the Files view (the repo file tree) — its own single-section activity-bar
      // pane, so showing it selects the Files pane and opens the inspector; turning it off hides the
      // pane (Files has no sub-section to collapse). Assigning `activeInspectorSection` in both
      // branches forces the bar + inspector to re-render synchronously (see `AppStore.apply`).
      Toggle(
        "Files",
        isOn: Binding(
          get: { showInspector && store?.activeInspectorSection == .files },
          set: { on in
            store?.activeInspectorSection = .files
            showInspector = on
          })
      )
      .keyboardShortcut("f", modifiers: [.command, .option])
      .disabled(modalBlocked)

      // View menu: reveal the History view (the commit log) — its own single-section activity-bar
      // pane, like Files. (⌥⌘Y — ⌥⌘H is macOS "Hide Others".)
      Toggle(
        "History",
        isOn: Binding(
          get: { showInspector && store?.activeInspectorSection == .history },
          set: { on in
            store?.activeInspectorSection = .history
            showInspector = on
          })
      )
      .keyboardShortcut("y", modifiers: [.command, .option])
      .disabled(modalBlocked)

      // View menu: reveal the Pull Request view — the second sub-section of the Changes pane, so it
      // selects that pane, opens the inspector, and expands the Pull Request sub-section.
      Toggle(
        "Pull Request",
        isOn: Binding(
          get: {
            showInspector && store?.activeInspectorSection == .changes
              && !(store?.prSectionCollapsed ?? true)
          },
          set: { on in
            if on {
              store?.activeInspectorSection = .changes
              showInspector = true
              store?.prSectionCollapsed = false
            } else {
              store?.prSectionCollapsed = true
            }
          })
      )
      .keyboardShortcut("p", modifiers: [.command, .option])
      .disabled(modalBlocked)

      // Theme chooser (issue #36). A menu command can't anchor a popover, so it posts a
      // notification RootView observes to present the picker as a sheet.
      Divider()
      Button("Theme…") { NotificationCenter.default.post(name: .showThemePicker, object: nil) }
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .disabled(modalBlocked)

      // Quick dark/light toggle (issue #57): flip the *currently visible* appearance. From System
      // it resolves the live OS appearance first, so it always inverts what's on screen and lands on
      // a forced mode — repeat presses then flip cleanly (the sidebar button still cycles back to
      // System). Title names the destination so the menu reads as the action it performs.
      Button(theme.toggledLightDark.label + " Mode") {
        theme = theme.toggledLightDark
      }
      .keyboardShortcut("l", modifiers: [.command, .shift])
      .disabled(modalBlocked)

      // Split the focused pane with a new terminal beside it (issue #3): ⌘D right, ⇧⌘D down; left/up
      // have no standard key, so they're menu-only.
      Divider()
      Button("Split Right") { store?.splitFocusedRight() }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(hasTerminal != true)
      Button("Split Left") { store?.splitFocusedLeft() }
        .disabled(hasTerminal != true)
      Button("Split Down") { store?.splitFocusedDown() }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(hasTerminal != true)
      Button("Split Up") { store?.splitFocusedUp() }
        .disabled(hasTerminal != true)

      // Resize a split's panes back to even (issue #83): one item per split kind, each enabled only
      // when that kind of split is actually on screen (a focused terminal split / the selected
      // workroom inside a workroom split). Menu-only, like Split Left/Up.
      Divider()
      Button("Resize Splits Evenly") { store?.equalizeFocusedSplit() }
        .disabled(terminalSplitVisible != true)
      Button("Resize Workroom Splits Evenly") { store?.equalizeWorkroomSplit() }
        .disabled(workroomSplitVisible != true)

      // Separate our View items from the system "Enter Full Screen" item that follows.
      Divider()
    }

    // Dedicated Run menu (issue #7): the run command's lifecycle. The keys (⌘R / ⇧⌘R / ⌥⌘R) are
    // handled by the AppDelegate monitor so they fire before the terminal; shown here for
    // discoverability (the monitor consumes them, so no double-fire). Run is disabled when no command
    // is configured; Restart/Stop only while it's running.
    CommandMenu("Run") {
      Button("Run") { store?.runOrFocusRunCommand() }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(hasRunCommand != true)
      Button("Restart") { store?.restartSelectedRunCommand() }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .disabled(runCommandActive != true)
      Button("Stop") { store?.stopSelectedRunCommand() }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(runCommandActive != true)
    }

    CommandGroup(after: .pasteboard) {
      // Edit ▸ Find: searches the focused pane — the terminal's scrollback for a terminal pane, or the
      // in-file find for a read-only file viewer. ⌘F opens the find bar; ⌘G / ⇧⌘G step to the next /
      // previous match (wrapping at the ends). All three are reserved in GhosttySurfaceView.isAppShortcut
      // so the menu key-equivalent wins over the terminal even while a TUI in an enhanced keyboard mode
      // (Claude/Codex) is running. Find Next / Previous no-op when no find bar is open. Disabled with no
      // terminal (a workroom always opens with one; a lone file pane is the only gap).
      Divider()
      Button("Find…") { store?.startFindInFocusedPane() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(hasTerminal != true)
      Button("Find Next") { store?.navigateFocusedPaneSearch(forward: true) }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(hasTerminal != true)
      Button("Find Previous") { store?.navigateFocusedPaneSearch(forward: false) }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(hasTerminal != true)

      // Edit menu: toggle copy-on-select (checkmark reflects state). A divider sets it apart
      // from the standard Cut/Copy/Paste group above, since it governs clipboard behaviour
      // rather than performing an action. No shortcut — it's a set-and-forget preference,
      // mirrored by the Settings checkbox.
      Divider()
      Toggle("Copy on Select", isOn: $copyOnSelect)
    }

    // File ▸ New Workroom (⌘N, issue #81) + New Window. New Workroom raises the project-picker
    // dialog (RootView observes `requestNewWorkroomPicker`); picking a project creates + opens a
    // workroom in it. It takes ⌘N — the more frequent action — so New Window keeps its menu item but
    // loses the accelerator rather than taking a second-choice "N" combo (⇧⌘N is Next Notification;
    // ⌥⌘N went unbound when issue #118 removed the Notifications inspector). New Workroom is
    // disabled with no projects, so ⌘N is a silent no-op rather than an empty dialog (issue #81 D3).
    // Replaces the standard WindowGroup item so the labels are explicit.
    CommandGroup(replacing: .newItem) {
      Button("New Window") { openWindow(value: WindowSeed(id: UUID(), restore: false)) }
      Button("New Workroom…") { store?.requestNewWorkroomPicker = true }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(hasProjects != true)
      // Open workroom… (⌘O, issue #94): raises the open-existing picker (RootView observes
      // `requestOpenWorkroomPicker`); picking a root/workroom switches + focuses it. ⌘O moved here
      // from the Go-menu "Open in Editor" (which keeps its menu item, no shortcut). Disabled with no
      // projects, so ⌘O is a silent no-op rather than an empty picker.
      Button("Open Workroom…") { store?.requestOpenWorkroomPicker = true }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(hasProjects != true)
    }

    CommandGroup(after: .newItem) {
      // No key equivalent: ⌘O is File ▸ Open workroom…, ⇧⌘O is Go ▸ Open in Editor (issue #94).
      // New Project keeps its menu item without an accelerator.
      Button("New Project…") {
        store?.requestAddProject = true
      }

      Divider()

      Button("New Terminal") {
        store?.newTerminalInSelectedTarget()
      }
      .keyboardShortcut("t", modifiers: .command)
      .disabled(workroomSelected != true)

      // Quick terminal at ~/ in its own chrome-less window (issue #39) — same open/focus action as
      // the toolbar button. Always enabled (needs no workroom). Shows ⌥§ as its equivalent: no
      // double-fire, because the registered Carbon hotkey consumes ⌥§ system-wide before it reaches
      // the menu (Release). In a Debug-only dev run (no Release build owning the global ⌥§), the
      // menu equivalent is what makes the shortcut work — handy for QA.
      Button("Quick Terminal") {
        NotificationCenter.default.post(name: .showQuickTerminal, object: nil)
      }
      .keyboardShortcut("§", modifiers: .option)
      // ⌥§ carries no ⌘, so the key monitor's `flags.contains(.command)` path never sees it and
      // nothing else would stop it opening a whole new window from behind a dialog.
      .disabled(modalBlocked)

      // ⌘W: "Close Terminal" sits above the standard File ▸ Close, so it wins the ⌘W
      // equivalent while enabled (Close keeps no shortcut).
      Button("Close Terminal") {
        store?.closeCurrentTerminalTab()
      }
      .keyboardShortcut("w", modifiers: .command)
      .disabled(hasTerminal != true)

      // Bulk close (issue #72), no shortcuts. Labelled "Tabs" (not "Terminals") since they act on
      // diff/content tabs too. "Close Other Tabs" needs ≥2 tabs; "Close All Tabs" needs ≥1.
      Button("Close Other Tabs") {
        store?.closeOtherTerminalTabsInSelectedTarget()
      }
      .disabled(multipleTerminalTabs != true)
      Button("Close All Tabs") {
        store?.closeAllTerminalTabsInSelectedTarget()
      }
      .disabled(hasTerminal != true)

      Divider()

      // Reveal the selected target's directory in Finder (moved off the detail toolbar). Acts on the
      // current selection like the terminal items above; reads `store.selectedTarget` directly so the
      // enabled state tracks selection live (the `@ObservedObject store` re-evaluates this body).
      // Disabled with no selection or a missing directory.
      Button("Reveal in Finder") {
        if let path = store?.selectedTarget?.path {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
      }
      .disabled(store?.selectedTarget == nil || store?.selectedTarget?.isMissing == true)

      // Gate the close-terminal confirmation (default on). A set-and-forget preference, so a divider
      // sets it apart from the File actions above (like the Quit toggle); no shortcut. Binds the same
      // key as the Settings checkbox and the dialog's "Don't ask me again", so ticking that box in the
      // confirm alert unchecks this item, and vice versa.
      Divider()
      Toggle("Confirm Before Closing a Terminal", isOn: $confirmOnCloseTerminal)
    }

    // Browser/Finder-style back/forward over the workroom + terminal history (issue #26), plus
    // the ⇧⌘N jump to the oldest pending notification. ⌘[ / ⌘] are reserved from the terminal in
    // GhosttySurfaceView.isAppShortcut so these key equivalents fire.
    CommandMenu("Go") {
      Button("Back") { store?.navigateBack() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(canNavigateBack != true)
      Button("Forward") { store?.navigateForward() }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(canNavigateForward != true)

      // Open the selected target in the remembered external editor (the toolbar's open button, ⇧⌘O).
      // ⌘O is now File ▸ Open workroom… (issue #94); this took ⇧⌘O from New Project, which keeps its
      // menu item without a shortcut. Disabled when nothing's selected / its directory is missing /
      // no editor is installed.
      Divider()
      Button("Open in \(ExternalEditor.remembered?.name ?? "Editor")") {
        store?.openSelectedInEditor()
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])
      .disabled(canOpenInEditor != true)

      // Scroll the focused terminal to the top/bottom of its scrollback (issue #42). ⌘↑/⌘↓ — the
      // menu key-equivalent fires before the terminal, so it works even in an enhanced-keyboard TUI.
      // Disabled when no terminal is focused.
      Divider()
      Button("Scroll to Top") { store?.scrollFocusedTerminalToTop() }
        .keyboardShortcut(.upArrow, modifiers: .command)
        .disabled(hasTerminal != true)
      Button("Scroll to Bottom") { store?.scrollFocusedTerminalToBottom() }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .disabled(hasTerminal != true)

      // Cycle terminal tabs (⌥⌘←/→) and workroom tabs (⇧⌥⌘←/→) (issue #29). The keys are caught by
      // the AppDelegate monitor so they fire before the terminal; shown here for discoverability (the
      // monitor consumes them, so no double-fire — like the Run menu). Disabled when there's nothing
      // to cycle between (≤1 tab).
      Divider()
      Button("Next Terminal Tab") { store?.cycleTerminalTab(forward: true) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        .disabled(multipleTerminalTabs != true)
      Button("Previous Terminal Tab") { store?.cycleTerminalTab(forward: false) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(multipleTerminalTabs != true)
      Button("Next Workroom Tab") { store?.cycleWorkroomTab(forward: true) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
        .disabled(multipleWorkroomTabs != true)
      Button("Previous Workroom Tab") { store?.cycleWorkroomTab(forward: false) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
        .disabled(multipleWorkroomTabs != true)

      Divider()

      // Jump to the run terminal if one exists (issue #7) — navigation only, so it's named distinctly
      // from the Run menu's "Run" (which starts the command). Disabled when there's none to go to.
      Button("Run Terminal") { store?.revealRunTerminal() }
        .disabled(hasRunTerminal != true)

      Divider()

      // ⇧⌘N: jump to the oldest pending notification (bottom of the panel). Opening dismisses it,
      // so repeated presses walk the backlog oldest→newest. Disabled when there are none.
      Button("Next Notification") {
        store?.openOldestNotification()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(hasNotifications != true)
    }
  }
}
