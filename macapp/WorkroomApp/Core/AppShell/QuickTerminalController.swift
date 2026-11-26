import AppKit
import Defaults
import SwiftUI
import WorkroomDomain

/// Marker type for the quick-terminal window so the `AppDelegate` key monitor can recognise it and
/// route ⌘W to close it. (The app rebinds ⌘W to a "Close Tab" menu command that targets the
/// main window's tabs and wins over a window's own `performKeyEquivalent`, so ⌘W is caught in the
/// monitor — the same mechanism the app already uses for ⌘R / ⌘1–9.)
///
/// A non-activating panel: summoned over another app, it takes key focus and keyboard input
/// without activating Workroom, so the app's other windows stay where they are, behind whatever
/// the user was working in, and the panel sits alongside that app.
final class QuickTerminalWindow: NSPanel {
  // AppKit pulls a titled window back on-screen, so the slide could never start off-screen.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  // A panel closes on Esc (`cancelOperation`) that nothing before it took, which here would slide
  // it away mid-typing. Behave as a window does: Esc is the terminal's and its views'.
  override func cancelOperation(_ sender: Any?) {}
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

/// The "quick terminal" (issue #39): the panel of the built-in terminal group (ADR 0077), a
/// chrome-less window that slides in from a screen edge, Quake-style, summoned by the ⌥§ global
/// hotkey, the main-toolbar button or the group's sidebar row. One persistent controller owns one
/// host for the app's life, and at most one window:
///
/// ```
///   ABSENT  ──⌥§ / button──▶ VISIBLE      create the window, a fresh terminal when it has none, slide in
///   VISIBLE ──⌥§───────────▶ HIDDEN       slide out, orderOut — terminals kept (scrollback / process persist)
///   HIDDEN  ──⌥§ / button──▶ VISIBLE      slide in, focus the SAME terminal
///   VISIBLE ──last terminal closes──▶ HIDDEN   the next summon opens a fresh terminal
/// ```
///
/// A toggle (`toggle()`, the hotkey) can hide; the button (`show()`) only ever brings the window
/// forward. Its terminals are ordinary ones: they survive a quit, and its layout is saved as its own
/// entry in `session.json` and restored at launch (`restore`), so their sessions reattach and
/// notify before it is first summoned.
///
/// Its tabs and panes are a workroom's — the same `WorkroomTerminalsView`, tab strip and pane tree,
/// so they look and behave the same — over its own `QuickTerminalHost`, which is never registered
/// with `WindowRegistry` as a window (ADR 0064) but is a holder of the Terminals section. Its panes
/// can be popped out into windows of their own.
/// The window is a non-activating AppKit `NSPanel`, not a SwiftUI scene, for exact chrome control,
/// and follows live theme switches, which `ThemeService` only takes to registered stores.
@MainActor
final class QuickTerminalController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  /// What hosts the Quick Terminal's panes, from its first summon or restore for the app's life.
  private(set) var host: QuickTerminalHost?
  /// The Terminals section its group is in. Set before the host is made; tests stand in their own.
  var section: TerminalsSection {
    get { sectionOverride ?? .shared }
    set { sectionOverride = newValue }
  }
  private var sectionOverride: TerminalsSection?
  /// Its saved layout until the host has restored it, written back as it was read meanwhile so a
  /// save before then doesn't lose it (as a window holds back a target it can't restore yet).
  private var pendingSession: TargetSession?

  /// The Quick Terminal's one target, the built-in group's: no workroom. `path` is where a new
  /// tab's shell starts, the group's starting folder or "New terminals open in".
  /// Built from the group directly, not through the section's lookup, which would read every
  /// holder's terminal names for a title that is fixed.
  static func target(in section: TerminalsSection = .shared) -> TerminalTarget {
    let group = section.quickTerminal
    return TerminalTarget(
      id: targetID, title: group.name ?? "Quick Terminal",
      path: group.workingDirectory(presence: section.folderPresence), unavailability: nil)
  }
  nonisolated static let targetID: TerminalTarget.ID = .quickTerminal
  /// Its symbol in a Move to… menu: a panel sliding in from the top.
  static let glyph = "rectangle.topthird.inset.filled"
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
  /// Slides the panel away as the app hides (⌘H), which it doesn't by itself (`canHide`).
  private var appHideObserver: NSObjectProtocol?
  /// Answers `QuickTerminalRequest`s for the controller's life (`observeRequests`).
  private var requestObserver: NSObjectProtocol?

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

  /// The folder a new quick-terminal shell starts in: the setting with `~` expanded, or the home
  /// folder when it is empty or no longer a folder (deleted, or on an unmounted or stalled
  /// volume). Synchronous callers (a new tab) get `presence`'s last answer, so the main actor never
  /// stats a user-set folder; a folder not checked yet is taken as there while its check runs.
  static func workingDirectory(
    for setting: String, presence: FolderPresence = .shared
  ) -> String {
    let path = (setting as NSString).expandingTildeInPath
    // An empty setting expands to "", which no folder matches.
    guard !path.isEmpty, presence.isFolder(path) else { return NSHomeDirectory() }
    return path
  }

  /// `workingDirectory(for:)` from a fresh, bounded check, for a caller that can wait for one.
  static func checkedWorkingDirectory(
    for setting: String, presence: FolderPresence = .shared
  ) async -> String {
    let path = (setting as NSString).expandingTildeInPath
    guard !path.isEmpty, await presence.check(path) else { return NSHomeDirectory() }
    return path
  }

  /// Whether losing key focus slides the window away (Settings ▸ Terminal). Overridable in tests,
  /// so no shared `Defaults` write races the parallel test workers.
  var hidesWhenUnfocused: @MainActor () -> Bool = { Defaults[.quickTerminalHidesWhenUnfocused] }
  /// Following a press in another window till its button comes up (`focusMoved`).
  private var mouseUpWait: Timer?
  /// Makes a press in another window act at once while the panel has focus (`watchPresses`).
  private var pressMonitor: Any?

  /// True while a window is on screen and not sliding out. False when ABSENT or HIDDEN.
  var isVisible: Bool { !hiding && (window?.isVisible ?? false) }
  /// True while a window exists (VISIBLE or HIDDEN) — inspection aid for tests.
  var hasWindow: Bool { window != nil }
  /// The focused pane's surface (VISIBLE or HIDDEN), else nil.
  var currentSurface: GhosttySurfaceView? {
    host.flatMap { $0.terminals.focusedSurface(for: $0.target) }
  }
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

  /// Answer the views' `QuickTerminalRequest`s from now on. `center` is the app's, or a test's own.
  func observeRequests(in center: NotificationCenter = .default) {
    if let requestObserver { center.removeObserver(requestObserver) }
    requestObserver = center.addObserver(
      forName: QuickTerminalRequest.notification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let request = QuickTerminalRequest(notification) else { return }
      MainActor.assumeIsolated { self?.handle(request) }
    }
  }

  func handle(_ request: QuickTerminalRequest) {
    switch request {
    case .show: show()
    case .toggle: toggle()
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
    }
    let host = ensureHost()
    // Its last terminal closed, or left for a window of its own, and hid it: a summon opens a fresh
    // one in the panel.
    if !host.hasDockedTab {
      _ = host.terminals.addTab(for: host.target)
    }
    if window == nil { createWindow(host) }
    // A focused pane that is popped out has no surface here: its slot shows its placeholder, and
    // the panel still comes in on it (issue #172).
    guard let window, currentSurface != nil || host.terminals.focusedTab(for: host.target) != nil
    else { return }
    // No `NSApp.activate`: that would bring every Workroom window forward with it. The panel is
    // non-activating, so it takes focus over whatever app is frontmost (or while Workroom is
    // hidden: it doesn't hide with the app) and leaves the rest of Workroom where it was.
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
      bringForward(window)
      slide(window, to: docked)
    } else {
      bringForward(window)
    }
    if let surface = currentSurface { window.makeFirstResponder(surface) }
  }

  /// A notification from one of its panes was clicked: slide in on that pane. Its host is no
  /// `WindowRegistry` window, so the app's usual notification routing can't find it.
  func reveal(tab tabID: TerminalTab.ID?) {
    if let tabID, let host, host.terminals.tab(tabID, for: host.target) != nil {
      // A popped-out pane is in a window of its own: that comes forward instead.
      if host.raiseDetachedPane(tabID) { return }
      host.terminals.focus(tabID, for: host.target)
    }
    show()
  }

  /// Front and key, over the frontmost app's windows when Workroom isn't active.
  private func bringForward(_ window: NSWindow) {
    window.orderFrontRegardless()
    window.makeKey()
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

  /// The host, made once: its terminals outlive the window, a hide and the last one closing. It
  /// registers with the Terminals section as the built-in group's holder as it is made.
  @discardableResult
  func ensureHost() -> QuickTerminalHost {
    if let host { return host }
    // Its terminals' notifications join the app's one list (ADR 0064).
    let host = QuickTerminalHost(
      notifications: WindowRegistry.shared.notifications, section: section)
    let panes = host.terminals
    panes.sessionService = sessionService
    panes.readsPaneBranches = true
    // Its panes pop out into windows of their own, or move into a workroom open in any window.
    panes.moveToWorkroomChoices = { [weak host] tabID, target in
      host?.paneMoveChoices(tabID, of: target) ?? []
    }
    panes.dropOutsideWindow = { [weak host] tabID, target in
      guard let host else { return false }
      return QuickTerminalPaneDrag.end(
        source: host.terminals, notifications: host.notifications, tabID: tabID, target: target)
    }
    panes.makeView = { [weak self] _, directory, command in
      let surface =
        self?.makeSurface(directory, command)
        ?? GhosttySurfaceView(workingDirectory: directory, command: command)
      Self.applyTheme(to: surface)
      return surface
    }
    // Closing the last tab, by ⌘W, its ✕ or its shell's exit, hides the panel; the group stays.
    host.onTargetEmptied = { [weak self] _ in self?.hide() }
    host.onReveal = { [weak self] tabID in self?.reveal(tab: tabID) }
    // Toasts show in the front window, this one while it is key (#573 D2).
    host.forwardToast = { WindowRegistry.shared.showToast($0) }
    self.host = host
    themeObserver = NotificationCenter.default.addObserver(
      forName: .themeDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyTheme() }
    }
    return host
  }

  /// Reattaches restored panes to their live sessions. Tests stand in their own, with no helper.
  var recoverSessions: @MainActor (TerminalPanes, (TerminalTarget.ID) -> Bool) async -> Void = {
    await PersistentSessionRecovery.recover(in: $0, reattaches: $1)
  }

  /// `restore` from the app's launch: holds `saved` at once, for any save before it lands.
  func restoreAtLaunch(_ saved: TargetSession?) {
    guard let saved else { return }
    pendingSession = saved
    Task { await restore(saved) }
  }

  /// At launch: bring back the panel's saved layout (`session.json`'s Quick Terminal entry), hidden,
  /// so its sessions reattach and notify before it is first summoned. Nothing to restore makes no
  /// host. A target it can't open here (its folder gone) keeps its panes, starting fresh shells.
  func restore(_ saved: TargetSession?) async {
    guard let saved else { return }
    pendingSession = saved
    await sessionService.prepareBackend()
    defer { pendingSession = nil }
    // Its folder is stat-ed off the main actor, once, before anything is restored: a stalled
    // mount costs the restore `restoreStatTimeout` and its panes start fresh shells. The group's
    // starting folder is checked first, so a stalled one starts in "New terminals open in".
    _ = await section.quickTerminal.checkedWorkingDirectory(presence: section.folderPresence)
    let path = Self.target(in: section).path
    let reattaches = await FolderPresence.exists(
      path, timeout: restoreStatTimeout, stat: restoreStat)
    let host = ensureHost()
    let target = host.target
    guard host.terminals.tabCount(forTargetID: target.id) == 0 else { return }
    host.terminals.restore(saved, for: target)
    await recoverSessions(host.terminals) { id in id == .quickTerminal && reattaches }
  }

  /// How long `restore`'s stat of the panel's folder may take before its panes start fresh.
  var restoreStatTimeout: TimeInterval = 3
  /// `restore`'s stat of the panel's folder, blocking. A seam for tests; nil for the disk.
  var restoreStat: (@Sendable (String) -> Bool)?

  /// What `session.json` keeps of the panel: its panes now, or its saved layout while that is
  /// still being restored. Nil when it has none.
  func captureSession() -> TargetSession? {
    host?.captureSession() ?? pendingSession
  }

  /// While the panel has focus, a press in one of the app's windows makes that window key before
  /// AppKit sees it, so the press acts at once, as in a key window, instead of only bringing the
  /// window forward: it can start a drag of terminals onto the panel's tabs (#652), which stays up
  /// till the button comes up (`focusMoved`).
  private func watchPresses() {
    guard pressMonitor == nil else { return }
    pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      nonisolated(unsafe) let event = event
      MainActor.assumeIsolated {
        guard let self, let window = self.window, window.isKeyWindow, self.isVisible,
          let other = event.window, other !== window, other.parent !== window,
          !other.isKeyWindow, other.canBecomeKey
        else { return }
        other.makeKey()
      }
      return event
    }
  }

  private func createWindow(_ host: QuickTerminalHost) {
    watchPresses()
    let window = QuickTerminalWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    window.title = "Quick Terminal"
    // A panel hides when its app deactivates by default; this one shows over other apps, and
    // `hidesWhenUnfocused` decides whether losing focus slides it away.
    window.hidesOnDeactivate = false
    // Summoned on whichever Space is current, a full-screen app's included, rather than switching
    // to the Space it was last on.
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    // Shown while Workroom is hidden without unhiding its windows; ⌘H slides it away instead.
    window.canHide = false
    appHideObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willHideNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.hide() }
    }
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
    window.contentView = NSHostingView(
      rootView: QuickTerminalContent(host: host).quickTerminalEnvironment(host: host))
    // Glass now, as its root (`QuickTerminalContent`) will resolve it, not when that first mounts.
    WindowBackgroundThemer.applyResolved(to: window, titlebar: .hidden)
    host.hostWindow = window
    self.window = window
    applyTheme()
  }

  /// Re-theme every pane for the active theme. On a `.themeDidChange` the global ghostty config is
  /// already reloaded (ThemeService posts the notification after it reloads); `ThemeService`
  /// re-themes only registered stores' panes, so this host's are pushed here. The window background
  /// is its Glass root's (`QuickTerminalContent`, #731), which re-applies on the same notification.
  private func applyTheme() {
    guard let host else { return }
    host.terminals.applyThemeToAll(isDark: ThemeService.isCurrentAppearanceDark())
  }

  private static func applyTheme(to surface: GhosttySurfaceView) {
    surface.applyColorScheme(isDark: ThemeService.isCurrentAppearanceDark())
  }

  /// A Quick Terminal key (`QuickTerminalKey`) pressed while its window is key.
  /// What a workroom window's menu does for the same keys, on this host's one target.
  /// False when the key did nothing and belongs to the terminal: a ⌃⌘arrow with no pane that way,
  /// as in a workroom.
  @discardableResult
  func perform(_ key: QuickTerminalKey) -> Bool {
    guard let host else { return true }
    let target = host.target
    let panes = host.terminals
    let active = panes.activeTab(for: target)
    switch key {
    case .closePane:
      if let active { host.requestCloseTerminalTab(active.id, for: target) }
    case .newTab:
      host.newTerminal(in: target)
    case .splitRight:
      if let active { panes.splitTab(active.id, on: .right, for: target) }
    case .splitDown:
      if let active { panes.splitTab(active.id, on: .bottom, for: target) }
    case .selectTab(let index):
      let tabs = panes.tabs(for: target)
      if tabs.indices.contains(index) { panes.focus(tabs[index].id, for: target) }
    case .focusPane(let direction):
      return panes.focusAdjacentPane(direction, for: target)
    }
    return true
  }

  /// A double-click in the tab bar's empty space must not zoom the window off its edge.
  func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }

  /// Destroys the window, keeping its terminals: the next summon builds a new window over them.
  /// Only tests and the app's own exit close it; the user's ways out hide it. Idempotent.
  func close() {
    window?.close()
  }

  /// A close asked of the window hides it instead: the panel is the group's, which never closes.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hide()
    return false
  }

  /// For the launch sweep: a session tag that still resolves. Only an older build's Quick Terminal
  /// tag doesn't: that build ended its shells at quit, so one still running was left by a crash or
  /// force quit and has nothing to come back to. Today's are the built-in group's, which reattach.
  nonisolated static func sweepResolves(_ workroomTag: String) -> Bool {
    workroomTag != TargetID.legacyQuickTerminalTag
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
  ///
  /// Focus that moved with the button down is a press in another window, which may start a drag
  /// of terminals onto this panel's tabs (#652): the panel waits for the button to come up, and
  /// stays if it was let go over the panel.
  func focusMoved(to newKey: NSWindow?) {
    guard hidesWhenUnfocused(), let window, window.attachedSheet == nil,
      newKey?.parent !== window
    else { return }
    if NSEvent.pressedMouseButtons & 1 != 0 { return waitForMouseUp() }
    hide()
  }

  /// A drag of terminals is starting in a window (`TerminalDragSession`): the panel, while it
  /// shows, comes in front of that window without taking focus, so its tabs can take the drop.
  func holdForDrag() {
    guard isVisible, let window else { return }
    window.orderFront(nil)
  }

  private func waitForMouseUp() {
    guard mouseUpWait == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        self?.mouseUpWait?.invalidate()
        self?.mouseUpWait = nil
        self?.mouseCameUp()
      }
    }
    // Common modes: a drag runs AppKit's event-tracking loop.
    RunLoop.main.add(timer, forMode: .common)
    mouseUpWait = timer
  }

  /// The press that took focus away ended: let go over the panel (a drop on its tabs), it takes
  /// focus back and stays; anywhere else, it slides away as focus moving would have had it.
  private func mouseCameUp() {
    guard let window, isVisible, NSApp.keyWindow !== window else { return }
    if window.frame.contains(NSEvent.mouseLocation) { return bringForward(window) }
    focusMoved(to: NSApp.keyWindow)
  }

  func windowWillClose(_ notification: Notification) {
    tearDownState()
  }

  /// Drops the window and nothing else. Its terminals and their sessions are the built-in group's,
  /// which outlive the window: closing them here would end shells a quit must keep (ADR 0077), on
  /// any quit path, AppKit closing windows at exit included. Re-entrancy-guarded because `close()`
  /// → `windowWillClose` re-enters.
  private func tearDownState() {
    guard !tearingDown else { return }
    tearingDown = true
    mouseUpWait?.invalidate()
    mouseUpWait = nil
    if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
    pressMonitor = nil
    if let appHideObserver { NotificationCenter.default.removeObserver(appHideObserver) }
    appHideObserver = nil
    hiding = false
    host?.hostWindow = nil
    window?.delegate = nil
    window = nil
    tearingDown = false
  }
}

/// What a view asks of the Quick Terminal, out of reach of its controller (which lives on the
/// `AppDelegate`): posted as one notification carrying the request, which the controller answers
/// (`observeRequests`). Same decoupled pattern as `.showThemePicker`. The global shortcut calls the
/// controller directly (it's registered in the delegate), so it doesn't go through this.
enum QuickTerminalRequest: String {
  /// Slide in and focus, never hide: the toolbar button, its sidebar row.
  case show
  /// Slide in, or out while it shows: the menu item, which answers the shortcut where no global
  /// hotkey holds it (a Debug build), as the hotkey does.
  case toggle

  static let notification = Notification.Name("workroom.quickTerminal")
  private static let key = "request"

  func post(in center: NotificationCenter = .default) {
    center.post(name: Self.notification, object: nil, userInfo: [Self.key: rawValue])
  }

  init?(_ notification: Notification) {
    guard let raw = notification.userInfo?[Self.key] as? String else { return nil }
    self.init(rawValue: raw)
  }
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

  /// The Quick Terminal key a press is, through the same shortcuts a workroom window uses (#148):
  /// Close Tab, New Terminal, Split Right/Down, Focus Terminal Tab 1–9 and Focus Pane.
  /// `characters` is the key's unshifted character.
  static func classify(
    flags: NSEvent.ModifierFlags, characters: String?, keyCode: UInt16? = nil,
    table: ShortcutTable = Shortcuts.current
  ) -> QuickTerminalKey? {
    guard
      let chord = KeyChord(
        keyCode: keyCode.map(Int.init) ?? -1, flags: flags, unshifted: characters),
      let match = table.match(chord)
    else { return nil }
    return QuickTerminalKey(match)
  }

  /// The Quick Terminal key a matched shortcut is, if it is one.
  init?(_ match: ShortcutMatch) {
    if let index = match.action.terminalTabIndex {
      self = .selectTab(index)
      return
    }
    if let direction = match.action.paneDirection {
      self = .focusPane(direction)
      return
    }
    switch match.action {
    case .closeTab: self = .closePane
    case .newTerminal: self = .newTab
    case .splitRight: self = .splitRight
    case .splitDown: self = .splitDown
    default: return nil
    }
  }
}
