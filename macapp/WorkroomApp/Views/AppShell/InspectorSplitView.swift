import AppKit
import SwiftUI

/// The right inspector composed as a raw `NSSplitView` (horizontal dividers, panes stacked top to
/// bottom) instead of a SwiftUI `VStack`. Each section is one arranged subview: a **sticky header +
/// scrollable body** — the section header is a fixed `NSHostingController` at the top, the body
/// lives in a native `NSScrollView` below it, so a section scrolls its content when cramped (or
/// dragged small) without ever scrolling its own disclosure header out of view.
///
/// Sizing: the default distribution is **equal** among expanded panes (collapsed panes pinned to
/// the header), realised once via `setPosition(ofDividerAt:)`; thereafter the user drags dividers
/// freely (raw `NSSplitView` gives native drag + proportional window-resize) and a per-pane height
/// constraint enforces the floor / the collapsed pin.
///
/// Why a **raw** `NSSplitView` and not `NSSplitViewController`: the controller's `adjustSubviews`
/// hugs every pane to its content's fitting size and dumps the slack on the lowest-holding-priority
/// pane, overriding `setPosition` on every layout pass — so equal sizing is impossible there. A raw
/// split view only positions dividers and respects per-subview Auto Layout constraints; it never
/// hugs content. Why AppKit at all (vs the old SwiftUI `VStack`): it kills the header-title "swim"
/// (each header is its own stable hosting view; collapse moves *sibling* panes, not a per-frame
/// SwiftUI re-layout of a translating `Text`) and gives free system-preference auto-hiding scrollers
/// (a raw `NSScrollView` tracks "Show scroll bars").

// MARK: - Pane: sticky header + scrollable body

/// One split pane. The section header is a fixed-height `NSHostingController` pinned to the top; the
/// body sits below it in one of two hosting modes:
///
/// - **scroll** (default): the body is an `NSHostingController` (`.intrinsicContentSize`) inside a
///   vertically-scrolling `NSScrollView` — it reports its natural height and the AppKit scroll view
///   scrolls when the pane is shorter than the content (auto-hiding scrollers, tracks the system
///   "Show scroll bars" preference).
/// - **fill** (`fillsBody`): the body hosting view instead FILLS the pane below the header and is
///   expected to scroll ITSELF (a SwiftUI `ScrollView`). This bypasses the `.intrinsicContentSize` →
///   `NSScrollView` bridge, so an inline height animation inside the body is driven entirely by
///   SwiftUI and can't fight AppKit's scroll-container resize-anchoring — the source of the visible
///   content shift the bridge produced.
///
/// When collapsed, the body is hidden and the enclosing split pins the pane to the header height.
final class InspectorPaneViewController: NSViewController {
  private let headerHost = NSHostingController(rootView: AnyView(EmptyView()))
  private let bodyScroll = NSScrollView()
  private let bodyHost = NSHostingController(rootView: AnyView(EmptyView()))
  /// Whether the body fills the pane and scrolls itself (vs. the default `NSScrollView` hosting).
  /// Must be set before the view first loads.
  var fillsBody = false
  /// Whether a fill-mode body's own scroll views draw overlay scrollers whatever the system's "Show
  /// scroll bars" setting. The sidebar's: a legacy scroller narrows its List's rows but not the
  /// sticky header above them, which would push the rows' "+" column out of line with the
  /// heading's. Must be set before the view first loads.
  var forcesOverlayScrollers = false
  private var observesScrollerStyle = false

  override func viewDidLayout() {
    super.viewDidLayout()
    if forcesOverlayScrollers { applyOverlayScrollers() }
  }

  /// A scroll view resets its style when the system preference changes, so that change re-applies
  /// it on the next layout.
  @objc private func preferredScrollerStyleDidChange(_ notification: Notification) {
    view.needsLayout = true
  }

  /// Sets every scroll view in the body to overlay scrollers.
  private func applyOverlayScrollers() {
    if !observesScrollerStyle {
      observesScrollerStyle = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(preferredScrollerStyleDidChange(_:)),
        name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }
    func visit(_ view: NSView) {
      if let scroll = view as? NSScrollView, scroll.scrollerStyle != .overlay {
        scroll.scrollerStyle = .overlay
      }
      view.subviews.forEach(visit)
    }
    visit(bodyHost.view)
  }

  override func loadView() {
    let container = NSView()

    headerHost.view.translatesAutoresizingMaskIntoConstraints = false
    let bodyView: NSView

    if fillsBody {
      // Fill mode: the body hosting view fills below the header and owns its own scrolling.
      bodyHost.sizingOptions = []
      addChild(bodyHost)
      bodyView = bodyHost.view
      bodyView.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(bodyView)
    } else {
      // Scroll mode: the body scroll view is added FIRST, then the header, so the header is topmost
      // in z-order — the opaque sticky header always sits above the scrolling body so content can
      // never bleed over the title during a resize.
      bodyHost.sizingOptions = [.intrinsicContentSize]
      addChild(bodyHost)
      let document = bodyHost.view
      document.translatesAutoresizingMaskIntoConstraints = false
      bodyScroll.translatesAutoresizingMaskIntoConstraints = false
      bodyScroll.hasVerticalScroller = true
      bodyScroll.hasHorizontalScroller = false
      bodyScroll.autohidesScrollers = true
      bodyScroll.drawsBackground = false
      bodyScroll.documentView = document
      container.addSubview(bodyScroll)
      bodyView = bodyScroll
      NSLayoutConstraint.activate([
        // Document pinned to the clip view's top/width (free height → it grows to content and the
        // scroll view scrolls when the pane is shorter than the content).
        document.topAnchor.constraint(equalTo: bodyScroll.contentView.topAnchor),
        document.leadingAnchor.constraint(equalTo: bodyScroll.contentView.leadingAnchor),
        document.trailingAnchor.constraint(equalTo: bodyScroll.contentView.trailingAnchor),
        document.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),
      ])
    }

    addChild(headerHost)
    container.addSubview(headerHost.view)

    NSLayoutConstraint.activate([
      // Sticky header: fixed height at the top.
      headerHost.view.topAnchor.constraint(equalTo: container.topAnchor),
      headerHost.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      headerHost.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      headerHost.view.heightAnchor.constraint(equalToConstant: InspectorPanePolicy.headerHeight),

      // Body fills the rest of the pane below the header.
      bodyView.topAnchor.constraint(equalTo: headerHost.view.bottomAnchor),
      bodyView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      bodyView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bodyView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    view = container
  }

  /// Swap the hosted header + body. The body is hidden when collapsed so only the header shows (the
  /// enclosing split also pins a collapsed pane to the header height). Each is a hosting root, so
  /// each gets the theme here rather than from every caller, and the window's Glass appearance.
  func setContent(
    header: AnyView, body: AnyView, collapsed: Bool, glass: GlassAppearance = .opaque
  ) {
    _ = view  // ensure loaded
    headerHost.rootView = header.hostedRoot(glass: glass)
    bodyHost.rootView = body.hostedRoot(glass: glass)
    (fillsBody ? bodyHost.view : bodyScroll).isHidden = collapsed
  }

  // MARK: Scroll memory (#810)

  private var scrollKey: String?
  private var scrollMemory: InspectorScrollMemory?
  /// The offset a return to `scrollKey` restores. Its content may arrive after the switch (a
  /// status read), and is clamped meanwhile, so every document resize re-applies it until the user
  /// scrolls.
  private var pendingOffset: CGFloat?
  private var observesScroll = false

  /// Remember a scroll-mode body's offset under `key` as the user scrolls, and restore the one
  /// remembered for it when `key` changes. A nil key (a workroom's inspector) leaves the scroll view
  /// alone. A fill-mode body scrolls itself (`inspectorScrollMemory(key:in:)`).
  func remembersScroll(under key: String?, in memory: InspectorScrollMemory?) {
    guard !fillsBody, key != scrollKey else { return }
    _ = view
    scrollKey = key
    scrollMemory = memory
    observeScrollIfNeeded()
    guard let key, let memory else {
      pendingOffset = nil
      return
    }
    pendingOffset = memory.offset(under: key) ?? 0
    applyPendingOffset()
  }

  /// Only the user's own scrolls (live scrolls) are remembered: a clip view clamped by a body
  /// that is briefly short must not overwrite where they left it.
  private func observeScrollIfNeeded() {
    guard !observesScroll else { return }
    observesScroll = true
    bodyHost.view.postsFrameChangedNotifications = true
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(userWillScroll(_:)),
      name: NSScrollView.willStartLiveScrollNotification, object: bodyScroll)
    for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification]
    {
      center.addObserver(
        self, selector: #selector(userDidScroll(_:)), name: name, object: bodyScroll)
    }
    center.addObserver(
      self, selector: #selector(documentFrameDidChange(_:)),
      name: NSView.frameDidChangeNotification, object: bodyHost.view)
  }

  @objc private func userWillScroll(_ notification: Notification) { pendingOffset = nil }

  @objc private func userDidScroll(_ notification: Notification) {
    pendingOffset = nil
    guard let scrollKey else { return }
    scrollMemory?.remember(bodyScroll.contentView.bounds.origin.y, under: scrollKey)
  }

  @objc private func documentFrameDidChange(_ notification: Notification) {
    applyPendingOffset()
  }

  /// Scroll as near `pendingOffset` as the content allows, without animating.
  private func applyPendingOffset() {
    guard let target = pendingOffset else { return }
    let clip = bodyScroll.contentView
    let limit = max(0, bodyHost.view.frame.height - clip.bounds.height)
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(target, limit)))
    bodyScroll.reflectScrolledClipView(clip)
  }
}

// MARK: - Split container

/// Owns the raw `NSSplitView` and the three pane child controllers. Sizing rules:
///
/// - A per-pane height constraint (swapped on collapse change) pins a collapsed pane to the header
///   and floors an expanded pane at `expandedMinHeight` — this is what a drag and a window resize
///   respect.
/// - The **default** distribution (equal among expanded panes, or the saved weights) is applied via
///   `setPosition` after the first real layout and on a workroom switch. Plain window resizes keep
///   the user's proportions (native `NSSplitView` behaviour).
/// - **Collapsing** a single section keeps the other panes' heights and flexes only a neighbour
///   (`reallocateOnToggle`), so a divider the user dragged between two unrelated sections survives a
///   collapse elsewhere. **Expanding** a section re-splits the expanded panes **equally**
///   (`allocate`) — re-opening a collapsed section returns the stack to equal heights (a third each
///   for Changes + History + Pull Request) rather than the minimum floor.
/// `NSSplitView` whose dividers use a themed hairline. The system's thin divider can render a hard,
/// near-black line between the section panes — most visible while the inspector collapses/expands —
/// so we override `dividerColor` to force our subtle border colour on every draw, mid-animation
/// included.
final class ThemedSplitView: NSSplitView {
  override var dividerColor: NSColor {
    ThemeService.shared.tokens.nsFg.withAlphaComponent(0.12)
  }
}

final class InspectorSplitContainerController: NSViewController, NSSplitViewDelegate {
  /// How one use of the split sizes its panes. The inspector's is the default; the sidebar's
  /// Terminals + Projects split (`ProjectSidebar`) floors a pane lower, holds the Terminals pane
  /// through a window resize, and re-derives its saved layout when a pane re-opens.
  struct Sizing: Equatable {
    /// Each expanded pane's floor, in pane order; nil floors every one at `expandedMinHeight`.
    var minHeights: [CGFloat]? = nil
    /// Each pane's holding priority, in pane order: the lowest flexes first on a window resize.
    /// Nil holds every pane equally (proportional resize).
    var holdingPriorities: [NSLayoutConstraint.Priority]? = nil
    /// Expanding a pane restores the saved (or content-sized) layout rather than splitting
    /// equally, and a collapse records no weights, so a fold and unfold returns the panes to where
    /// they were.
    var restoresLayoutOnExpand = false
    /// The most of the expanded panes' space a preferred (content-sized) pane takes.
    var preferredCap: CGFloat = 0.5
  }
  /// Set before `install`.
  var sizing = Sizing()
  let splitView = ThemedSplitView()
  private(set) var panes: [InspectorPaneViewController] = []
  private var heightConstraints: [NSLayoutConstraint] = []
  // Sized to the installed pane count, which is dynamic: the active activity-bar section decides how
  // many sub-sections its pane stacks (3 for Changes + History + Pull Request, 1 for Files). Empty
  // until the first `install`.
  private var collapsedFlags: [Bool] = []
  private var weights: [CGFloat] = []
  private var workroomKey = ""
  /// Content-sized heights for the panes that have one, used in place of `weights` while no layout
  /// is saved. Nil when the weights decide.
  private(set) var preferredHeights: [CGFloat?]?

  /// What the next real layout should do. `.redistribute` re-derives the whole layout from the saved
  /// weights (initial layout + workroom switch); `.toggle` re-sizes for one collapse change while
  /// preserving the untouched panes' heights. Both need `bounds.height > 0`, so the work is deferred
  /// to `viewDidLayout`.
  private enum PendingLayout {
    case none
    case redistribute
    case toggle(index: Int, previous: [CGFloat])
  }
  private var pendingLayout: PendingLayout = .redistribute

  /// Called when the user drags a divider, with the new relative pane heights.
  var onWeightsChanged: (([Double]) -> Void)?
  /// Whether a resize is a genuine user divider drag: the left mouse button is down. Programmatic
  /// distribution and the inspector's open animation also post resize notifications (sometimes even
  /// carrying a divider index), but with no mouse button held — so this gates out everything but a
  /// real drag. Injectable for headless tests, which have no live mouse state.
  var isLikelyUserDrag: () -> Bool = { NSEvent.pressedMouseButtons & 0x1 != 0 }

  override func loadView() {
    splitView.isVertical = false  // horizontal dividers → panes stack vertically
    splitView.dividerStyle = .thin
    splitView.delegate = self
    view = splitView
  }

  /// Install one arranged subview per sub-section of the active pane, top to bottom. The collapse
  /// flags / weights are (re)sized to the pane count here so a caller can install any count (1..N).
  func install(panes: [InspectorPaneViewController]) {
    self.panes = panes
    if collapsedFlags.count != panes.count {
      collapsedFlags = [Bool](repeating: false, count: panes.count)
    }
    if weights.count != panes.count {
      weights = [CGFloat](repeating: 1, count: panes.count)
    }
    for (index, pane) in panes.enumerated() {
      addChild(pane)
      pane.view.translatesAutoresizingMaskIntoConstraints = false
      splitView.addArrangedSubview(pane.view)
      let holding = sizing.holdingPriorities.flatMap { index < $0.count ? $0[index] : nil }
      splitView.setHoldingPriority(holding ?? .defaultLow, forSubviewAt: index)
      let constraint = makeHeightConstraint(for: pane, collapsed: collapsedFlags[index])
      constraint.isActive = true
      heightConstraints.append(constraint)
    }
  }

  /// Tear down the current panes and install a fresh set — used when the active activity-bar section
  /// changes and the pane count/identity differs (e.g. the 2-pane Changes stack ↔ the 1-pane Files).
  /// Resets the layout state so the next `viewDidLayout` re-derives the distribution from scratch.
  func rebuild(panes newPanes: [InspectorPaneViewController]) {
    for pane in panes {
      pane.view.removeFromSuperview()
      pane.removeFromParent()
    }
    for constraint in heightConstraints { constraint.isActive = false }
    heightConstraints.removeAll()
    panes = []
    collapsedFlags = []
    weights = []
    install(panes: newPanes)
    pendingLayout = .redistribute
  }

  /// Reflect the selected workroom's layout: its key, collapse state, and persisted pane weights.
  /// A workroom switch re-derives the whole layout from the saved weights. A single section's
  /// collapse toggling re-sizes only a neighbour, preserving the other panes' heights (so a manual
  /// drag elsewhere survives). A mere weights update coming back from a drag / a toggle's own
  /// persistence does nothing (the dividers are already where they belong).
  ///
  /// `preferredHeights` (content-sized panes, while no layout is saved) re-lays out the panes when it
  /// changes to new heights, so the sidebar's Terminals pane follows its rows. Its going away (the
  /// user dragged, and the drag's weights now decide) does not: the panes are already there, and a
  /// re-layout mid-drag would fight the mouse.
  func update(
    workroomKey: String, collapsed: [Bool], weights: [Double],
    preferredHeights: [CGFloat?]? = nil
  ) {
    precondition(collapsed.count == panes.count, "need one collapse flag per section")
    let resolvedWeights =
      weights.count == panes.count ? weights.map { CGFloat($0) } : self.weights
    let workroomChanged = workroomKey != self.workroomKey
    let previousCollapsed = collapsedFlags
    let collapseChanged = collapsed != previousCollapsed
    let preferredChanged = preferredHeights != nil && preferredHeights != self.preferredHeights
    self.weights = resolvedWeights
    self.workroomKey = workroomKey
    self.preferredHeights = preferredHeights
    if preferredChanged, !workroomChanged, !collapseChanged {
      pendingLayout = .redistribute
      view.needsLayout = true
      return
    }
    guard workroomChanged || collapseChanged else { return }

    // A lone collapse toggle within the same workroom preserves the other panes; a workroom switch
    // or a multi-flag change re-derives the whole layout. Capture the pre-toggle heights *before*
    // swapping constraints — the frames still hold the current layout at this point.
    let toggled = workroomChanged ? nil : Self.singleDifference(previousCollapsed, collapsed)
    let previousHeights = panes.map { $0.view.frame.height }

    collapsedFlags = collapsed
    swapHeightConstraints()
    if let toggled, previousHeights.allSatisfy({ $0 > 0 }) {
      pendingLayout = .toggle(index: toggled, previous: previousHeights)
    } else {
      pendingLayout = .redistribute
    }
    view.needsLayout = true
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    guard splitView.bounds.height > 0 else { return }
    switch pendingLayout {
    case .none:
      return
    case .redistribute:
      pendingLayout = .none
      redistribute()
    case .toggle(let index, let previous):
      pendingLayout = .none
      applyToggle(index: index, previous: previous)
    }
  }

  /// The single index whose flag differs between two collapse states, or nil when zero or more than
  /// one differ — i.e. exactly the "one section toggled" case the neighbour-preserving resize wants.
  private static func singleDifference(_ a: [Bool], _ b: [Bool]) -> Int? {
    guard a.count == b.count else { return nil }
    var diff: Int?
    for i in a.indices where a[i] != b[i] {
      if diff != nil { return nil }
      diff = i
    }
    return diff
  }

  /// Swap each pane's height constraint to match the current collapse state (collapsed → pinned to
  /// the header, expanded → floored at `expandedMinHeight`).
  private func swapHeightConstraints() {
    for (index, pane) in panes.enumerated() {
      heightConstraints[index].isActive = false
      let constraint = makeHeightConstraint(for: pane, collapsed: collapsedFlags[index])
      constraint.isActive = true
      heightConstraints[index] = constraint
    }
  }

  /// Realise the pane heights from `InspectorPanePolicy` (collapsed panes pinned to the header, the
  /// rest split by the saved weights — equal by default) via divider positions. Used for the initial
  /// layout and on a workroom switch, when the saved/default proportions should reassert.
  private func redistribute() {
    setPositions(defaultHeights())
  }

  /// The layout the saved weights, or the content-sized preferred heights, give.
  private func defaultHeights() -> [CGFloat] {
    InspectorPanePolicy.allocate(
      collapsed: collapsedFlags, weights: weights, minHeights: sizing.minHeights,
      preferred: preferredHeights, preferredCap: sizing.preferredCap,
      capacity: splitView.bounds.height, dividerThickness: splitView.dividerThickness)
  }

  /// Resize for a single section's collapse toggle: a **collapse** preserves the untouched panes'
  /// heights (only a neighbour flexes — `reallocateOnToggle`); an **expand** re-splits the expanded
  /// panes equally (`allocate`), so a re-opened section returns to an equal share. Either way the
  /// resulting layout is persisted so a later window resize / workroom switch reflects it.
  private func applyToggle(index: Int, previous: [CGFloat]) {
    let heights: [CGFloat]
    if collapsedFlags[index] {
      // Collapse: keep the other panes put — a neighbour absorbs the freed space, so a divider the
      // user dragged elsewhere survives.
      heights = InspectorPanePolicy.reallocateOnToggle(
        previous: previous, collapsed: collapsedFlags, toggled: index,
        minHeights: sizing.minHeights, capacity: splitView.bounds.height,
        dividerThickness: splitView.dividerThickness)
    } else if sizing.restoresLayoutOnExpand {
      // Re-opened, the panes go back to the saved or content-sized layout.
      setPositions(defaultHeights())
      return
    } else {
      // Expand: split the space EQUALLY among the now-expanded panes, so re-opening a collapsed
      // section returns the stack to equal heights (a third each for Changes + History + Pull Request)
      // rather than re-opening at the minimum floor with its neighbour hogging the rest.
      heights = InspectorPanePolicy.allocate(
        collapsed: collapsedFlags, weights: nil,
        capacity: splitView.bounds.height, dividerThickness: splitView.dividerThickness)
    }
    setPositions(heights)
    // A split that restores its layout on expand keeps the weights a drag saved through a fold.
    if !sizing.restoresLayoutOnExpand { reportWeights(from: heights) }
  }

  /// Set divider positions to realise `heights` (top to bottom).
  private func setPositions(_ heights: [CGFloat]) {
    var offset: CGFloat = 0
    for index in 0..<(panes.count - 1) {
      offset += heights[index]
      splitView.setPosition(offset, ofDividerAt: index)
      offset += splitView.dividerThickness
    }
  }

  /// Persist a toggle's resulting layout as weights: each expanded pane reports its new height; a
  /// collapsed pane keeps its remembered weight (which `allocate` ignores while it's collapsed and
  /// renormalises among the expanded panes on re-expand). No-op if nothing changed. This reuses the
  /// drag-capture channel (`onWeightsChanged`); the follow-up `update` it triggers sees no
  /// workroom/collapse change and so does not re-layout.
  private func reportWeights(from heights: [CGFloat]) {
    var reported = weights
    for index in panes.indices where !collapsedFlags[index] { reported[index] = heights[index] }
    guard reported != weights else { return }
    weights = reported
    onWeightsChanged?(reported.map { Double($0) })
  }

  /// Capture the new proportions when the user drags a divider. Two conditions distinguish a real
  /// drag from programmatic distribution / the inspector's open animation / a window resize: the
  /// notification carries a divider index (window resizes don't), and the left mouse button is down
  /// (`isLikelyUserDrag` — programmatic moves and animations fire after the triggering click's
  /// mouse-up). Collapsed panes keep their remembered weight so re-expanding restores a sensible
  /// share.
  func splitViewDidResizeSubviews(_ notification: Notification) {
    guard notification.userInfo?["NSSplitViewDividerIndex"] != nil, isLikelyUserDrag()
    else { return }
    var updated = weights
    for (index, pane) in panes.enumerated() where !collapsedFlags[index] {
      updated[index] = pane.view.frame.height
    }
    weights = updated
    onWeightsChanged?(updated.map { Double($0) })
  }

  /// A collapsed pane is pinned to the header (strong but breakable, so an all-collapsed split can
  /// still let the last pane fill rather than fight an unsatisfiable layout); an expanded pane is
  /// floored at `expandedMinHeight` (breakable, so a too-short window compresses it and it scrolls).
  private func makeHeightConstraint(for pane: NSViewController, collapsed: Bool)
    -> NSLayoutConstraint
  {
    let index = panes.firstIndex { $0 === pane } ?? 0
    if collapsed {
      let c = pane.view.heightAnchor.constraint(equalToConstant: InspectorPanePolicy.headerHeight)
      c.priority = .required - 1
      return c
    }
    let c = pane.view.heightAnchor.constraint(
      greaterThanOrEqualToConstant: InspectorPanePolicy.minHeight(index, sizing.minHeights))
    c.priority = .defaultHigh
    return c
  }
}

// MARK: - SwiftUI bridge

/// SwiftUI bridge for `InspectorSplitContainerController`. Each section's header and body are passed
/// as `AnyView`s already carrying their environment (the hosted SwiftUI does not inherit the
/// parent's `@EnvironmentObject`s across `NSHostingController`, so the caller injects them), plus
/// the collapse flags. Arrays are ordered as `InspectorSectionKind.allCases`.
struct InspectorSplitView: NSViewControllerRepresentable {
  var headers: [AnyView]
  var bodies: [AnyView]
  var collapsed: [Bool]
  /// Per-section: whether the pane hosts its body in **fill** mode (the body scrolls itself) rather
  /// than the default `NSScrollView` hosting. History uses fill mode so its inline accordion animates
  /// via SwiftUI without fighting the AppKit scroll container.
  var fills: [Bool]
  /// Identifies the active activity-bar section's sub-section set (its raw value). When it changes,
  /// the pane count/identity differs, so the controller rebuilds its panes rather than reusing them.
  var sectionKey: String
  /// A stable key for the selected workroom (so the controller re-distributes when it switches).
  var workroomKey: String
  /// The selected workroom's persisted relative pane heights (equal by default).
  var weights: [Double]
  /// Reports the new relative pane heights after the user drags a divider, for persistence.
  var onWeightsChanged: ([Double]) -> Void
  /// Content-sized pane heights, used while no layout is saved (`weights` empty); nil otherwise.
  var preferredHeights: [CGFloat?]? = nil
  /// How this use sizes its panes (`InspectorSplitContainerController.Sizing`); the inspector's by
  /// default.
  var sizing = InspectorSplitContainerController.Sizing()
  /// Whether the fill-mode panes draw overlay scrollers whatever the system setting
  /// (`InspectorPaneViewController.forcesOverlayScrollers`).
  var forcesOverlayScrollers = false
  /// What each pane's scroll position is remembered under (#810), nil for none; empty for no
  /// memory at all.
  var scrollKeys: [String?] = []
  /// Where those positions are remembered.
  var scrollMemory: InspectorScrollMemory? = nil

  func makeNSViewController(context: Context) -> InspectorSplitContainerController {
    let panes = makePanes()
    context.coordinator.panes = panes
    context.coordinator.sectionKey = sectionKey
    let controller = InspectorSplitContainerController()
    controller.sizing = sizing
    controller.onWeightsChanged = onWeightsChanged
    controller.install(panes: panes)
    pushContent(into: panes, glass: context.environment.glassAppearance)
    controller.update(
      workroomKey: workroomKey, collapsed: collapsed, weights: weights,
      preferredHeights: preferredHeights)
    return controller
  }

  func updateNSViewController(_ controller: InspectorSplitContainerController, context: Context) {
    controller.onWeightsChanged = onWeightsChanged
    // Active section changed (or the pane count differs) → rebuild the panes for the new sub-section
    // set before pushing content, so headers/bodies/collapse all line up with the new pane list.
    if context.coordinator.sectionKey != sectionKey
      || context.coordinator.panes.count != headers.count
    {
      let panes = makePanes()
      context.coordinator.panes = panes
      context.coordinator.sectionKey = sectionKey
      controller.rebuild(panes: panes)
    }
    pushContent(into: context.coordinator.panes, glass: context.environment.glassAppearance)
    controller.update(
      workroomKey: workroomKey, collapsed: collapsed, weights: weights,
      preferredHeights: preferredHeights)
  }

  /// Fill the space SwiftUI offers. Without this, SwiftUI sizes the controller to the split's
  /// (tiny) intrinsic content size and the inspector renders as a sliver.
  func sizeThatFits(
    _ proposal: ProposedViewSize, nsViewController: InspectorSplitContainerController,
    context: Context
  ) -> CGSize? {
    proposal.replacingUnspecifiedDimensions(by: CGSize(width: 260, height: 400))
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// Create one pane per section, each pre-configured with its body hosting mode (set BEFORE the
  /// pane's view loads, since `fillsBody` is read in `loadView`).
  private func makePanes() -> [InspectorPaneViewController] {
    (0..<headers.count).map { index in
      let pane = InspectorPaneViewController()
      pane.fillsBody = index < fills.count && fills[index]
      pane.forcesOverlayScrollers = forcesOverlayScrollers
      return pane
    }
  }

  private func pushContent(into panes: [InspectorPaneViewController], glass: GlassAppearance) {
    guard panes.count == headers.count, panes.count == bodies.count, panes.count == collapsed.count
    else { return }
    for (index, pane) in panes.enumerated() {
      pane.setContent(
        header: headers[index], body: bodies[index], collapsed: collapsed[index], glass: glass)
      if index < scrollKeys.count {
        pane.remembersScroll(under: scrollKeys[index], in: scrollMemory)
      }
    }
  }

  final class Coordinator {
    var panes: [InspectorPaneViewController] = []
    /// The section-set the current `panes` were built for; a change triggers a rebuild.
    var sectionKey: String = ""
  }
}

// MARK: - Section header (the sticky bar)

/// One inspector section's header bar: a disclosure chevron, the title, an optional status
/// indicator, and a trailing action accessory. Tapping anywhere toggles `collapsed`. The chevron
/// rotates (a single glyph) so it never changes width. This is hosted as the pane's fixed sticky
/// header — its body content is hosted separately in the pane's scroll view.
struct SectionHeader<Accessory: View>: View {
  let title: String
  /// The section's collapse binding, or `nil` for a **solo** pane (a section whose activity-bar pane
  /// stacks only itself, e.g. Files) — a solo pane can't collapse, so its header shows no chevron and
  /// is a static label rather than a toggle button.
  var collapsed: Binding<Bool>? = nil
  var indicator: AnyView = AnyView(EmptyView())
  var indicatorLabel: String = ""
  /// The View-menu shortcut that reveals this section (e.g. "⌥⌘C"), shown in the header tooltip for
  /// discoverability. Nil for sections with no command equivalent.
  var shortcut: String? = nil
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    Group {
      if let collapsed {
        Button {
          collapsed.wrappedValue.toggle()
        } label: {
          headerLabel(collapsed: collapsed.wrappedValue, showsChevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "\(title) section, \(collapsed.wrappedValue ? "collapsed" : "expanded")"
            + (indicatorLabel.isEmpty ? "" : ", \(indicatorLabel)")
        )
        .help(
          (collapsed.wrappedValue ? "Expand \(title)" : "Collapse \(title)")
            + (shortcut.map { " (\($0))" } ?? "")
        )
      } else {
        headerLabel(collapsed: false, showsChevron: false)
          .accessibilityLabel(
            "\(title) section" + (indicatorLabel.isEmpty ? "" : ", \(indicatorLabel)")
          )
          .help(shortcut.map { "\(title) (\($0))" } ?? title)
      }
    }
    .accessibilityIdentifier("inspector.header.\(title)")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sectionHeaderBand()
    .overlay(alignment: .trailing) {
      accessory().padding(.trailing, SectionHeaderMetrics.horizontalPadding)
    }
  }

  /// The header's row: an optional rotating disclosure chevron, the title, a status indicator, and a
  /// trailing spacer (the action accessory is overlaid by `body`). The chevron is omitted for a solo
  /// pane (`showsChevron == false`).
  private func headerLabel(collapsed: Bool, showsChevron: Bool) -> some View {
    SectionHeaderLabel(
      title: title, collapsed: showsChevron ? collapsed : nil, indicator: indicator)
  }
}

/// What every section header shares: the inspector's (`SectionHeader`) and the sidebar's Terminals
/// and Projects headings (`SidebarSectionHeading`). One set of numbers, so the two read as one kind.
enum SectionHeaderMetrics {
  /// The band's height: a collapsed inspector pane's, too.
  static let height: CGFloat = InspectorPanePolicy.headerHeight
  /// Between the band's leading edge and the chevron, and the trailing edge and the accessory.
  static let horizontalPadding: CGFloat = 12
  /// The sidebar headings' leading padding: the sidebar rows' own base margin
  /// (`ProjectSidebar.rowInsets.leading`), so the band reads tight against the narrower column.
  static let sidebarLeadingPadding: CGFloat = 6
  static let verticalPadding: CGFloat = 8
  /// Between the chevron, the title and the indicator.
  static let spacing: CGFloat = 7
  static let chevronWidth: CGFloat = 12
  static let titleFont = Font.system(size: 11, weight: .semibold)
  static let chevronFont = Font.system(size: 11, weight: .semibold)
}

extension View {
  /// A section header's full-width tinted band.
  func sectionHeaderBand() -> some View { modifier(SectionHeaderBand()) }
}

/// The fill behind a section header: the raised wash (`ThemeFill.raised`), as under Glass.
struct SectionHeaderBand: ViewModifier {
  func body(content: Content) -> some View {
    content.background(ThemeFill.raised)
  }
}

/// A section header's row: a leading disclosure chevron that rotates (one glyph, so it never changes
/// width), the bold title, an optional indicator and a trailing spacer. `collapsed == nil` draws no
/// chevron (a solo inspector pane).
struct SectionHeaderLabel<Indicator: View>: View {
  let title: String
  let collapsed: Bool?
  let indicator: Indicator
  /// Between the band's leading edge and the chevron: the inspector's `horizontalPadding`, or the
  /// sidebar's tighter `SectionHeaderMetrics.sidebarLeadingPadding`.
  var leadingPadding: CGFloat = SectionHeaderMetrics.horizontalPadding

  init(
    title: String, collapsed: Bool?, indicator: Indicator,
    leadingPadding: CGFloat = SectionHeaderMetrics.horizontalPadding
  ) {
    self.title = title
    self.collapsed = collapsed
    self.indicator = indicator
    self.leadingPadding = leadingPadding
  }

  var body: some View {
    HStack(spacing: SectionHeaderMetrics.spacing) {
      if let collapsed {
        Image(systemName: "chevron.right")
          .font(SectionHeaderMetrics.chevronFont)
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(collapsed ? 0 : 90))
          .frame(width: SectionHeaderMetrics.chevronWidth, alignment: .center)
      }
      Text(title).font(SectionHeaderMetrics.titleFont)
      indicator
      Spacer(minLength: 0)
    }
    .padding(.leading, leadingPadding)
    .padding(.trailing, SectionHeaderMetrics.horizontalPadding)
    .padding(.vertical, SectionHeaderMetrics.verticalPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

extension SectionHeaderLabel where Indicator == EmptyView {
  init(
    title: String, collapsed: Bool?,
    leadingPadding: CGFloat = SectionHeaderMetrics.horizontalPadding
  ) {
    self.init(
      title: title, collapsed: collapsed, indicator: EmptyView(), leadingPadding: leadingPadding)
  }
}
