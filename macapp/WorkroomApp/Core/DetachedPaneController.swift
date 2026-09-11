import AppKit
import SwiftUI

/// Marker type for a popped-out pane's window (issue #172), so the `AppDelegate` key monitor and
/// `WindowRegistry` can recognise it the way they already recognise `QuickTerminalWindow`.
final class DetachedPaneWindow: NSWindow {
  /// The pane this window hosts. Carried on the window so "is a detached pane key, and which one?"
  /// can be answered from the key window alone — `DetachedPaneWindows` is per-store, and the menu
  /// asking the question has no store in hand.
  var tabID: TerminalTab.ID?
}

/// Which detached pane, if any, currently has key focus (issue #172).
///
/// A detached window is not a SwiftUI scene, so nothing about it reaches `@FocusedValue`, and a
/// `Commands` body would never re-evaluate when one becomes key. This is an `ObservableObject` the
/// menu observes directly, which is the one mechanism that does re-render it.
@MainActor
final class DetachedPaneFocus: ObservableObject {
  static let shared = DetachedPaneFocus()

  /// The detached pane that is key, or nil when the key window is anything else.
  @Published private(set) var keyTabID: TerminalTab.ID?

  private var observers: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.refresh() }
        })
    }
  }

  /// Re-read the key window. Driven by notifications rather than stored per-window, so a window
  /// closing (which resigns key without a matching become) cannot strand a stale id.
  func refresh() {
    let tabID = (NSApp.keyWindow as? DetachedPaneWindow)?.tabID
    if keyTabID != tabID { keyTabID = tabID }
  }
}

/// The windows holding popped-out panes (issue #172). One per detached tab, owned by the `AppStore`
/// whose `TerminalSessions` still owns the tab — so a detached window's lifetime is a subset of its
/// store's, and closing the origin window can never strand a window over a freed surface.
///
/// ```
///                 detach ── drag the pane title bar past the window edge
///                        └─ or "Move to new window" (title-bar button / Window menu)
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
  /// The size a freshly torn-off pane's window opens at.
  ///
  /// Deliberately a CONSTANT rather than the pane's measured rect: on screen a pane is whatever size
  /// the split happened to leave it, and inheriting that means tearing off a narrow column hands you
  /// a narrow, unusable window. Detaching is a request for a window, not for those dimensions.
  /// Matches `QuickTerminalController`'s 800x500, plus room for the pane's own title and status bars.
  static let defaultSize = NSSize(
    width: 800, height: 500 + 2 * TerminalPanelMetrics.chromeRowHeight)

  private var windows: [TerminalTab.ID: DetachedPaneWindow] = [:]
  private var toolbarDelegates: [TerminalTab.ID: ToolbarDelegate] = [:]
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

  /// Rename a detached pane's window, so a terminal that retitles itself retitles its window.
  /// `title` also stays on the window for the Window menu and Mission Control, which read it even
  /// though the title bar itself draws the toolbar's label.
  func setTitle(
    _ title: String, project: String, workroom: String?, for tabID: TerminalTab.ID
  ) {
    windows[tabID]?.title = title
    toolbarDelegates[tabID]?.update(title: title, project: project, workroom: workroom)
  }

  /// Open a window for a freshly-detached pane. `origin` is a SCREEN point (the cursor at drop time);
  /// the window is placed so its top-left lands there, then nudged onto a visible screen.
  func open<Content: View>(
    tabID: TerminalTab.ID, title: String, project: String, workroom: String?, origin: CGPoint?,
    frame: NSRect? = nil, onCloseTab: @escaping () -> Void, onDock: @escaping () -> Void,
    content: () -> Content
  ) {
    guard windows[tabID] == nil else {
      windows[tabID]?.makeKeyAndOrderFront(nil)
      return
    }
    // A restored window keeps the frame the user left it at; a fresh tear-off always opens at the
    // standard size.
    let size = frame?.size ?? Self.defaultSize
    let window = DetachedPaneWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.tabID = tabID
    window.title = title
    // A NORMAL title bar, unlike the main window's (issue #172): traffic lights, then the pane's name
    // beside them, and a button to send it back. That is a toolbar, and AppKit's own title is hidden
    // so the toolbar can draw the name itself — `NSWindow.subtitle` stacks the secondary text UNDER
    // the title and grows the bar, and the ask was for it alongside.
    //
    // Plain AppKit views, not `NSHostingView`: SwiftUI-managed toolbar items are what dragged in the
    // `menuFormRepresentation` recompute behind the macOS-26 app hangs (see `WindowBackgroundThemer`),
    // and a label plus a button is not worth reopening that.
    //
    // `.unifiedCompact` rather than `.unified`: the tall variant leaves a band of empty space under
    // the title, which on a window whose whole job is to show one pane is just less pane.
    let toolbarDelegate = ToolbarDelegate(
      title: title, project: project, workroom: workroom, onDock: onDock)
    let toolbar = NSToolbar(identifier: "detachedPane")
    toolbar.delegate = toolbarDelegate
    toolbar.showsBaselineSeparator = false
    toolbar.displayMode = .iconOnly
    toolbarDelegates[tabID] = toolbarDelegate
    window.toolbar = toolbar
    window.toolbarStyle = .unifiedCompact
    window.titleVisibility = .hidden
    // We own the lifetime (see `close`); don't let AppKit free the window out from under us.
    window.isReleasedWhenClosed = false
    // Only the window-level a11y id in this app besides the onboarding window's — XCUITest has no
    // other way to scope a query to this window (see `DetachedPaneUITests`).
    window.setAccessibilityIdentifier("detachedPane.window")
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

    // ORDER FRONT BEFORE MOUNTING THE CONTENT. `GhosttySurfaceView.viewDidMoveToWindow` decides
    // whether to render from `window.occlusionState.contains(.visible)`, and a window that has not
    // been ordered in yet is not visible — so mounting first paused the renderer the instant the
    // surface arrived, and the pane came up blank while its title bar (plain SwiftUI) drew fine.
    // Nothing recovered it either: the occlusion observer only fires on a CHANGE, and the surface
    // had already recorded "not visible" before the window ever appeared.
    window.makeKeyAndOrderFront(nil)
    window.contentView = NSHostingView(rootView: content())
  }

  /// Close a detached pane's window WITHOUT closing its tab — a dock, or a teardown where the tab is
  /// already being removed by someone else. Idempotent.
  func close(tabID: TerminalTab.ID) {
    guard let window = windows[tabID] else { return }
    toolbarDelegates[tabID] = nil
    closingWithoutTab.insert(tabID)
    window.delegate = nil
    window.close()
    closingWithoutTab.remove(tabID)
    windows[tabID] = nil
    delegates[tabID] = nil
    DetachedPaneFocus.shared.refresh()
  }

  /// Close every detached window this store owns — the origin window is going away, and its surfaces
  /// are about to be released.
  func closeAll() {
    for tabID in windows.keys { close(tabID: tabID) }
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

  /// The detached window's toolbar: the pane's name with its project and workroom alongside it in
  /// smaller type, and a button to send the pane back to the main window.
  ///
  /// The label is one `NSTextField` carrying an attributed string rather than two views, so the two
  /// sizes share a baseline and the whole thing is one item the toolbar can centre.
  @MainActor
  final class ToolbarDelegate: NSObject, NSToolbarDelegate {
    private static let labelItem = NSToolbarItem.Identifier("detachedPane.label")
    private static let dockItem = NSToolbarItem.Identifier("detachedPane.dock")

    private let label = NSTextField(labelWithString: "")
    private let onDock: () -> Void

    init(title: String, project: String, workroom: String?, onDock: @escaping () -> Void) {
      self.onDock = onDock
      super.init()
      label.attributedStringValue = Self.attributed(
        title: title, project: project, workroom: workroom)
      label.lineBreakMode = .byTruncatingTail
      label.setAccessibilityIdentifier("detachedPane.title")
    }

    func update(title: String, project: String, workroom: String?) {
      label.attributedStringValue = Self.attributed(
        title: title, project: project, workroom: workroom)
    }

    /// `Terminal 2      ⌂ my-project · ▣ my-workroom` — the pane's name, then where it lives, in
    /// smaller secondary type. The glyphs are the sidebar's own vocabulary (`ProjectSidebar`: `house`
    /// for a project root, `cube` for a workroom), so the window names the pane the same way the
    /// sidebar does.
    private static func attributed(title: String, project: String, workroom: String?)
      -> NSAttributedString
    {
      let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
      let secondary: [NSAttributedString.Key: Any] = [
        .font: small, .foregroundColor: NSColor.secondaryLabelColor,
      ]
      let result = NSMutableAttributedString(
        string: title,
        attributes: [
          .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
          .foregroundColor: NSColor.labelColor,
        ])
      guard !project.isEmpty else { return result }
      // One kerned space rather than a run of them: the gap is then a measured 14pt, not however wide
      // the font happens to render three spaces.
      result.append(NSAttributedString(string: " ", attributes: [.kern: 14, .font: small]))
      // A root has no workroom, so it takes the house; otherwise the project is plain text and the
      // cube sits against the workroom name, which is what it labels.
      if workroom == nil { result.append(symbol("house", font: small)) }
      result.append(NSAttributedString(string: project, attributes: secondary))
      if let workroom {
        result.append(NSAttributedString(string: " · ", attributes: secondary))
        result.append(symbol("cube", font: small))
        result.append(NSAttributedString(string: workroom, attributes: secondary))
      }
      return result
    }

    /// An SF Symbol inline in the label, tinted secondary and nudged onto the text baseline. Returns
    /// an empty string if the symbol is missing, so a bad name can never render as a blank box.
    private static func symbol(_ name: String, font: NSFont) -> NSAttributedString {
      let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
      guard
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
          .withSymbolConfiguration(config)
      else { return NSAttributedString(string: "") }
      let attachment = NSTextAttachment()
      attachment.image = image
      // Centre the glyph on the text's optical centre, not its baseline. `bounds.y` is the image's
      // BOTTOM measured from the baseline, and the text reads as centred on roughly half its cap
      // height — so sitting the image on the baseline (y ≈ 0) hangs it high by half the glyph.
      // Solving `y + height/2 == capHeight/2` gives the offset below.
      attachment.bounds = CGRect(
        x: 0, y: (font.capHeight - image.size.height) / 2,
        width: image.size.width, height: image.size.height)
      let result = NSMutableAttributedString(attachment: attachment)
      result.append(NSAttributedString(string: " ", attributes: [.font: font]))
      return result
    }

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar)
      -> [NSToolbarItem.Identifier]
    {
      [Self.labelItem, .flexibleSpace, Self.dockItem]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar)
      -> [NSToolbarItem.Identifier]
    {
      toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
      _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
      willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
      switch identifier {
      case Self.labelItem:
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = label
        item.visibilityPriority = .high
        return item
      case Self.dockItem:
        let item = NSToolbarItem(itemIdentifier: identifier)
        // `arrow.down.right.and.arrow.up.left` — the conventional "collapse this back in" glyph.
        // NOT `macwindow.badge.minus`, which reads as the obvious counterpart to the pop-out button's
        // `macwindow.badge.plus` but does not exist: `NSImage(systemSymbolName:)` returned nil and the
        // button rendered as an empty bezel. Falling back to a TITLE rather than an empty image, so a
        // symbol that ever goes missing degrades to a readable button instead of an invisible one.
        let symbol = NSImage(
          systemSymbolName: "arrow.down.right.and.arrow.up.left",
          accessibilityDescription: "Move pane back to the main window")
        let button: NSButton =
          symbol.map { NSButton(image: $0, target: self, action: #selector(dockTapped)) }
          ?? NSButton(title: "Move Back", target: self, action: #selector(dockTapped))
        button.bezelStyle = .texturedRounded
        button.setAccessibilityIdentifier("detachedPane.dockButton")
        item.view = button
        item.label = "Move Back"
        item.toolTip = "Move this pane back to the main window"
        return item
      default:
        return nil
      }
    }

    @objc private func dockTapped() { onDock() }
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
