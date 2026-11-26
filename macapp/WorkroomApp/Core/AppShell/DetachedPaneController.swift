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
/// whose `TerminalPanes` still owns the tab — so a detached window's lifetime is a subset of its
/// store's, and closing the origin window can never strand a window over a freed surface.
///
/// ```
///          detach ── drag the pane title bar (or a tab chip) past the window edge
///                 └─ or "Move to new window" (pane title-bar button / Window menu / ⌃⌘O)
///                        │
///   ┌──────────────────┐ ▼  ┌────────────────────────────┐
///   │      DOCKED      │───▶│         DETACHED           │
///   │ a leaf of the    │    │ its own DetachedPaneWindow; │
///   │ pane tree        │◀───│ the tab stays in the        │
///   └──────────────────┘    │ ORIGIN store's sessions     │
///        │           dock   └────────────────────────────┘
///        │        (Dock button / ⌃⌘O)        │
///        │                                   │
///        │      quit ─▶ session.json records `detachedFrame`
///        │              relaunch restores it DETACHED ──┘
///        │
///    pane ✕                        red button · ⌘W
///        │                                   │
///        └────────────▶ ┌──────────┐ ◀───────┘
///                       │  CLOSED  │
///                       └──────────┘
///      closeTab / reap → undetach → .paneDocked → close(tabID:), i.e. the window
///      goes as a CONSEQUENCE of the tab dying
///
///   DETACHED ── its workroom moves to another window (#444) ──▶ DETACHED, owned by THAT store:
///      close(tabID:) here, then the destination's `.paneRestoredDetached` reopens it at the same
///      frame. The tab never docks and never dies on the way.
/// ```
///
/// Three asymmetries, all deliberate, all easy to get backwards:
///
/// 1. The window's **red button and ⌘W close the pane**, not merely the window — Chrome / VS Code
///    tear-off semantics. They route through `requestCloseTerminalTab`, so a live process still gets
///    its confirmation (which is presented by `RootView`, i.e. on the ORIGIN window). The pane draws
///    no ✕ of its own in there: a detached pane renders `chromeless`, so the window's chrome is the
///    only chrome.
/// 2. The **Dock button closes the window and keeps the pane.** It is the only close-shaped action
///    that does, and it goes through `close(tabID:)`, which explicitly does not touch the tab.
/// 3. A tab dying closes its window as a *consequence*, never the cause: `closeTab`/`reap` call
///    `undetach`, which fires `.paneDocked`, which calls `close(tabID:)`. Nothing here may close a
///    window in order to close a tab.
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
  /// Matches `QuickTerminalController`'s 800x500, plus room for the pane's status bar — ONE chrome
  /// row, not two: a detached pane renders `chromeless`, so it draws no title bar of its own, and the
  /// window's own title bar sits outside `contentRect`.
  static let defaultSize = NSSize(
    width: 800, height: 500 + TerminalPanelMetrics.chromeRowHeight)

  private var windows: [TerminalTab.ID: DetachedPaneWindow] = [:]
  private var toolbarDelegates: [TerminalTab.ID: ToolbarDelegate] = [:]
  private var delegates: [TerminalTab.ID: Delegate] = [:]

  /// The pop out or pull back running for a pane, at most one each (`PaneWindowMotion`). Anything
  /// else that happens to the pane first settles it: a second pop out or pull back finishes it at
  /// its end, a close drops it.
  private var transitions: [TerminalTab.ID: PaneWindowTransition] = [:]
  /// Whether pop out and pull back animate; off in a hosted unit run.
  var animates = PaneWindowMotion.isEnabledByDefault
  var animator: PaneWindowAnimating = LivePaneWindowAnimator()
  /// The system's Reduce Motion, read as each transition starts.
  var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  /// A detached window's corners, which its pop out lands with and its pull back leaves with. A
  /// window with a toolbar on macOS 26; the slot's are `TerminalPanelMetrics.cornerRadius`.
  static let windowCornerRadius: CGFloat = 16

  /// Where a popped-out pane came from, for its window to grow out of (issue #172): its slot,
  /// pictured before the pane moved, and whether it was dragged out.
  struct PopOutSource {
    var slot: PaneSlot?
    /// Dragged out of its window, and let go at `pointer`.
    var byDrag: Bool
    var pointer: CGPoint?
    /// Tells the slot the pane is in flight over it (true), so it shows no placeholder, or has
    /// lifted clear of it (false) (`TerminalPanes.setInFlight`).
    var setInFlight: @MainActor (Bool) -> Void = { _ in }

    /// The slot of `tabID` as it is now, with `surface` in it; none when it isn't on screen.
    /// `onScreen`: whether its holder shows the pane's workroom at all, which a slot's view alone
    /// cannot tell.
    @MainActor
    static func slot(
      of tabID: TerminalTab.ID, surface: NSView?, onScreen: Bool = true, byDrag: Bool,
      pointer: CGPoint?, setInFlight: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> PopOutSource {
      PopOutSource(
        slot: onScreen ? PaneSlot.current(of: tabID, surface: surface) : nil, byDrag: byDrag,
        pointer: pointer, setInFlight: setInFlight)
    }
  }

  /// A window's background at full opacity: under Glass it is translucent, and the card that flies
  /// has no blur behind it.
  private static func opaque(_ color: NSColor?) -> NSColor {
    (color ?? .windowBackgroundColor).withAlphaComponent(1)
  }

  /// The window hosting `tabID`, for the raise paths (`AppStore.window(forTab:)`).
  func window(for tabID: TerminalTab.ID) -> NSWindow? { windows[tabID] }

  /// The live frame of a detached pane's window, for session capture. Read from the window itself
  /// rather than a cached copy, so a user-moved window is persisted where it actually is.
  func frame(for tabID: TerminalTab.ID) -> NSRect? { windows[tabID]?.frame }

  /// Rename a detached pane's window, so a terminal that retitles itself retitles its window.
  /// `title` also stays on the window for the Window menu and Mission Control, which read it even
  /// though the title bar itself draws the toolbar's label.
  func setTitle(
    _ title: String, project: String, workroom: String?, glyph: String = "cube",
    for tabID: TerminalTab.ID
  ) {
    windows[tabID]?.title = title
    toolbarDelegates[tabID]?.update(
      title: title, project: project, workroom: workroom, glyph: glyph)
  }

  /// Open a window for a freshly-detached pane. `origin` is a SCREEN point (the cursor at drop time);
  /// the window is placed so its top-left lands there, then nudged onto a visible screen.
  ///
  /// `popOut`, given for a pop out and never for a restore or a hand-off (#444), grows the window
  /// out of the pane's slot (`PaneWindowMotion.popOut`).
  func open<Content: View>(
    tabID: TerminalTab.ID, title: String, project: String, workroom: String?,
    glyph: String = "cube", origin: CGPoint?,
    frame: NSRect? = nil, popOut: PopOutSource? = nil, onCloseTab: @escaping () -> Void,
    onDock: @escaping () -> Void,
    content: () -> Content
  ) {
    guard windows[tabID] == nil else {
      settle(tabID)
      windows[tabID]?.makeKeyAndOrderFront(nil)
      return
    }
    settle(tabID)
    // A restored window keeps the frame the user left it at; a fresh tear-off always opens at the
    // standard size.
    // `AppStore.frameOnAVisibleScreen`, not a local copy: it already encodes what "reachable" means
    // (a real 60pt overlap in BOTH axes, not a shared edge), it is pure and screen-injectable, and it
    // is unit-tested. A restored frame it rejects is unusable, so fall back to the standard size.
    let restored = frame.flatMap { AppStore.frameOnAVisibleScreen($0) }
    let size = restored?.size ?? Self.defaultSize
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
      title: title, project: project, workroom: workroom, glyph: glyph, onDock: onDock)
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
    if let restored {
      window.setFrame(restored, display: false)
    } else if let origin {
      window.setFrameTopLeftPoint(origin)
      if let safe = AppStore.frameOnAVisibleScreen(window.frame) {
        window.setFrame(safe, display: false)
      }
    } else {
      window.center()
    }
    let delegate = Delegate(onCloseTab: onCloseTab)
    // Moving or resizing the window as it grows in ends the growing, at the window.
    delegate.onMove = { [weak self] in self?.settle(tabID) }
    window.delegate = delegate
    delegates[tabID] = delegate
    windows[tabID] = window
    let popOut = animates ? popOut : nil
    if popOut != nil {
      // Hidden until its pop out lands, but still the window that takes the keyboard and the
      // mouse: a window at alpha 0 otherwise lets clicks through to the window under it.
      window.alphaValue = 0
      window.ignoresMouseEvents = false
    }

    // ORDER FRONT BEFORE MOUNTING THE CONTENT. `GhosttySurfaceView.viewDidMoveToWindow` decides
    // whether to render from `window.occlusionState.contains(.visible)`, and a window that has not
    // been ordered in yet is not visible — so mounting first paused the renderer the instant the
    // surface arrived, and the pane came up blank while its title bar (plain SwiftUI) drew fine.
    // Nothing recovered it either: the occlusion observer only fires on a CHANGE, and the surface
    // had already recorded "not visible" before the window ever appeared.
    window.makeKeyAndOrderFront(nil)
    // Glass like the main window (#731), resolving this window's own full screen. A normal title bar
    // (`.standard`): the pane has a name and a place to drag from.
    window.contentView = NSHostingView(
      rootView: content().modifier(GlassWindowRoot(titlebar: .standard)).themeTokensRoot())
    // Glass now, as that root will resolve it, not when it first mounts on a display cycle.
    WindowBackgroundThemer.applyResolved(to: window, titlebar: .standard)
    if let popOut {
      let transition = popOutTransition(for: window, tabID: tabID, from: popOut)
      transition.start()
      transitions[tabID] = transition
    }
  }

  /// The pop out of `window`, which opens at its final frame, hidden, and shows when the snapshot
  /// growing out of the slot reaches it; with Reduce Motion, or no slot on screen, it fades in
  /// where it opens.
  ///
  /// The snapshot starts as the slot and lands as the window: its own title bar, pictured now its
  /// content is mounted, over the slot's body, so the swap to the real window changes nothing but
  /// the terminal's reflow.
  private func popOutTransition(
    for window: NSWindow, tabID: TerminalTab.ID, from source: PopOutSource
  ) -> PaneWindowTransition {
    let plan = PaneWindowMotion.popOut(
      slot: source.slot?.rect, final: window.frame, pointer: source.pointer,
      byDrag: source.byDrag, reduceMotion: reduceMotion(), screens: NSScreen.screens.map(\.frame))
    let surface: PaneWindowTransitionSurface
    if plan.moves {
      window.contentView?.superview?.layoutSubtreeIfNeeded()
      let background = Self.opaque(window.backgroundColor)
      let titlebar = PaneSnapshot.titlebarHeight(of: window)
      let slotBody = source.slot?.snapshot.flatMap {
        PaneSnapshot.split(
          $0, height: source.slot?.rect.height ?? 0, top: PaneTitleBarMetrics.height
        ).body
      }
      let windowTop = PaneSnapshot.window(window).flatMap {
        PaneSnapshot.split($0, height: window.frame.height, top: titlebar).top
      }
      let landed = PaneSnapshot.compose(
        size: window.frame.size, scale: window.backingScaleFactor, background: background,
        top: windowTop, topHeight: titlebar, body: slotBody)
      surface = PaneTransitionPanel(
        from: .init(
          image: source.slot?.snapshot, cornerRadius: TerminalPanelMetrics.cornerRadius,
          shadow: false),
        to: .init(image: landed, cornerRadius: Self.windowCornerRadius, shadow: true),
        background: source.slot?.background ?? background,
        above: NSWindow.Level(
          rawValue: max(source.slot?.level.rawValue ?? 0, window.level.rawValue)))
    } else {
      surface = PaneWindowFadeIn(window)
    }
    // The slot shows no placeholder until the pane has lifted out of it: in this same turn as the
    // detach, so it never shows for a frame first.
    var milestones: [(fraction: Double, action: () -> Void)] = []
    if plan.moves {
      source.setInFlight(true)
      milestones.append(
        (PaneWindowMotion.Tuning.placeholderRevealFraction, { source.setInFlight(false) }))
    }
    return PaneWindowTransition(
      kind: .popOut, plan: plan, surface: surface, animator: animator, milestones: milestones
    ) { [weak self, weak window] _ in
      window?.alphaValue = 1
      self?.forgetEnded(tabID)
    }
  }

  /// Dock `tabID` with its pull back (issue #172): its window shrinks into `slot` (none when it
  /// isn't on screen), fully opaque, and `dock` runs when it lands, so the pane is never in its
  /// window and its slot at once; the card then fades off the docked pane. The slot's placeholder
  /// goes as it starts (`setInFlight(true)`; docking clears it), so it lands on a calm slot. With
  /// Reduce Motion, or no slot, the pane docks at once under a snapshot of its window that fades
  /// where it was. Nothing to animate (no window, or one that is minimised or full screen) docks
  /// at once.
  ///
  /// The snapshot starts as the window, title bar and all, and lands as the slot will draw the
  /// pane: the slot's own title bar over the window's body.
  func dock(
    _ tabID: TerminalTab.ID, into slot: PaneSlot?,
    setInFlight: @escaping @MainActor (Bool) -> Void = { _ in }, then dock: @escaping () -> Void
  ) {
    if let running = transitions.removeValue(forKey: tabID) {
      // A pull back already running docks as it finishes; a pop out finishes into its window,
      // which then pulls back.
      running.finish()
      if running.kind == .pullBack { return }
    }
    guard animates, let window = windows[tabID], window.isVisible, !window.isMiniaturized,
      !window.styleMask.contains(.fullScreen)
    else {
      dock()
      return
    }
    let plan = PaneWindowMotion.pullBack(
      window: window.frame, slot: slot?.rect, reduceMotion: reduceMotion(),
      screens: NSScreen.screens.map(\.frame))
    let background = Self.opaque(window.backgroundColor)
    let picture = PaneSnapshot.window(window)
    var landed: CGImage?
    if plan.moves, let slot {
      let windowBody = picture.flatMap {
        PaneSnapshot.split(
          $0, height: window.frame.height, top: PaneSnapshot.titlebarHeight(of: window)
        ).body
      }
      let slotTop = slot.snapshot.flatMap {
        PaneSnapshot.split($0, height: slot.rect.height, top: PaneTitleBarMetrics.height).top
      }
      landed = PaneSnapshot.compose(
        size: slot.rect.size, scale: slot.scale, background: slot.background, top: slotTop,
        topHeight: PaneTitleBarMetrics.height, body: windowBody)
    }
    let panel = PaneTransitionPanel(
      from: .init(image: picture, cornerRadius: Self.windowCornerRadius, shadow: true),
      to: .init(image: landed, cornerRadius: TerminalPanelMetrics.cornerRadius, shadow: false),
      background: background,
      above: NSWindow.Level(
        rawValue: max(slot?.level.rawValue ?? 0, window.level.rawValue)))
    let docksFirst = !plan.moves
    let transition = PaneWindowTransition(
      kind: .pullBack, plan: plan, surface: panel, animator: animator
    ) { [weak self] _ in
      self?.forgetEnded(tabID)
      if !docksFirst { dock() }
    }
    // The slot's placeholder starts its fast fade now, while the card is still far off.
    if !docksFirst { setInFlight(true) }
    // The snapshot covers the window before the window goes, so the pane never blinks out.
    transition.start()
    window.animationBehavior = .none
    window.orderOut(nil)
    // Docking closes the window, which drops a transition registered for it: register after.
    if docksFirst { dock() }
    if !transition.isDone { transitions[tabID] = transition }
  }

  /// End `tabID`'s transition at its end now, if one is running.
  func settle(_ tabID: TerminalTab.ID) {
    transitions.removeValue(forKey: tabID)?.finish()
  }

  private func forgetEnded(_ tabID: TerminalTab.ID) {
    if transitions[tabID]?.isDone == true { transitions[tabID] = nil }
  }

  /// Close a detached pane's window WITHOUT closing its tab — a dock, or a teardown where the tab is
  /// already being removed by someone else. Idempotent.
  func close(tabID: TerminalTab.ID) {
    // A transition for a pane that is going away has nothing left to end at.
    transitions.removeValue(forKey: tabID)?.cancel()
    guard let window = windows[tabID] else { return }
    toolbarDelegates[tabID] = nil
    // Nilling the delegate is the whole guard: `NSWindow.close()` does not consult
    // `windowShouldClose(_:)` (only `performClose(_:)` does), and with no delegate there is nothing
    // to consult anyway — so this can never re-enter and try to close the tab we are un-hosting.
    window.delegate = nil
    window.close()
    windows[tabID] = nil
    delegates[tabID] = nil
    DetachedPaneFocus.shared.refresh()
  }

  /// Close every detached window this store owns — the origin window is going away, and its surfaces
  /// are about to be released.
  func closeAll() {
    for tabID in windows.keys { close(tabID: tabID) }
  }

  /// The detached window's toolbar: the pane's name with its project and workroom alongside it in
  /// smaller type, and a button to send the pane back to the main window.
  ///
  /// The label is one `NSTextField` carrying an attributed string rather than two views, so the two
  /// sizes share a baseline and the whole thing is one item the toolbar can centre.
  @MainActor
  final class ToolbarDelegate: NSObject, NSToolbarDelegate {
    nonisolated private static let labelItem = NSToolbarItem.Identifier("detachedPane.label")
    nonisolated private static let dockItem = NSToolbarItem.Identifier("detachedPane.dock")

    private let label = NSTextField(labelWithString: "")
    private let onDock: () -> Void

    init(
      title: String, project: String, workroom: String?, glyph: String,
      onDock: @escaping () -> Void
    ) {
      self.onDock = onDock
      super.init()
      label.attributedStringValue = Self.attributed(
        title: title, project: project, workroom: workroom, glyph: glyph)
      label.lineBreakMode = .byTruncatingTail
      label.setAccessibilityIdentifier("detachedPane.title")
    }

    func update(title: String, project: String, workroom: String?, glyph: String) {
      label.attributedStringValue = Self.attributed(
        title: title, project: project, workroom: workroom, glyph: glyph)
    }

    /// `Terminal 2      ⌂ my-project · ▣ my-workroom` — the pane's name, then where it lives, in
    /// smaller secondary type. The glyphs are the sidebar's own vocabulary (`ProjectSidebar`: `house`
    /// for a project root, `cube` for a workroom), so the window names the pane the same way the
    /// sidebar does, and a workroom on a host takes the network (`TerminalTarget.workroomGlyph`).
    private static func attributed(
      title: String, project: String, workroom: String?, glyph: String
    ) -> NSAttributedString {
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
        result.append(symbol(glyph, font: small))
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
  /// then closes as a consequence, via `closeTab` → `undetach` → `.paneDocked` → `close(tabID:)`.
  private final class Delegate: NSObject, NSWindowDelegate {
    private let onCloseTab: () -> Void
    /// The window moved or resized: a pop out still growing into it settles.
    var onMove: (() -> Void)?
    init(onCloseTab: @escaping () -> Void) { self.onCloseTab = onCloseTab }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
      onCloseTab()
      return false
    }
    func windowDidMove(_ notification: Notification) { onMove?() }
    func windowDidResize(_ notification: Notification) { onMove?() }
  }
}
