import AppKit
import Defaults
import SwiftUI

/// The title bar's right-click menu: "Show Tabs", the same app-wide value as
/// Settings ▸ Appearance's "Show tabs in the title bar". A tab's own right-click menu carries the
/// same item (`WorkroomTabChip`); this one covers the rest of the bar, which is how the tabs come
/// back once they're hidden.
///
/// A window-local right-click (and control-click) monitor, not a SwiftUI `.contextMenu`: the empty bar has to stay
/// AppKit's title-bar drag region, which a hit-testable SwiftUI shape there would take away (and
/// with it double-click to zoom, see `RootView.detail`). A right-click on a tab is left to the tab's
/// own menu, and one on the window's own buttons (the traffic lights) to AppKit.
struct TitlebarContextMenu: NSViewRepresentable {
  /// Whether a right-click at a screen point lands on a title-bar tab.
  let isOverTab: (CGPoint) -> Bool

  func makeNSView(context: Context) -> MenuView {
    let view = MenuView()
    view.isOverTab = isOverTab
    return view
  }

  func updateNSView(_ nsView: MenuView, context: Context) {
    nsView.isOverTab = isOverTab
  }

  static func dismantleNSView(_ nsView: MenuView, coordinator: ()) {
    nsView.stopMonitoring()
  }

  final class MenuView: NSView {
    var isOverTab: (CGPoint) -> Bool = { _ in false }
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      // A control-click is a right-click too, as it is on the tabs' own menus.
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
        [weak self] event in
        guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
          let self, self.showsMenu(for: event)
        else { return event }
        NSMenu.popUpContextMenu(Self.menu(), with: event, for: self)
        return nil
      }
    }

    func stopMonitoring() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    /// In this window's title bar, and on neither a tab nor one of the window's own buttons.
    private func showsMenu(for event: NSEvent) -> Bool {
      guard let window, event.window === window else { return false }
      let point = event.locationInWindow
      guard point.y >= window.contentLayoutRect.maxY else { return false }
      if let frame = window.contentView?.superview,
        frame.hitTest(frame.convert(point, from: nil)) is NSButton
      {
        return false
      }
      return !isOverTab(window.convertPoint(toScreen: point))
    }

    private static func menu() -> NSMenu {
      let menu = NSMenu()
      let item = NSMenuItem(
        title: TitleBarTabsToggle.title, action: #selector(MenuTarget.toggle), keyEquivalent: "")
      item.target = MenuTarget.shared
      item.state = Defaults[.showTitleBarTabs] ? .on : .off
      menu.addItem(item)
      return menu
    }
  }

  /// The menu item's target: an `NSMenuItem` holds its target weakly, so it needs one that lives.
  @MainActor private final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    @objc func toggle() { Defaults[.showTitleBarTabs].toggle() }
  }
}

/// The right-click item that shows or hides the title bar's tabs, on a tab and on the bar.
enum TitleBarTabsToggle {
  static let title = "Show Tabs"
}
