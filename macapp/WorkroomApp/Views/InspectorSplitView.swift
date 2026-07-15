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
///   `NSScrollView` bridge, so an inline height animation inside the body (the History pane's
///   divergence expander) is driven entirely by SwiftUI and can't fight AppKit's scroll-container
///   resize-anchoring — the source of the visible content shift the bridge produced.
///
/// When collapsed, the body is hidden and the enclosing split pins the pane to the header height.
final class InspectorPaneViewController: NSViewController {
  private let headerHost = NSHostingController(rootView: AnyView(EmptyView()))
  private let bodyScroll = NSScrollView()
  private let bodyHost = NSHostingController(rootView: AnyView(EmptyView()))
  /// Whether the body fills the pane and scrolls itself (vs. the default `NSScrollView` hosting).
  /// Must be set before the view first loads.
  var fillsBody = false

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
  /// enclosing split also pins a collapsed pane to the header height).
  func setContent(header: AnyView, body: AnyView, collapsed: Bool) {
    _ = view  // ensure loaded
    headerHost.rootView = header
    bodyHost.rootView = body
    (fillsBody ? bodyHost.view : bodyScroll).isHidden = collapsed
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
///   (`allocate`) — re-opening a collapsed section returns the stack to equal heights (half each for
///   Changes + Pull Request) rather than the minimum floor.
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
  let splitView = ThemedSplitView()
  private(set) var panes: [InspectorPaneViewController] = []
  private var heightConstraints: [NSLayoutConstraint] = []
  // Sized to the installed pane count, which is dynamic: the active activity-bar section decides how
  // many sub-sections its pane stacks (2 for Changes + Pull Request, 1 for Files). Empty until the
  // first `install`.
  private var collapsedFlags: [Bool] = []
  private var weights: [CGFloat] = []
  private var workroomKey = ""

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
      splitView.setHoldingPriority(.defaultLow, forSubviewAt: index)
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
  func update(workroomKey: String, collapsed: [Bool], weights: [Double]) {
    precondition(collapsed.count == panes.count, "need one collapse flag per section")
    let resolvedWeights =
      weights.count == panes.count ? weights.map { CGFloat($0) } : self.weights
    let workroomChanged = workroomKey != self.workroomKey
    let previousCollapsed = collapsedFlags
    let collapseChanged = collapsed != previousCollapsed
    self.weights = resolvedWeights
    self.workroomKey = workroomKey
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
    let heights = InspectorPanePolicy.allocate(
      collapsed: collapsedFlags, weights: weights, capacity: splitView.bounds.height,
      dividerThickness: splitView.dividerThickness)
    setPositions(heights)
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
        capacity: splitView.bounds.height, dividerThickness: splitView.dividerThickness)
    } else {
      // Expand: split the space EQUALLY among the now-expanded panes, so re-opening a collapsed
      // section returns the stack to equal heights (half each for Changes + Pull Request) rather than
      // re-opening at the minimum floor with its neighbour hogging the rest.
      heights = InspectorPanePolicy.allocate(
        collapsed: collapsedFlags, weights: nil,
        capacity: splitView.bounds.height, dividerThickness: splitView.dividerThickness)
    }
    setPositions(heights)
    reportWeights(from: heights)
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
    if collapsed {
      let c = pane.view.heightAnchor.constraint(equalToConstant: InspectorPanePolicy.headerHeight)
      c.priority = .required - 1
      return c
    }
    let c = pane.view.heightAnchor.constraint(
      greaterThanOrEqualToConstant: InspectorPanePolicy.expandedMinHeight)
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

  func makeNSViewController(context: Context) -> InspectorSplitContainerController {
    let panes = makePanes()
    context.coordinator.panes = panes
    context.coordinator.sectionKey = sectionKey
    let controller = InspectorSplitContainerController()
    controller.onWeightsChanged = onWeightsChanged
    controller.install(panes: panes)
    pushContent(into: panes)
    controller.update(workroomKey: workroomKey, collapsed: collapsed, weights: weights)
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
    pushContent(into: context.coordinator.panes)
    controller.update(workroomKey: workroomKey, collapsed: collapsed, weights: weights)
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
      return pane
    }
  }

  private func pushContent(into panes: [InspectorPaneViewController]) {
    guard panes.count == headers.count, panes.count == bodies.count, panes.count == collapsed.count
    else { return }
    for (index, pane) in panes.enumerated() {
      pane.setContent(header: headers[index], body: bodies[index], collapsed: collapsed[index])
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
    .background(ThemeService.shared.tokens.surface)
    .overlay(alignment: .trailing) {
      accessory().padding(.trailing, 12)
    }
  }

  /// The header's row: an optional rotating disclosure chevron, the title, a status indicator, and a
  /// trailing spacer (the action accessory is overlaid by `body`). The chevron is omitted for a solo
  /// pane (`showsChevron == false`).
  @ViewBuilder private func headerLabel(collapsed: Bool, showsChevron: Bool) -> some View {
    HStack(spacing: 7) {
      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(collapsed ? 0 : 90))
          .frame(width: 12, alignment: .center)
      }
      Text(title).font(.system(size: 11, weight: .semibold))
      indicator
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
