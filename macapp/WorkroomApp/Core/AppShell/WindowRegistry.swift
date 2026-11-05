import AppKit
import Combine
import Defaults
import SwiftUI

/// The single app-level coordinator for the multi-window world (issue #70). Each window owns its own
/// `AppStore` (per-window selection, terminals, splits, run state); this registry is the *only*
/// shared coordination point above them, for the things that are genuinely app-scoped:
///
/// - **Key/active routing** — the `AppDelegate` key-event monitor and a terminal surface's
///   context-menu actions act on whichever window is key (`keyStore`).
/// - **Last-active capture** — `lastActiveStore` tracks the most recent *workroom* window to become
///   key, captured before any modal (quit alert / Settings) can steal key status, so quit-time
///   persistence reads the right window.
/// - **Aggregation** — the Dock badge (and menu-bar item) sum across every window's notifications.
/// - **Run-command ownership** — a workroom's run command is single-owner across windows; a second
///   window's Run focuses the owner instead of forking a duplicate server (issue #70 / issue #7).
/// - **Quit/close de-dup** — `isTerminating` suppresses the per-window close prompt during a quit.
///
/// Per-window logic stays in `AppStore`; this holds only weak references, so closed windows fall out
/// on the next prune.
@MainActor
final class WindowRegistry: ObservableObject {
  static let shared = WindowRegistry()

  private final class Entry {
    weak var window: NSWindow?
    weak var store: AppStore?
    var sessionObservation: AnyCancellable?
    init(window: NSWindow, store: AppStore) {
      self.window = window
      self.store = store
    }
  }
  private var entries: [Entry] = []

  /// True while the app is terminating, so a window's close handler doesn't prompt/stop run commands
  /// a second time on top of `applicationShouldTerminate` (issue #70, OV #10).
  var isTerminating = false

  /// The most recent registered (workroom) window to become key. Updated only for registered windows,
  /// so a modal alert / Settings becoming key never overwrites it — quit persistence can trust it.
  private(set) weak var lastActiveStore: AppStore?

  /// SwiftUI's `openWindow`, handed over by each window as it appears, so a store can open a window
  /// to move a workroom into (#444). Only views get the environment action.
  var openWindow: ((WindowSeed) -> Void)?

  /// What sits under a screen point, for a workroom dropped there (#444).
  enum DropWindow {
    /// A Workroom window, or the one that owns a torn-off pane's window there (Q22).
    case store(AppStore)
    /// Nothing of ours, or another app's window in front of ours: a new window.
    case none
  }

  /// The frontmost window under `screenPoint`, skipping `skipped` (the drag's own ghost, which sits
  /// under the cursor). Across every app, so a window of another app in front of one of ours wins.
  func dropWindow(at screenPoint: CGPoint, skipping skipped: Set<Int>) -> DropWindow {
    Self.frontmostDropWindow(
      skipping: skipped,
      numberBelow: { NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: $0) },
      resolve: { [self] number in
        guard let window = NSApp.window(withWindowNumber: number) else { return DropWindow.none }
        if let store = store(for: window) { return .store(store) }
        if let pane = window as? DetachedPaneWindow, let tab = pane.tabID,
          let owner = ownerOf(tabID: tab)
        {
          return .store(owner)
        }
        return DropWindow.none
      })
  }

  /// The Workroom window a drag is over at `screenPoint`, looking past the drag's own ghost
  /// (`DetachedPaneDragPreview`), which sits under the cursor.
  func dropStore(at screenPoint: CGPoint) -> AppStore? {
    let ghost = DetachedPaneDragPreview.shared.windowNumber.map { Set([$0]) } ?? []
    guard case .store(let store) = dropWindow(at: screenPoint, skipping: ghost) else { return nil }
    return store
  }

  /// The torn-off pane (issue #172) whose window is in front under `screenPoint`, past the drag's
  /// ghost, if one is. `dropStore` answers with its owner, whose main window it isn't.
  func detachedPane(at screenPoint: CGPoint) -> TerminalTab.ID? {
    let ghost = DetachedPaneDragPreview.shared.windowNumber.map { Set([$0]) } ?? []
    var pane: TerminalTab.ID?
    _ = Self.frontmostDropWindow(
      skipping: ghost,
      numberBelow: { NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: $0) },
      resolve: { number in
        pane = (NSApp.window(withWindowNumber: number) as? DetachedPaneWindow)?.tabID
        return DropWindow.none
      })
    return pane
  }

  /// The walk behind `dropWindow`, front to back: `numberBelow(n)` is the window under the point
  /// below window `n` (0 for the frontmost, 0 when there is none).
  static func frontmostDropWindow(
    skipping skipped: Set<Int>, numberBelow: (Int) -> Int, resolve: (Int) -> DropWindow
  ) -> DropWindow {
    var below = 0
    var seen: Set<Int> = []
    while case let number = numberBelow(below), number > 0, seen.insert(number).inserted {
      guard skipped.contains(number) else { return resolve(number) }
      below = number
    }
    return DropWindow.none
  }

  /// The app's one notification list, shared by every window (ADR 0064).
  let notifications = NotificationCenterStore()
  /// The unread count every surface shows: the bell, the menu bar and the Dock badge (ADR 0064).
  /// `@Published` so they re-render as it changes.
  @Published private(set) var aggregateUnread = 0
  @Published private(set) var activeCodingAgentBackends: Set<CodingAgentBackend> = []

  init() {
    // Driven from the model, not a view: a hidden window's view misses background changes (#32).
    notifications.onTotalChange = { [weak self] _ in self?.recomputeBadge() }
    // Track the active workroom window. Only registered windows update `lastActiveStore`, so the quit
    // alert / Settings / menu-bar popover becoming key leaves the last *workroom* selection intact.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { [weak self] note in
      // Delivered on the main queue (`queue: .main`), so the note never actually crosses threads.
      nonisolated(unsafe) let note = note
      MainActor.assumeIsolated {
        guard let self, let window = note.object as? NSWindow,
          let store = self.store(for: window)
        else { return }
        self.lastActiveStore = store
        // Which window was key is part of the saved session — it decides where the user lands after
        // a restore (issue #46).
        SavedLayoutCoordinator.shared.markDirty()
        // Bringing a window forward makes its selection the most recent one (issue #132). Without
        // this, ⌘` to another window leaves the switcher's MRU head pointing at the window you left,
        // so the next ⌥Tab tap flips somewhere you didn't come from.
        SwitcherRecency.shared.recordWorkroom(store: store, sid: store.selectedTargetID)
        // Put the keyboard back on the focused pane if first responder drifted off it while this
        // window wasn't key (⌘-Tab, Mission Control, a dismissed sheet, a pane unmounted mid-split).
        // Guarded — see `TerminalFocusReconciliation`.
        self.reconcileTerminalFocus(in: window, store: store)
      }
    }
    // Drop a window as it closes (issue #46). `unregister` previously had NO caller: entries were
    // only ever cleared by `prune()` noticing the weak reference had died, which happens whenever the
    // next unrelated lookup runs — so a closed window scheduled no save, and the session file kept
    // describing it until something else happened to mark the session dirty. Filtered to registered
    // workroom windows, so Settings/About/quick terminal closing here is a no-op.
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] note in
      // Delivered on the main queue (`queue: .main`), so the note never actually crosses threads.
      nonisolated(unsafe) let note = note
      MainActor.assumeIsolated {
        guard let self, let window = note.object as? NSWindow, self.store(for: window) != nil
        else { return }
        self.unregister(window: window)
      }
    }
  }

  // MARK: Focus reconciliation

  /// Restore first responder to the focused pane's surface on key-gain, when and only when first
  /// responder has genuinely drifted off it. The complement to `GhosttySurfaceView`'s own
  /// `adoptFocusIfFirstResponder`, which handles the surface-CREATION race but not this one (the
  /// surface already exists; first responder moved away). `makeFirstResponder` routes through
  /// `becomeFirstResponder`, so libghostty's focus flag and the store's logical focus both follow.
  ///
  /// A content pane (diff / file / changeset) has no surface, so a window whose focused tab is one
  /// is left exactly as AppKit restored it — this never drags focus out of a diff into a terminal.
  ///
  /// Ordering: this registry's observer is installed at init, before any surface's own key-window
  /// observer (`GhosttySurfaceView.viewDidMoveToWindow`), so first responder is set here first and
  /// the surface's `syncFocusToKeyWindow` then reads `holdsFirstResponder == true` and no-ops. The
  /// reverse order would be harmless too — `lastSetFocus` dedups, so the TUI never sees a duplicate
  /// DECSET-1004 focus report either way.
  private func reconcileTerminalFocus(in window: NSWindow, store: AppStore) {
    guard let target = store.selectedTarget,
      let surface = store.terminals.focusedTab(for: target)?.surface,
      TerminalFocusReconciliation.shouldRestoreFirstResponder(in: window, to: surface)
    else { return }
    window.makeFirstResponder(surface)
  }

  // MARK: Registration

  /// Register (or re-register) a window with its store. Idempotent — `WindowAccessor` may resolve the
  /// same window more than once. Prunes any dead entries while here.
  func register(window: NSWindow, store: AppStore) {
    prune()
    if let existing = entries.first(where: { $0.window === window }) {
      existing.store = store
    } else {
      let entry = Entry(window: window, store: store)
      entry.sessionObservation = store.terminals.objectWillChange.sink { [weak self] _ in
        // Published terminal state is still the old value during objectWillChange.
        Task { @MainActor in self?.recomputeActiveCodingAgents() }
      }
      entries.append(entry)
    }
    if lastActiveStore == nil { lastActiveStore = store }
    store.forwardToast = { [weak self] in self?.showToast($0) }
    // The saved session is rebuilt from the live windows (issue #46), and the window layer publishes
    // through none of the store's own publishers — so opening a window has to say so itself.
    SavedLayoutCoordinator.shared.markDirty()
    // The two publishing writes wait a turn. `register` is reached from `WindowAccessor`'s
    // `viewDidMoveToWindow`, which SwiftUI runs WHILE it is installing the representable's backing
    // view — i.e. inside a view update — and `assignWindowNumberIfNeeded` (`AppStore.windowNumber`,
    // `@Published`) plus `recomputeBadge` (`aggregateUnread`, `@Published`) both fire
    // `objectWillChange` from there. That is "Publishing changes from within view updates is not
    // allowed, this will cause undefined behavior": measured at exactly 9 faults per launch, all of
    // them this one call path.
    //
    // Deferred here rather than at the `WindowAccessor` callback, which must NOT move: `attachWindow`
    // depends on running pre-display (it sets the window's frame, hides the title bar before the
    // open-time flash, and claims the saved session), and the rest of `register` must stay
    // synchronous too — a window can become key immediately, and `didBecomeKeyNotification`'s handler
    // above bails when `store(for:)` can't find it yet. Only these two are safe to slip: both are
    // derived display state (a Window-menu number, a Dock badge) that nothing reads this turn.
    //
    // A `Task` on the main actor cannot start until the actor yields, which is after the update
    // finishes — that is the whole point, so don't "simplify" this into a direct call.
    Task { @MainActor in
      assignWindowNumberIfNeeded(store)
      recomputeBadge()
      recomputeActiveCodingAgents()
      windowsChanged += 1
    }
  }

  /// Bumped as windows come and go, for views that list them (`QuickTerminalMoveToWorkroomMenu`).
  @Published private(set) var windowsChanged = 0

  /// Give a newly registered window the smallest unused positive number, so the untitled-window
  /// fallback reads "Window 1", "Window 2", … and a closed window's number is reclaimed by the next
  /// new window (macOS untitled-document style). Assigned once per store (0 = not yet numbered).
  private func assignWindowNumberIfNeeded(_ store: AppStore) {
    guard store.windowNumber == 0 else { return }
    let used = Set(entries.compactMap { $0.store?.windowNumber }.filter { $0 > 0 })
    var n = 1
    while used.contains(n) { n += 1 }
    store.windowNumber = n
  }

  func unregister(window: NSWindow) {
    // Close this window's popped-out panes first (issue #172). Their surfaces belong to the store
    // that is going away, so a window left behind would host a view about to be released.
    if let closing = store(for: window) {
      closing.detachedPanes.closeAll()
      dropNotifications(raisedBy: closing)
    }
    entries.removeAll { $0.window === window || $0.window == nil }
    windowsChanged += 1
    recomputeBadge()
    recomputeActiveCodingAgents()
    // Without this a closed window is never noticed, and comes back on the next launch. The quit
    // freeze is what stops the same signal erasing the session as windows close during termination.
    SavedLayoutCoordinator.shared.markDirty()
  }

  private func prune() {
    entries.removeAll { $0.window == nil || $0.store == nil }
  }

  // MARK: Lookup

  /// Every live window's store.
  var allStores: [AppStore] {
    prune()
    return entries.compactMap(\.store)
  }

  func store(for window: NSWindow?) -> AppStore? {
    guard let window else { return nil }
    return entries.first { $0.window === window }?.store
  }

  /// The store of the window that should receive a global key event / surface action: the key window
  /// if it's one of ours, else the last active workroom window, else any.
  var keyStore: AppStore? {
    store(for: keyWindow()) ?? lastActiveStore ?? allStores.first
  }

  /// The key window, `NSApp.keyWindow`. A seam because a test host's windows never become key.
  var keyWindow: () -> NSWindow? = { NSApp.keyWindow }

  /// The frame size a *new* window should open at: the current (last-active, else any) window's full
  /// frame size, so a new window opens at exactly the existing window's size (issue #70). Frame, not
  /// content, size — this app's full-width titlebar toolbar makes the two differ. `nil` when there's
  /// no existing window (the launch window), which then restores its own saved frame / a default.
  var preferredNewWindowSize: CGSize? {
    let window = lastActiveStore?.hostWindow ?? allStores.compactMap(\.hostWindow).first
    return window?.frame.size
  }

  /// The window store that owns the terminal tab `tabID` (each tab id is unique across windows), for
  /// routing an OS-notification click to the right window (issue #70, OV #4).
  func ownerOf(tabID: TerminalTab.ID) -> AppStore? {
    allStores.first { $0.terminals.containsTab(tabID) }
  }

  /// Open a notification's terminal wherever it lives (#573): the window that has the pane comes
  /// forward and focuses it. When no window has it any more, the front window opens the workroom,
  /// if it still exists. Every surface that opens a notification comes through here.
  func open(targetID: TerminalTarget.ID, tabID: TerminalTab.ID?, notifID: UUID?) {
    let owner = tabID.flatMap { ownerOf(tabID: $0) }
    var targetID = targetID
    if targetID == QuickTerminalController.targetID {
      // A banner from a Quick Terminal pane that has since moved into a window: its payload still
      // names the Quick Terminal, so open the pane where it is now.
      guard let owner, let tabID, let moved = owner.terminals.targetID(ofTab: tabID) else {
        notifications.dismiss(notifID: notifID, orTab: tabID)
        quickTerminal?.reveal(tab: tabID)
        return
      }
      targetID = moved
    }
    let store = owner ?? keyStore
    // `window(forTab:)`, not `hostWindow`: a detached pane (issue #172) lives in its own window.
    store?.window(forTab: tabID)?.makeKeyAndOrderFront(nil)
    store?.openTerminal(targetID: targetID, tabID: tabID, notifID: notifID)
  }

  func open(_ note: WorkroomNotification) {
    open(targetID: note.targetID, tabID: note.tabID, notifID: note.id)
  }

  /// A toast shows in the front window, whichever window raised it, the Quick Terminal included
  /// (#573 D2).
  func showToast(_ note: WorkroomNotification) {
    frontStore?.enqueueToast(note)
  }

  /// Drop the notifications `store` raised, banners too, as its window closes (#573 D3). Not on
  /// quit: they die with the process anyway, and a quit should leave delivered banners be.
  func dropNotifications(raisedBy store: AppStore) {
    guard !isTerminating else { return }
    let dropped = notifications.removeAll(from: ObjectIdentifier(store))
    store.systemNotifier.withdraw(
      identifiers: dropped.map { SystemNotifier.payload(for: $0).identifier })
  }

  /// The Quick Terminal: in no window entry here, but its terminals share the notification list.
  weak var quickTerminal: QuickTerminalController?

  /// Every store whose terminals raise notifications: each window's and the Quick Terminal's.
  var notifyingStores: [AppStore] { allStores + [quickTerminal?.store].compactMap { $0 } }

  /// The store of the window in front: the Quick Terminal's while it is the key window.
  var frontStore: AppStore? {
    if let quickTerminal, let window = quickTerminal.currentWindow, keyWindow() === window,
      let store = quickTerminal.store
    {
      return store
    }
    return keyStore
  }

  // MARK: Window cycling (issue #87)

  /// Cycle key focus to the next/previous app window — the "Move focus to next window" shortcut
  /// (⌘` forward, ⇧⌘` backward), driven by the `AppDelegate` key monitor because the focused
  /// terminal surface otherwise swallows the backtick as input. Cycles every workroom window plus
  /// the quick terminal (issue #39), the windows the user actually works in — deliberately not the
  /// Settings / About panels. Works in front-to-back z-order: forward surfaces the window just
  /// behind the front and sends the old front to the back; backward surfaces the backmost — so
  /// repeated presses rotate through *all* windows instead of bouncing between the front two.
  func cycleWindows(forward: Bool) {
    let cycleable = NSApp.orderedWindows.filter(isCycleableWindow)
    guard let plan = Self.cyclePlan(ordered: cycleable, forward: forward) else { return }
    plan.front.makeKeyAndOrderFront(nil)
    plan.sendBack?.orderBack(nil)
  }

  /// A window ⌘`/⇧⌘` should cycle through: a visible, focusable workroom window (one we registered)
  /// or the quick terminal. Excludes panels, the menu-bar status item's window, and anything that
  /// can't become key.
  ///
  /// Internal rather than private so a test can assert the switcher rail's panel is rejected — the
  /// `canBecomeKey` guard is what excludes it, and `SwitcherPanel` relies on that staying true.
  func isCycleableWindow(_ window: NSWindow) -> Bool {
    guard window.isVisible, window.canBecomeKey else { return false }
    // `DetachedPaneWindow` (issue #172) owns no store, so it fails the registry test — but it holds a
    // real pane the user works in, so ⌘` must reach it, exactly as it reaches the quick terminal.
    return store(for: window) != nil || window is QuickTerminalWindow
      || window is DetachedPaneWindow
  }

  /// Pure rotation math for `cycleWindows`, extracted so it's unit-testable without live z-ordering.
  /// `ordered` is the cycleable windows front-to-back. Returns the window to bring forward and, for
  /// the forward direction, the old front window to push to the back (so the rotation visits every
  /// window rather than ping-ponging between the front two). nil when there's nothing to cycle to.
  nonisolated static func cyclePlan<W>(ordered: [W], forward: Bool) -> (front: W, sendBack: W?)? {
    guard ordered.count > 1 else { return nil }
    return forward ? (ordered[1], ordered[0]) : (ordered[ordered.count - 1], nil)
  }

  // MARK: Aggregation

  private func recomputeActiveCodingAgents() {
    let agents = allStores.reduce(into: Set<CodingAgentBackend>()) {
      $0.formUnion($1.terminals.activeCodingAgentBackends)
    }
    if agents != activeCodingAgentBackends { activeCodingAgentBackends = agents }
  }

  /// Mirror the unread count onto the menu-bar label, the bell and the Dock badge. Called when the
  /// list changes and on register/unregister.
  ///
  /// It counts requests a program waits on the user for (#358) while they wait, read or not, plus
  /// every other unread notification; a "needs you" alert is never counted twice.
  func recomputeBadge() {
    let alerts = ProgramStatusAlerts.shared
    alerts.recomputeWaiting()
    let total = notifications.unreadExcludingRequests + alerts.countedWaiting
    if total != aggregateUnread { aggregateUnread = total }
    DockBadge.apply(total)
  }

  // MARK: Run-command ownership

  /// The other window already running `target`'s run command, if any. Derived from each window's live
  /// `runStates` (no separate map to drift): a second window's Run focuses this owner instead of
  /// forking a duplicate dev server on the same port (issue #70 / issue #7).
  func runOwner(for target: TerminalTarget.ID, excluding: AppStore) -> AppStore? {
    allStores.first { $0 !== excluding && ($0.runStates[target]?.isRunning ?? false) }
  }

  /// Whether any window has a live Investigate session (issue #146) for any of `targetIDs` — used
  /// to warn before `deleteWorkroom`/`deleteProject` reap those targets' surfaces. Both delete flows
  /// stop and reap unconditionally (even `.configOnly`, which keeps files but still tears down live
  /// terminals), and neither goes through `hasLiveRunCommand`/`gracefullyStopRuns` (which only know
  /// about `runStates`) — so without this check, deleting silently kills a live agent session with
  /// no wait or warning, and for `.workrooms`/`.fromDisk` also deletes the directory out from under it.
  func hasLiveInvestigateSession(for targetIDs: [TerminalTarget.ID]) -> Bool {
    let ids = Set(targetIDs)
    return allStores.contains { store in
      store.investigateTabs.contains { tabID, targetID in
        ids.contains(targetID)
          && store.terminals.view(forTab: tabID, inTarget: targetID)?.hasLiveProcess == true
      }
    }
  }

  // MARK: Quit

  /// Whether any window's run command (not an Investigate tab) is going: what quitting may keep
  /// running or stop (#522).
  var hasAnyLiveRun: Bool { allStores.contains(where: \.hasLiveRun) }

  /// Ctrl-C every window's live run commands and let them exit before the process dies, so dev
  /// servers release their ports/pidfiles instead of being orphaned by the OS hangup (issue #7).
  /// Calls `completion` once all windows have stopped (or each one's timeout elapses).
  func gracefullyStopAllWindows(timeout: TimeInterval, completion: @escaping () -> Void) {
    let live = allStores.filter(\.stopsRunsBeforeClosing)
    guard !live.isEmpty else {
      completion()
      return
    }
    let group = DispatchGroup()
    for store in live {
      group.enter()
      store.gracefullyStopAllRunCommands(timeout: timeout) { group.leave() }
    }
    group.notify(queue: .main) { completion() }
  }
}

/// A forwarding `NSWindowDelegate` proxy that intercepts only `windowShouldClose:` so a window with a
/// live run command confirms and gracefully stops it before closing (issue #70, A3) — otherwise the
/// dev server is orphaned against a torn-down window (the per-window form of issue #7). Every other
/// delegate message forwards to SwiftUI's original delegate, so scene/restoration behaviour is intact.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
  private weak var store: AppStore?
  private weak var forwarding: NSWindowDelegate?

  init(store: AppStore, forwarding: NSWindowDelegate?) {
    self.store = store
    self.forwarding = forwarding
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    MainActor.assumeIsolated {
      // During an app quit, `applicationShouldTerminate` already prompts + stops every window, so
      // don't prompt again here (de-dup, OV #10). No live run command → nothing to stop, close now.
      guard let store, !WindowRegistry.shared.isTerminating, store.stopsRunsBeforeClosing else {
        return true
      }
      if Defaults[.confirmOnQuit] {
        let alert = NSAlert()
        alert.messageText = "Close this window?"
        alert.informativeText = "It has a running process. Closing the window will stop it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
      }
      // Stop the run command(s), then close — return false now so the surfaces stay alive for the
      // graceful Ctrl-C + wait and are never freed mid-IO (the no-mass-free rule).
      store.gracefullyStopAllRunCommands(timeout: 5) { sender.close() }
      return false
    }
  }

  override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || (forwarding?.responds(to: aSelector) ?? false)
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? { forwarding }
}

/// Bridges a SwiftUI view to its hosting `NSWindow`. Drop it in a `.background(...)`; it resolves
/// `view.window` in `viewDidMoveToWindow` — which fires during window setup, *before* the window is
/// shown — so the owning `AppStore` can register and size the window with no visible resize flash
/// (issue #70).
struct WindowAccessor: NSViewRepresentable {
  let onResolve: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    WindowResolvingView(onResolve: onResolve)
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowResolvingView: NSView {
  private let onResolve: (NSWindow) -> Void

  init(onResolve: @escaping (NSWindow) -> Void) {
    self.onResolve = onResolve
    super.init(frame: .zero)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window { onResolve(window) }
  }
}

/// Hands back the `NSView` behind a SwiftUI view, for asking AppKit where that view is on screen.
struct ViewAnchor: NSViewRepresentable {
  let onMake: (NSView) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    onMake(view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
