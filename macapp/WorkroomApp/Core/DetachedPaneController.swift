import AppKit
import SwiftUI

/// Marker type for a popped-out pane's window (issue #172), so the `AppDelegate` key monitor and
/// `WindowRegistry` can recognise it the way they already recognise `QuickTerminalWindow`.
final class DetachedPaneWindow: NSWindow {}

/// The windows holding popped-out panes (issue #172). One per detached tab, owned by the `AppStore`
/// whose `TerminalSessions` still owns the tab — so a detached window's lifetime is a subset of its
/// store's, and closing the origin window can never strand a window over a freed surface.
///
/// ```
///                 detach ── drag the pane title bar past the window edge
///                        └─ or "Open in New Window" (title-bar button / View menu)
///                               │
///    ┌──────────────────┐       ▼        ┌────────────────────────────┐
///    │      DOCKED      │ ─────────────▶ │         DETACHED           │
///    │ a leaf of the    │                │ its own DetachedPaneWindow;│
///    │ pane tree        │ ◀───────────── │ the tab stays in the       │
///    └──────────────────┘   dock         │ ORIGIN store's sessions    │
///         │                  ├─ Dock button        → solo            │
///         │                  └─ drag onto a pane edge → splits there │
///         │                                └────────────────────────────┘
///         │                                          │
///         │           quit ─▶ session.json records `detachedFrame`
///         │                   relaunch restores it DETACHED ──┘
///         │
///    pane ✕                             red button · ⌘W · the pane's own ✕
///         │                                          │
///         └──────────────────▶ ┌──────────┐ ◀────────┘
///                              │  CLOSED  │
///                              └──────────┘
///           closeTab → onTabsRemoved → the detached window closes as a CONSEQUENCE
/// ```
///
/// Three asymmetries, all deliberate, all easy to get backwards:
///
/// 1. The window's **red button and ⌘W close the pane**, not merely the window — Chrome / VS Code
///    tear-off semantics. They route through `requestCloseTerminalTab`, so a live process still gets
///    its confirmation (which is presented by `RootView`, i.e. on the ORIGIN window).
/// 2. The **Dock button closes the window and keeps the pane.** It is the only close-shaped action
///    that does, and it goes through `closeWithoutClosingTab`.
/// 3. `onTabsRemoved` closing a window is a *consequence* of the tab dying, never the cause. Nothing
///    here may close a window in order to close a tab.
///
/// Deliberately **not** registered in `WindowRegistry`: these windows own no `AppStore`, and
/// registering them would make `AppDelegate.shortcutStore(for:)` route ⌘T / ⌘1–9 to the *origin*
/// store while a detached window is key — actively wrong. Unregistered, they inherit the monitor's
/// auxiliary-window semantics instead (⌘W closes the front window, which is what we want). The one
/// exception is `WindowRegistry.isCycleableWindow`, which allows them by class so ⌘` reaches them.
@MainActor
final class DetachedPaneWindows {
  /// Fallback size for a pane that was never measured (nothing has laid it out yet, so
  /// `TerminalSessions.paneRects` has no entry for it).
  static let fallbackSize = NSSize(width: 720, height: 480)

  private var windows: [TerminalTab.ID: DetachedPaneWindow] = [:]
  /// Set while `close(tabID:)` is tearing a window down, so the `windowShouldClose` delegate hook
  /// doesn't re-enter and try to close the tab we are merely un-hosting.
  private var closingWithoutTab: Set<TerminalTab.ID> = []
  private var delegates: [TerminalTab.ID: Delegate] = [:]

  /// Whether this tab currently has a window — the controller's half of the detached invariant.
  func hasWindow(for tabID: TerminalTab.ID) -> Bool { windows[tabID] != nil }

  /// The window hosting `tabID`, for the raise paths (`AppStore.window(forTab:)`).
  func window(for tabID: TerminalTab.ID) -> NSWindow? { windows[tabID] }

  /// The live frame of a detached pane's window, for session capture. Read from the window itself
  /// rather than a cached copy, so a user-moved window is persisted where it actually is.
  func frame(for tabID: TerminalTab.ID) -> NSRect? { windows[tabID]?.frame }

  /// Open a window for a freshly-detached pane. `origin` is a SCREEN point (the cursor at drop time);
  /// the window is placed so its top-left lands there, then nudged onto a visible screen.
  func open<Content: View>(
    tabID: TerminalTab.ID, title: String, measuredSize: CGSize?, origin: CGPoint?,
    frame: NSRect? = nil, onCloseTab: @escaping () -> Void, content: () -> Content
  ) {
    guard windows[tabID] == nil else {
      windows[tabID]?.makeKeyAndOrderFront(nil)
      return
    }
    let size = frame?.size ?? Self.sized(measuredSize)
    let window = DetachedPaneWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = title
    // We own the lifetime (see `close`); don't let AppKit free the window out from under us.
    window.isReleasedWhenClosed = false
    // Only the window-level a11y id in this app besides the onboarding window's — XCUITest has no
    // other way to scope a query to this window (see `DetachedPaneUITests`).
    window.setAccessibilityIdentifier("detachedPane.window")
    window.contentView = NSHostingView(rootView: content())
    if let frame {
      window.setFrame(Self.onVisibleScreen(frame), display: false)
    } else if let origin {
      window.setFrameTopLeftPoint(origin)
      window.setFrame(Self.onVisibleScreen(window.frame), display: false)
    } else {
      window.center()
    }
    let delegate = Delegate(
      onCloseTab: onCloseTab,
      isSuppressed: { [weak self] in
        self?.closingWithoutTab.contains(tabID) ?? false
      })
    window.delegate = delegate
    delegates[tabID] = delegate
    windows[tabID] = window
    window.makeKeyAndOrderFront(nil)
  }

  /// Close a detached pane's window WITHOUT closing its tab — a dock, or a teardown where the tab is
  /// already being removed by someone else. Idempotent.
  func close(tabID: TerminalTab.ID) {
    guard let window = windows[tabID] else { return }
    closingWithoutTab.insert(tabID)
    window.delegate = nil
    window.close()
    closingWithoutTab.remove(tabID)
    windows[tabID] = nil
    delegates[tabID] = nil
  }

  /// Close every detached window this store owns — the origin window is going away, and its surfaces
  /// are about to be released.
  func closeAll() {
    for tabID in windows.keys { close(tabID: tabID) }
  }

  /// The window size for a pane, floored so a never-measured or degenerate pane still opens usable.
  private static func sized(_ measured: CGSize?) -> NSSize {
    guard let measured, measured.width > 100, measured.height > 100 else { return fallbackSize }
    return NSSize(width: measured.width, height: measured.height)
  }

  /// Nudge a frame back onto a screen that still exists — the same protection `AppStore`'s restored
  /// main-window frame gets, and for the same reason: unplug the display a detached pane was on and
  /// it would otherwise reopen somewhere unreachable.
  static func onVisibleScreen(_ frame: NSRect) -> NSRect {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return frame }
    if screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return frame }
    let target = (NSScreen.main ?? screens[0]).visibleFrame
    var moved = frame
    moved.size.width = min(moved.width, target.width)
    moved.size.height = min(moved.height, target.height)
    moved.origin = CGPoint(x: target.midX - moved.width / 2, y: target.midY - moved.height / 2)
    return moved
  }

  /// Turns the window's own close (red button, ⌘W) into a request to close the TAB — asymmetry 1
  /// above. Returning `false` lets `requestCloseTerminalTab` run its confirmation first; the window
  /// then closes as a consequence, via `onTabsRemoved` → `undetach` → `close(tabID:)`.
  private final class Delegate: NSObject, NSWindowDelegate {
    private let onCloseTab: () -> Void
    private let isSuppressed: () -> Bool
    init(onCloseTab: @escaping () -> Void, isSuppressed: @escaping () -> Bool) {
      self.onCloseTab = onCloseTab
      self.isSuppressed = isSuppressed
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
      if isSuppressed() { return true }
      onCloseTab()
      return false
    }
  }
}
