import AppKit
import Defaults
import SwiftUI
import UserNotifications
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import os

/// Installs the app's local key monitor: the shortcuts that are handled *here* rather than as menu
/// items, because they'd clutter the menu (⌘1–9 / ⌥⌘1–9 tab focus), because they have no menu home
/// (⌘` window cycling, ⌃⌘arrows pane focus, ⌥Tab / ⌃Tab quick switching), or because the monitor must
/// beat a competing menu item (⌘W in the quick terminal). A local monitor runs inside
/// `NSApp.sendEvent`, ahead of both menu key-equivalent dispatch and the focused terminal surface, so
/// it is also the only place a shortcut can be claimed *conditionally* — see the ⌥Tab / ⌃Tab branch,
/// which passes the key back to the terminal when there is nothing to switch to.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  /// A UI-test fixture launch: it skips the Quick Terminal's orphan sweep and quits without asking.
  /// Never in Release.
  nonisolated private static var isFixtureLaunch: Bool {
    #if DEBUG
      AppEnvironment.current.isFixture
    #else
      false
    #endif
  }

  private var monitor: Any?
  /// The global ⌘§ show/hide shortcut while enabled, else nil (issue #13). Registered/torn down by
  /// `updateGlobalHotkey()` to follow the `globalHotkey` setting.
  private var showHideHotkey: GlobalHotkey?
  /// The global quick-terminal shortcut (⌥§ unless Settings records another) while enabled, else
  /// nil (issue #39). Registered/torn down alongside `showHideHotkey` by `updateGlobalHotkey()`
  /// under the same `globalHotkey` setting.
  private var quickTerminalHotkey: GlobalHotkey?
  /// Re-registers the quick-terminal hotkey when Settings records a new shortcut.
  private var quickTerminalShortcutObservation: Task<Void, Never>?
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
  /// Retains the background-save observer (issue #46) for the app's lifetime.
  private var resignActiveObserver: Any?

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

  /// What a quick-switcher keystroke (⌥Tab / ⌃Tab, issue #132) should do for `window`.
  ///
  /// Three outcomes, because this shortcut is the first one whose consumption is *conditional*:
  /// - `.passThrough` — not one of our windows (Settings, About, the quick terminal). The key belongs
  ///   to whatever is focused there; a terminal's own ⌃Tab binding then consumes it (#555).
  /// - `.swallow` — one of ours with a modal up. Raising a window and moving its selection under its
  ///   own sheet would leave that sheet acting on a workroom the user never chose (for the commit
  ///   sheet, a wrong-target VCS write). Gated on the FULL `hasModalPresentation` predicate, not
  ///   `activePicker` — hence resolving through the registry rather than `shortcutStore`, which nils
  ///   out a picker window and a foreign window alike, two cases that must differ here.
  /// - `.act(store)` — go ahead; whether the event is consumed then depends on whether the switcher
  ///   actually switched (nothing to switch to ⇒ the terminal keeps the key).
  ///
  /// `registry` is injectable for the same reason as `shortcutStore`'s: so tests don't register windows
  /// on the shared singleton.
  @MainActor static func switcherGate(
    for window: NSWindow?, in registry: WindowRegistry = .shared
  ) -> SwitcherGate {
    guard let store = registry.store(for: window) else { return .passThrough }
    return store.hasModalPresentation ? .swallow : .act(store)
  }

  /// Whether `window` is one of ours *and* has a command-palette dialog open — the case where a
  /// shortcut must be actively swallowed rather than merely no-op'd, because the branch doesn't
  /// consult a store at all (⌘` window cycling).
  @MainActor static func hasModalPicker(
    _ window: NSWindow?, in registry: WindowRegistry = .shared
  ) -> Bool {
    registry.store(for: window)?.activePicker != nil
  }

  private var didScheduleWarmups = false

  /// The first visible normal or onboarding window has completed its update. Keep optional
  /// preparation out of that update and give input/display a turn between the two warmups.
  func prewarmAfterDisplay() {
    guard !didScheduleWarmups else { return }
    didScheduleWarmups = true
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) {
      SwitcherPanelController.shared.prepare()
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) {
        MarkdownWebViewPool.shared.prewarm()
      }
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let interval = LaunchSignposts.begin("Application did finish launching")
    defer { LaunchSignposts.end("Application did finish launching", interval) }
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
    // Alerts for terminals that need the user (#358), app-wide; their count joins the badge.
    ProgramStatusAlerts.shared.onWaitingChange = { WindowRegistry.shared.recomputeBadge() }
    ProgramStatusAlerts.shared.start()

    // Not under test (`AppEnvironment.current.isTestProcess`): it would replace the developer's real daemon.
    if !AppEnvironment.current.isTestProcess {
      // Hand an older running daemon to the bundled one (#230), before panes are likely to attach.
      MainActor.assumeIsolated { DaemonHandOff.start() }
      // A crash or force quit leaves the Quick Terminal's shells running, unseen: end them. Its own
      // sweep, since the workroom one waits for a project list, which may be empty (ADR 0064). A
      // live Quick Terminal opened meanwhile is attached, and attached sessions are spared.
      if !Self.isFixtureLaunch {
        Task { @MainActor in
          let service = PersistentSessionService.shared
          await service.prepareBackend()
          await service.endOrphanedSessions(resolves: QuickTerminalController.sweepResolves)
        }
      }
      // Remote panes reattach on wake and network changes, not a minute later.
      MainActor.assumeIsolated { RemoteLinkMonitor.shared.start() }
    }

    // Wire shortcuts now; the optional panel render waits for the first window update. An earlier
    // reveal still prepares it on demand through `show`, so input never depends on the warmup.
    SwitcherPanelController.shared.attach(to: .shared)

    // Save the session whenever the app goes to the background (issue #46). Belt and braces on top
    // of the coalesced writes: ⌘-tabbing away is the most common moment a user leaves a layout they
    // would hate to lose, and it costs nothing when nothing changed (the coordinator compares the
    // captured document with the last one written).
    resignActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { SavedLayoutCoordinator.shared.writeIfChanged() }
    }

    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [quickTerminal] event in
      let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
      // The quick terminal's own keys (issue #39) when its window is key: ⌘W closes a pane, ⌘T a
      // new tab, ⌘D / ⇧⌘D splits, ⌘1–9 its tabs, ⌃⌘arrows its panes. The menu's items for those
      // target the main window's tabs, and the workroom handlers below resolve only registered
      // windows' stores, so catch them here (like ⌘R / ⌘1–9 above). Gated on the key window being a
      // QuickTerminalWindow, so they still act on a workroom everywhere else.
      if (event.window ?? NSApp.keyWindow) is QuickTerminalWindow,
        let key = QuickTerminalKey.classify(
          flags: flags, characters: event.charactersIgnoringModifiers, keyCode: event.keyCode),
        MainActor.assumeIsolated({ quickTerminal.perform(key) })
      {
        return nil
      }
      // ⌘W on an auxiliary window (Settings, About) — a window with no AppStore (not a workroom
      // window). The menu's "Close Tab" owns ⌘W app-wide but is disabled there (no focused
      // terminal), so ⌘W would otherwise just beep. Close the window, as the standard File ▸ Close
      // would. Workroom windows (store != nil) fall through so their "Close Tab" still fires.
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
      // ⌥Tab / ⌃Tab: the quick switchers (issue #132) — ⌥Tab steps open workrooms across every
      // window by most-recent use, ⌃Tab steps the current workroom's panes. Caught here for the same
      // reason as ⌘1–9, and *only* here: Tab is deliberately NOT in `isAppShortcut`, because whether
      // the app owns it depends on runtime state (a workroom with one pane has nothing to switch to,
      // so the key is left to the terminal, where Ghostty's `next_tab` binding consumes it, #555).
      // Both trigger modifiers are preferences — a global hotkey grabber like AltTab beats this
      // monitor and can't be detected.
      if QuickSwitcherKey.classify(keyCode: event.keyCode, flags: flags) != nil {
        // Decided on the main actor; the event itself goes back out here, since `NSEvent` isn't
        // Sendable and can't be the closure's result.
        let passes = MainActor.assumeIsolated { () -> Bool in
          switch Self.switcherGate(for: window) {
          case .passThrough: return true
          case .swallow: return false
          case .act(let store):
            // Autorepeat would spin the switcher (~15 steps/sec); macOS's own ⌘Tab ignores repeats too.
            // Tested INSIDE `.act`, not above the gate: above it, a held ⌃Tab in the quick terminal or
            // in a single-pane workroom — the cases deliberately left to the terminal — passed its
            // first keystroke through and had every repeat after it silently eaten.
            if event.isARepeat { return false }
            guard let hit = QuickSwitcherKey.classify(keyCode: event.keyCode, flags: flags) else {
              return true
            }
            // Consumed only when it switched, so a single-pane workroom leaves ⌃Tab to the terminal —
            // the same rule as the ⌥⌘digit / ⌥⌘arrow branches below.
            return QuickSwitcherController.shared.handleTrigger(
              hit.kind, reverse: hit.reverse, in: store) == false
          }
        }
        return passes ? event : nil
      }
      // Escape and ←/→ while a switcher session is live (issue #132). Ahead of every other branch that
      // could claim them, because a live session owns the keyboard until it ends — and behind the Tab
      // branch above, which is what starts one.
      //
      // Gated on the window like the Tab branch, and on the modifiers: without the window gate, Escape
      // pressed in the quick terminal or in Settings was swallowed to cancel the rail instead of
      // dismissing what was actually in front of the user. `handleArrow` enforces the rest — revealed
      // only, and no modifier beyond the trigger, so a live session can't steal ⌥⌘←/→ or ⇧⌥⌘←/→.
      if MainActor.assumeIsolated({ QuickSwitcherController.shared.isLive }),
        MainActor.assumeIsolated({
          if case .passThrough = Self.switcherGate(for: window) { false } else { true }
        })
      {
        if event.keyCode == 53 {  // Escape
          return MainActor.assumeIsolated { QuickSwitcherController.shared.handleEscape() }
            ? nil : event
        }
        if event.keyCode == 123 || event.keyCode == 124 {  // ← / →
          let reverse = event.keyCode == 123
          return MainActor.assumeIsolated {
            QuickSwitcherController.shared.handleArrow(reverse: reverse, flags: flags)
          } ? nil : event
        }
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
      // project's settings with a warning instead of doing nothing (issue #127).
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
      // terminal tabs (issue #29). Wraps at a split's edge; consumed only when focus actually moves.
      // (Virtual keycodes: left 123 / right 124 / down 125 / up 126.)
      let arrows: [UInt16: PaneDirection] = [123: .left, 124: .right, 125: .down, 126: .up]
      if flags == [.command, .control], let direction = arrows[event.keyCode],
        MainActor.assumeIsolated({ Self.shortcutStore(for: window)?.focusPane(direction) ?? false })
      {
        return nil
      }
      // ⌃⌘S: toggle the Projects sidebar (issue #128). Caught here — not just left to the menu's
      // key-equivalent — so it fires reliably even with a focused TUI (like ⌘1-9 above).
      if flags == [.command, .control], event.charactersIgnoringModifiers?.lowercased() == "s" {
        Task { @MainActor in Self.shortcutStore(for: window)?.toggleSidebar() }
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
        Task { @MainActor in Self.shortcutStore(for: window)?.toggleSidebar() }
        return nil
      }
      // ⌥⌘B: secondary "Projects" sidebar toggle, mirroring ⌃⌘S above — caught here (not just left
      // to a menu key-equivalent) so it fires reliably with a focused TUI too (issue #128).
      if flags == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "b" {
        Task { @MainActor in Self.shortcutStore(for: window)?.toggleSidebar() }
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
    quickTerminalShortcutObservation = Task { @MainActor [weak self] in
      for await _ in Defaults.updates(.quickTerminalShortcut, initial: false) {
        // Let the old keys go before claiming the new ones.
        self?.quickTerminalHotkey = nil
        self?.updateGlobalHotkey()
      }
    }

    // The main-toolbar Quick-Terminal button (issue #39) posts this; the controller lives here, out
    // of the SwiftUI view's reach. The ⌥§ hotkey calls the controller directly (see updateGlobalHotkey).
    quickTerminalObserver = NotificationCenter.default.addObserver(
      forName: .showQuickTerminal, object: nil, queue: .main
    ) { [quickTerminal] _ in
      // The controller, not `self`: it is main-actor-isolated, so the `Sendable` handler can hold it,
      // and it lives exactly as long as the app delegate that owns it.
      MainActor.assumeIsolated { quickTerminal.show() }
    }
    // Its terminals share the app's notification list, and opening one of theirs slides it in.
    WindowRegistry.shared.quickTerminal = quickTerminal

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
    source.setEventHandler { [quickTerminal] in
      // The source fires on the main queue, so we're main-actor-isolated in practice (same pattern
      // as the NSEvent monitor above) — assert it so we can touch the store synchronously.
      MainActor.assumeIsolated {
        // SIGTERM is the path `XCUIApplication.terminate()`, `make app-run` and `pkill` take —
        // `applicationShouldTerminate` never runs for a signal, so the session flush has to happen
        // here too or none of those exits save anything (issue #46). Remote workrooms' layouts go
        // to their hosts first, for at most a second (#255, D14).
        // Nobody can be asked about a signal, so the quit setting decides, and keeps runs going
        // while it is still Ask (#522, Q12). Runs it stops are left out of what is saved.
        let action = QuitWithRunningServers.action(
          setting: Defaults[.quitWithRunningServers],
          hasLiveRuns: WindowRegistry.shared.hasAnyLiveRun,
          isUpdateRelaunch: Updater.isInstallingUpdate, canAsk: false)
        AppStore.quitStopsRuns = action == .stop
        let group = DispatchGroup()
        group.enter()
        Task {
          await AppStore.flushHostLayouts(budget: 1)
          SavedLayoutCoordinator.shared.flushAndFreeze()
          // Only once frozen: the document is built from the live windows, which stopping changes.
          if action == .stop {
            group.enter()
            WindowRegistry.shared.gracefullyStopAllWindows(timeout: 4) { group.leave() }
          }
          group.leave()
        }
        // The Quick Terminal's shells are not kept across a quit (ADR 0064), a signalled one too.
        quickTerminal.endSessionsAtQuit()
        // A tab closed moments before this signal fires an unstructured kill Task; without
        // waiting for it here too, quitting fast enough after a close leaves that one session
        // running despite the explicit close.
        group.enter()
        Task {
          await PersistentSessionService.shared.awaitPendingCloseKills(
            until: ContinuousClock.now + PersistentSessionService.closeKillQuitBudget)
          group.leave()
        }
        group.notify(queue: .main) { exit(EXIT_SUCCESS) }
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
          showHideHotkey = GlobalHotkey.commandSection {
            MainActor.assumeIsolated { AppDelegate.toggleAppVisibility() }
          }
        }
        if quickTerminalHotkey == nil {
          // The controller, not `self`, as for the toolbar button's observer above.
          quickTerminalHotkey = GlobalHotkey.quickTerminal(Defaults[.quickTerminalShortcut]) {
            [quickTerminal] in
            MainActor.assumeIsolated { quickTerminal.toggle() }
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
  @MainActor private static func toggleAppVisibility() {
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
        NSApp.activate(ignoringOtherApps: true)
        WindowRegistry.shared.open(targetID: targetID, tabID: tabID, notifID: notifID)
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
    // UI-test fixture quits cleanly (no modal, no waiting) so XCUITest teardown never blocks. The
    // session still flushes here: this branch IS terminating, and a UI test that relaunches to check
    // what was restored must not race the coalescing timer (issue #46).
    if Self.isFixtureLaunch {
      SavedLayoutCoordinator.shared.flushAndFreeze()
      return .terminateNow
    }
    // Run commands are daemon sessions, which outlive the app unless quitting stops them (#522).
    // The first quit with one going asks, whether or not quit confirmation is on, and keeps the
    // answer; that dialog's Cancel stands in for the confirmation (Q9, Q10).
    var action = QuitWithRunningServers.action(
      setting: Defaults[.quitWithRunningServers],
      hasLiveRuns: WindowRegistry.shared.hasAnyLiveRun,
      isUpdateRelaunch: Updater.isInstallingUpdate, canAsk: true)
    if action == .ask {
      guard let answer = askAboutRunningServers() else { return .terminateCancel }
      Defaults[.quitWithRunningServers] = answer
      action = answer == .stop ? .stop : .keep
    } else if Defaults[.confirmOnQuit] {
      let alert = NSAlert()
      alert.messageText = "Quit Workroom?"
      alert.informativeText =
        "Your terminals keep running in the background and will be waiting when you reopen "
        + "Workroom."
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
    return stopRunCommandsThenTerminate(sender, stoppingRuns: action == .stop)
  }

  /// The first quit with a dev server running (#522): keep them running or stop them, remembered in
  /// Settings ▸ General. Nil when the user cancels the quit.
  @MainActor
  private func askAboutRunningServers() -> QuitWithRunningServers? {
    let alert = NSAlert()
    alert.messageText = "Keep your dev servers running after Workroom quits?"
    alert.informativeText =
      "Your run commands keep running, and their tabs pick them up again when you reopen "
      + "Workroom. Stopping them ends each one as Stop does. Workroom remembers your answer, and "
      + "you can change it in Settings ▸ General."
    alert.addButton(withTitle: "Keep Running and Quit")
    alert.addButton(withTitle: "Stop Servers and Quit")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .keepRunning
    case .alertSecondButtonReturn: return .stop
    default: return nil
    }
  }

  /// `stoppingRuns`: stop every live run command and let it exit before the process dies, so dev
  /// servers clean up (release their port + pidfile) — the quit setting asked for it (#522). Run
  /// commands that keep running are left alone: they are daemon sessions, and their tabs reattach
  /// on the next launch. Never frees a surface, so the no-mass-free-on-quit rationale in
  /// `applicationWillTerminate` still holds. Bounded so a wedged server can't block the quit.
  @MainActor
  private func stopRunCommandsThenTerminate(
    _ sender: NSApplication, stoppingRuns: Bool
  ) -> NSApplication.TerminateReply {
    let registry = WindowRegistry.shared
    // Mark the app as terminating so a window's own close handler doesn't also prompt/stop (#70).
    registry.isTerminating = true
    // The Quick Terminal's shells are not kept across a quit (ADR 0064). Ended before the close-kill
    // wait below, which counts them.
    quickTerminal.endSessionsAtQuit()
    // Write the session and stop writing (issue #46). Deliberately HERE and not at the top of
    // `applicationShouldTerminate`: that method can still return `.terminateCancel` at the confirm
    // dialog, and freezing above that guard would silently kill session saving for the rest of the
    // app's life after one cancelled ⌘Q. This point is past the guard and still before any window
    // closes — which is exactly what the freeze protects, since the document is rebuilt from the
    // live windows: the reply below, which closes them, waits on the group.
    //
    // Remote workrooms' layouts go to their hosts first, for at most a second (#255, D14), so the
    // session written next marks only what did not get there as stale.
    // Runs this quit stops don't come back, so their tabs are left out of what is saved (#522).
    AppStore.quitStopsRuns = stoppingRuns
    let group = DispatchGroup()
    group.enter()
    Task {
      await AppStore.flushHostLayouts(budget: 1)
      SavedLayoutCoordinator.shared.flushAndFreeze()
      // Only once frozen: the document is built from the live windows, which stopping changes.
      if stoppingRuns {
        group.enter()
        // Stop every window's run commands, not just the focused one's.
        registry.gracefullyStopAllWindows(timeout: 5) { group.leave() }
      }
      group.leave()
    }
    // A tab closed moments before quitting fires an unstructured kill Task (`closeTab`); wait for
    // it unconditionally — skipping this (the old early-return did, with no run command live) let
    // that one session outlive the quit despite the user having explicitly closed it.
    group.enter()
    Task {
      await PersistentSessionService.shared.awaitPendingCloseKills(
        until: ContinuousClock.now + PersistentSessionService.closeKillQuitBudget)
      group.leave()
    }
    group.notify(queue: .main) { sender.reply(toApplicationShouldTerminate: true) }
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
  /// the hangup and is left orphaned on its port/pidfile. Run commands are daemon sessions now, so
  /// quitting keeps them running unless the quit setting says to stop them (#522); then
  /// `applicationShouldTerminate` asks each one's supervisor to stop and waits for it *before*
  /// returning, never freeing a surface, so the no-mass-free rationale above still holds.
  @MainActor
  func applicationWillTerminate(_ notification: Notification) {}
}
