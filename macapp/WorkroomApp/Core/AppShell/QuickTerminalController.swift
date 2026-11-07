import AppKit
import Defaults
import SwiftUI
import WorkroomDomain

/// Marker type for the quick-terminal window so the `AppDelegate` key monitor can recognise it and
/// route ⌘W to close it. (The app rebinds ⌘W to a "Close Tab" menu command that targets the
/// main window's tabs and wins over a window's own `performKeyEquivalent`, so ⌘W is caught in the
/// monitor — the same mechanism the app already uses for ⌘R / ⌘1–9.)
final class QuickTerminalWindow: NSWindow {
  // AppKit pulls a titled window back on-screen, so the slide could never start off-screen.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// The screen edge the quick terminal slides in from (Settings ▸ Terminal).
enum QuickTerminalEdge: String, CaseIterable, Defaults.Serializable,
  Defaults.PreferRawRepresentable
{
  case top, bottom, left, right

  var label: String { rawValue.capitalized }

  /// Where the window sits when shown: against this edge of `visible` (the screen's
  /// `visibleFrame`), shrunk to fit, its centre at `offset` along the edge (0 the left or bottom
  /// end, 1 the other, 0.5 centred) as far as it fits.
  func dockedFrame(size: NSSize, in visible: NSRect, offset: Double = 0.5) -> NSRect {
    let size = NSSize(
      width: min(size.width, visible.width), height: min(size.height, visible.height))
    let x = min(
      max(visible.minX + visible.width * offset - size.width / 2, visible.minX),
      visible.maxX - size.width)
    let y = min(
      max(visible.minY + visible.height * offset - size.height / 2, visible.minY),
      visible.maxY - size.height)
    let origin: NSPoint
    switch self {
    case .top: origin = NSPoint(x: x, y: visible.maxY - size.height)
    case .bottom: origin = NSPoint(x: x, y: visible.minY)
    case .left: origin = NSPoint(x: visible.minX, y: y)
    case .right: origin = NSPoint(x: visible.maxX - size.width, y: y)
    }
    return NSRect(origin: origin, size: size)
  }

  /// Where a drag docks a window of `size` that the pointer would put centred at `center`: the
  /// edge whose docked spot is nearest it, ties going top, bottom, left, right. `current` keeps
  /// its edge until another is `stickiness` points nearer, so a pointer on the line doesn't flicker.
  /// From the window's centre, not the pointer: a grab near the window's end would otherwise flip
  /// it between opposite edges as each hop moved the window under the pointer.
  static func nearest(
    forCenter center: NSPoint, size: NSSize, in visible: NSRect,
    current: QuickTerminalEdge? = nil, stickiness: CGFloat = 40
  ) -> QuickTerminalEdge {
    func distance(_ edge: QuickTerminalEdge) -> CGFloat {
      let docked = edge.dockedFrame(
        size: size, in: visible, offset: edge.offset(forCenter: center, size: size, in: visible))
      let gap = hypot(docked.midX - center.x, docked.midY - center.y)
      return edge == current ? gap - stickiness : gap
    }
    // `min(by:)` keeps the first of equal elements, so `allCases`' order breaks ties.
    return allCases.min { distance($0) < distance($1) }!
  }

  /// Where along this edge a window of `size` centred at `center` sits, as `dockedFrame`'s
  /// `offset`, clamped so the window stays on the screen.
  func offset(forCenter center: NSPoint, size: NSSize, in visible: NSRect) -> Double {
    let (position, start, length, extent) =
      self == .top || self == .bottom
      ? (center.x, visible.minX, visible.width, size.width)
      : (center.y, visible.minY, visible.height, size.height)
    guard length > extent else { return 0.5 }
    let half = extent / 2 / length
    return min(max(Double((position - start) / length), half), 1 - half)
  }

  /// `docked` pushed just past this edge of `screen` (the screen's full frame), where the slide
  /// starts and ends. Only the origin moves, so the terminal never resizes mid-slide.
  func hiddenFrame(docked: NSRect, screen: NSRect) -> NSRect {
    var frame = docked
    switch self {
    case .top: frame.origin.y = screen.maxY
    case .bottom: frame.origin.y = screen.minY - frame.height
    case .left: frame.origin.x = screen.minX - frame.width
    case .right: frame.origin.x = screen.maxX
    }
    return frame
  }
}

/// The "quick terminal" (issue #39): a login shell (at `~/` unless Settings ▸ Terminal names
/// another folder) in its own chrome-less window that slides in from a screen edge, Quake-style,
/// summoned by the ⌥§ global hotkey or the main-toolbar button. One persistent controller owns at
/// most one window + surface at a time:
///
/// ```
///   ABSENT  ──⌥§ / button──▶ VISIBLE      create window + a fresh surface, slide in, key + focused
///   VISIBLE ──⌥§───────────▶ HIDDEN       slide out, orderOut — surface kept alive (scrollback / process persist)
///   HIDDEN  ──⌥§ / button──▶ VISIBLE      slide in, focus the SAME surface
///   VISIBLE/HIDDEN ──⌘W / shell exit──▶ ABSENT   tearDown surface, destroy window
/// ```
///
/// A toggle (`toggle()`, the hotkey) can hide; the button (`show()`) only ever brings the window
/// forward. After a full close the next summon is a brand-new terminal — no session resurrection.
///
/// Its tabs and panes are a workroom's — the same `WorkroomTerminalsView`, tab strip and pane tree,
/// so they look and behave the same — over a private `AppStore` that is never registered with
/// `WindowRegistry` (never saved, restored or counted in the badge), whose `TerminalPanes` keeps
/// no background session (`persistsSessions`) and moves no pane to a window of its own
/// (`allowsDetach`). The target is no project, so the store's project lookups never see it. The
/// window is an AppKit `NSWindow`, not a SwiftUI scene, for exact chrome control, and follows live
/// theme switches, which `ThemeService` only takes to registered stores.
@MainActor
final class QuickTerminalController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  /// The Quick Terminal's own store, while a window exists.
  private(set) var store: AppStore?

  /// The Quick Terminal's one target: no workroom, its id unlike any project path. `path` is where
  /// a new tab's shell starts.
  static func target() -> TerminalTarget {
    TerminalTarget(
      id: targetID, title: "Quick Terminal", path: newTabDirectory(), unavailability: nil)
  }
  nonisolated static let targetID: TerminalTarget.ID = .quickTerminal
  private var themeObserver: NSObjectProtocol?
  /// Guards `tearDownState` against the re-entrancy of `window.close()` → `windowWillClose`.
  private var tearingDown = false
  /// Set while a summon waits for the session backend's first health check (`show`).
  private var preparingBackend = false
  /// Where its panes' background sessions live, `.shared` unless a test stands in its own.
  var sessionServiceOverride: PersistentSessionService?
  private var sessionService: PersistentSessionService { sessionServiceOverride ?? .shared }
  /// Set while a slide-out runs; a summon during it clears it, cancelling the pending `orderOut`.
  private var hiding = false
  /// Set while a summon from another app waits for the activation to land (`frontOnceActive`).
  private var activationObserver: NSObjectProtocol?

  /// Nonisolated so `AppDelegate` can construct it as a stored-property default (a nonisolated
  /// context); it only assigns nil/closure defaults — no main-actor work runs here. Every method
  /// that touches AppKit stays main-actor-isolated via the class annotation.
  nonisolated override init() {
    super.init()
  }

  /// Surface factory — overridable in tests to inject a non-spawning surface (`spawnsSurface: false`)
  /// so no real PTY / Metal renderer is created. Defaults to a login shell in the folder given, or
  /// the command given (an Investigate tab's agent).
  var makeSurface: @MainActor (String, String?) -> GhosttySurfaceView = {
    GhosttySurfaceView(workingDirectory: $0, command: $1)
  }

  /// Where a new tab's shell starts: the Settings folder. A split starts in its neighbour's.
  static func newTabDirectory() -> String {
    workingDirectory(for: Defaults[.quickTerminalDirectory])
  }

  /// The folder a new quick-terminal shell starts in: the setting with `~` expanded, or the home
  /// folder when it is empty or no longer a folder (deleted, or on an unmounted volume).
  nonisolated static func workingDirectory(for setting: String) -> String {
    let path = (setting as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    // An empty setting expands to "", which no folder matches.
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return NSHomeDirectory() }
    return path
  }

  /// Whether losing key focus slides the window away (Settings ▸ Terminal). Overridable in tests,
  /// so no shared `Defaults` write races the parallel test workers.
  var hidesWhenUnfocused: @MainActor () -> Bool = { Defaults[.quickTerminalHidesWhenUnfocused] }

  /// True while a window is on screen and not sliding out. False when ABSENT or HIDDEN.
  var isVisible: Bool { !hiding && (window?.isVisible ?? false) }
  /// True while a window exists (VISIBLE or HIDDEN) — inspection aid for tests.
  var hasWindow: Bool { window != nil }
  /// The focused pane's surface (VISIBLE or HIDDEN), else nil.
  var currentSurface: GhosttySurfaceView? { store?.terminals.focusedSurface(for: Self.target()) }
  /// The live window — for tests asserting the chrome-less styling.
  var currentWindow: NSWindow? { window }

  /// Hotkey semantics: ABSENT → new + show, VISIBLE → hide, HIDDEN → show.
  func toggle() {
    if window == nil {
      show()
    } else if isVisible {
      hide()
    } else {
      show()
    }
  }

  /// Button / summon semantics: never hides — create if ABSENT, then slide in + focus. Called
  /// for the toolbar button and as the second half of `toggle()` from ABSENT/HIDDEN.
  func show() {
    if window == nil {
      // Its first pane waits for the session backend's first health check, as a workroom's do:
      // created before, it would open as a plain shell, with no "needs you" alerts (#573).
      guard sessionService.isBackendPrepared else {
        guard !preparingBackend else { return }
        preparingBackend = true
        Task { [weak self] in
          guard let self else { return }
          await self.sessionService.prepareBackend()
          self.preparingBackend = false
          self.show()
        }
        return
      }
      createWindow()
    }
    guard let window, let surface = currentSurface else { return }
    // The hotkey can fire while another app is frontmost (or while Workroom is hidden), so pull the
    // app forward — mirrors `AppDelegate.toggleAppVisibility`.
    if !NSApp.isActive { frontOnceActive(window) }
    NSApp.activate(ignoringOtherApps: true)
    hiding = false
    // Dock on every summon: to the edge the setting names now, on the screen under the pointer
    // (the hotkey fires from any app, so the key window's screen may not be where the user is).
    let screen =
      NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    if let screen {
      let edge = Defaults[.quickTerminalEdge]
      let docked = edge.dockedFrame(
        size: window.frame.size, in: screen.visibleFrame, offset: Defaults[.quickTerminalOffset])
      // Re-summoned mid slide-out, it is still up: slide back from where it is.
      if !window.isVisible {
        window.setFrame(edge.hiddenFrame(docked: docked, screen: screen.frame), display: false)
      }
      window.makeKeyAndOrderFront(nil)
      slide(window, to: docked)
    } else {
      window.makeKeyAndOrderFront(nil)
    }
    window.makeFirstResponder(surface)
  }

  /// A notification from one of its panes was clicked: slide in on that pane. Its store is in no
  /// `WindowRegistry`, so the app's usual notification routing can't find it.
  func reveal(tab tabID: TerminalTab.ID?) {
    let target = Self.target()
    if let tabID, let sessions = store?.terminals, sessions.tab(tabID, for: target) != nil {
      sessions.focus(tabID, for: target)
    }
    show()
  }

  /// The activation lands later and fronts the app's last key window, a workroom's, over this one,
  /// which an inactive app can't make key: once it has, make this key and front again.
  private func frontOnceActive(_ window: NSWindow) {
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if let observer = self.activationObserver {
          NotificationCenter.default.removeObserver(observer)
        }
        self.activationObserver = nil
        // A turn later, after AppKit's own activation ordering.
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard self.window === window, self.isVisible, let surface = self.currentSurface
            else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(surface)
          }
        }
      }
    }
  }

  /// Slide out, then hide without destroying: the surface keeps running so a re-summon restores
  /// the same session.
  func hide() {
    guard let window, window.isVisible, !hiding else { return }
    hiding = true
    guard let screen = window.screen else { return finishHide() }
    let hidden = Defaults[.quickTerminalEdge].hiddenFrame(
      docked: window.frame, screen: screen.frame)
    slide(window, to: hidden) { [weak self] in self?.finishHide() }
  }

  /// End of a slide-out. A summon during it cleared `hiding`, and then the window stays up.
  private func finishHide() {
    guard hiding else { return }
    hiding = false
    window?.orderOut(nil)
  }

  /// Animate the window to `frame`, which only differs in origin; instant under Reduce Motion.
  private func slide(
    _ window: NSWindow, to frame: NSRect,
    completion: (@MainActor @Sendable () -> Void)? = nil
  ) {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0 : 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      window.animator().setFrame(frame, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { completion?() }
    }
  }

  private func createWindow() {
    // Its terminals' notifications join the app's one list (ADR 0064).
    let store = AppStore(notifications: WindowRegistry.shared.notifications)
    let sessions = store.terminals
    sessions.sessionService = sessionService
    sessions.readsPaneBranches = true
    sessions.allowsDetach = false
    // Its panes move into a workroom open in any window instead.
    sessions.moveToWorkroomChoices = { [weak store] tabID, target in
      store?.quickTerminalPaneWorkroomChoices(tabID, of: target) ?? []
    }
    sessions.dropOutsideWindow = { [weak store] tabID, target in
      if let store { QuickTerminalPaneDrag.end(store: store, tabID: tabID, target: target) }
    }
    sessions.makeView = { [weak self] _, directory, command in
      let surface =
        self?.makeSurface(directory, command)
        ?? GhosttySurfaceView(workingDirectory: directory, command: command)
      Self.applyTheme(to: surface)
      return surface
    }
    // Closing the last tab, by ⌘W, its ✕ or its shell's exit, closes the window.
    store.onTargetEmptied = { [weak self] _ in self?.close() }
    // Toasts show in the front window, this one while it is key (#573 D2).
    store.forwardToast = { WindowRegistry.shared.showToast($0) }
    // Its one target is always on screen here, so a watched pane's notification counts as seen.
    store.pinnedTarget = Self.target()
    // `ensureInitialTerminal` opens a project's first tab; this target is no project.
    _ = sessions.addTab(for: Self.target())
    self.store = store

    let window = QuickTerminalWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "Quick Terminal"
    // Chrome-less: hide the title text, the toolbar and the traffic lights, and make the titlebar
    // transparent; the tab bar sits where it was. Still `.titled` + `.closable`, so it takes key
    // focus and the edges resize. Not movable: every summon docks it to its edge, and a drag of the
    // tab strip's or a footer's empty space moves it along the edges (`QuickTerminalDragHandle`).
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = nil
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(button)?.isHidden = true
    }
    window.isMovable = false
    // We own the lifetime (nil our refs in `tearDownState`); don't let AppKit free the window on close.
    window.isReleasedWhenClosed = false
    window.delegate = self
    // The autosave restores the user's last size; `show()` sets the position.
    window.setFrameAutosaveName("QuickTerminal")
    // The same environment a detached pane's window gives its pane (`DetachedPaneView`).
    window.contentView = NSHostingView(
      rootView: QuickTerminalContent(sessions: sessions)
        .themeTokensRoot()
        .environment(\.isQuickTerminal, true)
        .environmentObject(store)
        .environmentObject(store.modals)
        .environmentObject(store.runCommand)
        .environmentObject(store.lifecycle)
        .environmentObject(store.notifications)
        .environmentObject(sessions.codingAgentManager)
        .environmentObject(CodingAgentUsageMonitor.shared)
        .environmentObject(ClaudeUsageBridge.shared))
    store.hostWindow = window
    self.window = window
    applyTheme()

    themeObserver = NotificationCenter.default.addObserver(
      forName: .themeDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyTheme() }
    }
  }

  /// Repaint the window background and re-theme every pane for the active theme. On a
  /// `.themeDidChange` the global ghostty config is already reloaded (ThemeService posts the
  /// notification after it reloads); `ThemeService` re-themes only registered stores' panes, so
  /// this store's are pushed here.
  private func applyTheme() {
    guard let window, let store else { return }
    window.backgroundColor = ThemeService.shared.tokens.nsPanel
    store.terminals.applyThemeToAll(isDark: ThemeService.isCurrentAppearanceDark())
  }

  private static func applyTheme(to surface: GhosttySurfaceView) {
    if let config = GhosttyApp.shared.config { surface.updateConfig(config) }
    surface.applyColorScheme(isDark: ThemeService.isCurrentAppearanceDark())
  }

  /// A Quick Terminal key (`QuickTerminalKey`) pressed while its window is key.
  /// What a workroom window's menu does for the same keys, on this store's one target.
  /// False when the key did nothing and belongs to the terminal: a ⌃⌘arrow with no pane that way,
  /// as in a workroom.
  @discardableResult
  func perform(_ key: QuickTerminalKey) -> Bool {
    guard let store else { return true }
    let target = Self.target()
    let sessions = store.terminals
    let active = sessions.activeTab(for: target)
    switch key {
    case .closePane:
      if let active { store.requestCloseTerminalTab(active.id, for: target) }
    case .newTab:
      store.newTerminal(in: target)
    case .splitRight:
      if let active { sessions.splitTab(active.id, on: .right, for: target) }
    case .splitDown:
      if let active { sessions.splitTab(active.id, on: .bottom, for: target) }
    case .selectTab(let index):
      let tabs = sessions.tabs(for: target)
      if tabs.indices.contains(index) { sessions.focus(tabs[index].id, for: target) }
    case .focusPane(let direction):
      return sessions.focusAdjacentPane(direction, for: target)
    }
    return true
  }

  /// A double-click in the tab bar's empty space must not zoom the window off its edge.
  func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }

  /// Full close: destroy the window (its `windowWillClose` runs the teardown). Idempotent.
  func close() {
    window?.close()
  }

  /// At quit: end its panes' background sessions, since its shells are not kept across a quit
  /// (ADR 0064). Its tabs stay open; a quit must not free surfaces.
  func endSessionsAtQuit() {
    store?.terminals.endSessionsAtQuit(for: Self.target())
  }

  /// For the launch sweep: a session tag that still resolves. The Quick Terminal's never does, so a
  /// crash or force quit, which skips `endSessionsAtQuit`, can't leave its shells running unseen.
  nonisolated static func sweepResolves(_ workroomTag: String) -> Bool {
    workroomTag != targetID.encoded
  }

  // MARK: Dragging along the edges

  /// Where a drag docks a window of `size`: on the screen the pointer is over (else `fallback`), to
  /// the edge nearest where the pointer, less where it grabbed the window (`grab`, from the
  /// window's centre), would centre it (`current` is the edge it is on), at that spot along the
  /// edge. Docked all the way, so it slides along the edges and hops between them but never
  /// floats free; the docked spots meet at the corners, so only a hop across the screen jumps.
  static func dragDock(
    size: NSSize, pointer: NSPoint, grab: NSPoint, current: QuickTerminalEdge,
    fallback: NSScreen?
  ) -> (edge: QuickTerminalEdge, offset: Double, frame: NSRect)? {
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? fallback
    else { return nil }
    let visible = screen.visibleFrame
    let center = NSPoint(x: pointer.x - grab.x, y: pointer.y - grab.y)
    let edge = QuickTerminalEdge.nearest(
      forCenter: center, size: size, in: visible, current: current)
    let offset = edge.offset(forCenter: center, size: size, in: visible)
    return (edge, offset, edge.dockedFrame(size: size, in: visible, offset: offset))
  }

  /// A resize from a side moves the window's centre along its edge; keep that for next time.
  func windowDidEndLiveResize(_ notification: Notification) {
    guard let window, let screen = window.screen else { return }
    let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
    let edge = Defaults[.quickTerminalEdge]
    Defaults[.quickTerminalOffset] = edge.offset(
      forCenter: center, size: window.frame.size, in: screen.visibleFrame)
  }

  /// Checked a turn later, once AppKit has made the new window key.
  func windowDidResignKey(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { self?.focusMoved(to: NSApp.keyWindow) }
    }
  }

  /// Focus moved to `newKey` (nil: another app): slide away, unless it went to this window's own
  /// sheet (a clipboard confirmation) or popover (the usage detail), which are not leaving it.
  func focusMoved(to newKey: NSWindow?) {
    guard hidesWhenUnfocused(), let window, window.attachedSheet == nil,
      newKey?.parent !== window
    else { return }
    hide()
  }

  func windowWillClose(_ notification: Notification) {
    tearDownState()
  }

  /// Free the surface via the documented single-steady-state-surface path (clears callbacks first,
  /// then `ghostty_surface_free`) and drop the window — leaving the controller ABSENT so the next
  /// summon is fresh. Re-entrancy-guarded because `close()` → `windowWillClose` re-enters.
  private func tearDownState() {
    guard !tearingDown else { return }
    tearingDown = true
    hiding = false
    if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    themeObserver = nil
    if let store {
      // The window is already going: closing its tabs mustn't ask to close it again.
      store.onTargetEmptied = nil
      let target = Self.target()
      for tab in store.terminals.allTabs(for: target) {
        store.terminals.closeTab(tab.id, for: target)
      }
      // Its notifications go with it, as a closing window's do (#573 D3).
      WindowRegistry.shared.dropNotifications(raisedBy: store)
    }
    store = nil
    window?.delegate = nil
    window = nil
    tearingDown = false
  }
}

/// Posted by the main-toolbar Quick-Terminal button; `AppDelegate` observes it and calls `show()`
/// (the controller lives on the delegate, out of reach of the SwiftUI view). Same decoupled pattern
/// as `.showThemePicker` / `.showKeyboardShortcuts`. The ⌥§ global hotkey calls the controller
/// directly (it's registered in the delegate), so it doesn't go through this.
extension Notification.Name {
  static let showQuickTerminal = Notification.Name("workroom.showQuickTerminal")
}

/// The keys the Quick Terminal answers while its window is key, as a workroom window's menu does
/// for its own tabs: ⌘W closes the focused pane (its tab with its last pane, the window with its
/// last tab), ⌘T opens a tab, ⌘D / ⇧⌘D split right / down, ⌘1–9 pick a tab. Caught in
/// `AppDelegate`'s key monitor, because those menu items target the workroom window.
enum QuickTerminalKey: Equatable {
  case closePane, newTab, splitRight, splitDown
  /// 0-based.
  case selectTab(Int)
  /// ⌃⌘arrows, as in a workroom.
  case focusPane(PaneDirection)

  static func classify(
    flags: NSEvent.ModifierFlags, characters: String?, keyCode: UInt16? = nil
  ) -> QuickTerminalKey? {
    let flags = flags.intersection([.command, .shift, .option, .control])
    // Virtual keycodes, as the workroom handler reads them: left 123 / right 124 / down 125 / up 126.
    let arrows: [UInt16: PaneDirection] = [123: .left, 124: .right, 125: .down, 126: .up]
    if flags == [.command, .control], let keyCode, let direction = arrows[keyCode] {
      return .focusPane(direction)
    }
    guard let key = characters?.lowercased() else { return nil }
    switch (flags, key) {
    case (.command, "w"): return .closePane
    case (.command, "t"): return .newTab
    case (.command, "d"): return .splitRight
    case ([.command, .shift], "d"): return .splitDown
    case (.command, _):
      guard let digit = Int(key), (1...9).contains(digit) else { return nil }
      return .selectTab(digit - 1)
    default: return nil
    }
  }
}
