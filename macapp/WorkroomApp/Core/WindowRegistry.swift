import AppKit
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

  /// Combined unread notification count across every window — drives the menu-bar label + Dock badge
  /// (issue #70). `@Published` so the `MenuBarExtra` label re-renders as any window's count changes.
  @Published private(set) var aggregateUnread = 0

  init() {
    // Track the active workroom window. Only registered windows update `lastActiveStore`, so the quit
    // alert / Settings / menu-bar popover becoming key leaves the last *workroom* selection intact.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated {
        guard let self, let window = note.object as? NSWindow,
          let store = self.store(for: window)
        else { return }
        self.lastActiveStore = store
        // Bringing a window forward makes its selection the most recent one (issue #132). Without
        // this, ⌘` to another window leaves the switcher's MRU head pointing at the window you left,
        // so the next ⌥Tab tap flips somewhere you didn't come from.
        SwitcherRecency.shared.recordWorkroom(store: store, sid: store.selectedTargetID)
      }
    }
  }

  // MARK: Registration

  /// Register (or re-register) a window with its store. Idempotent — `WindowAccessor` may resolve the
  /// same window more than once. Prunes any dead entries while here.
  func register(window: NSWindow, store: AppStore) {
    prune()
    if let existing = entries.first(where: { $0.window === window }) {
      existing.store = store
    } else {
      entries.append(Entry(window: window, store: store))
    }
    assignWindowNumberIfNeeded(store)
    if lastActiveStore == nil { lastActiveStore = store }
    recomputeBadge()
  }

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
    entries.removeAll { $0.window === window || $0.window == nil }
    recomputeBadge()
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
    store(for: NSApp.keyWindow) ?? lastActiveStore ?? allStores.first
  }

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
    return store(for: window) != nil || window is QuickTerminalWindow
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

  /// Mirror the *combined* unread count across all windows onto the menu-bar label + Dock badge
  /// (issue #70). Replaces the per-store `DockBadge.apply` so a second window can't clobber the
  /// first's count. Called from each store's `notifications.onTotalChange` and on register/unregister.
  func recomputeBadge() {
    aggregateUnread = allStores.reduce(0) { $0 + $1.notifications.total }
    DockBadge.apply(aggregateUnread)
  }

  // MARK: Run-command ownership

  /// The other window already running `target`'s run command, if any. Derived from each window's live
  /// `runStates` (no separate map to drift): a second window's Run focuses this owner instead of
  /// forking a duplicate dev server on the same port (issue #70 / issue #7).
  func runOwner(for target: TerminalTarget.ID, excluding: AppStore) -> AppStore? {
    allStores.first { $0 !== excluding && ($0.runStates[target]?.isRunning ?? false) }
  }

  // MARK: Quit

  /// Any window with a live run command — gates the graceful-stop-on-quit (issue #7 / #70).
  var hasAnyLiveRunCommand: Bool { allStores.contains(where: \.hasLiveRunCommand) }

  /// Ctrl-C every window's live run commands and let them exit before the process dies, so dev
  /// servers release their ports/pidfiles instead of being orphaned by the OS hangup (issue #7).
  /// Calls `completion` once all windows have stopped (or each one's timeout elapses).
  func gracefullyStopAllWindows(timeout: TimeInterval, completion: @escaping () -> Void) {
    let live = allStores.filter(\.hasLiveRunCommand)
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
      guard let store, !WindowRegistry.shared.isTerminating, store.hasLiveRunCommand else {
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
