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
/// body is an `NSHostingController` inside a vertically-scrolling `NSScrollView` filling the rest.
/// The body hosting view uses `.intrinsicContentSize` so it reports its natural height and the
/// scroll view scrolls when the pane is shorter than the content. A raw `NSScrollView` already
/// auto-hides and tracks the system "Show scroll bars" preference. When collapsed, the body scroll
/// view is hidden and the enclosing split pins the pane to the header height.
final class InspectorPaneViewController: NSViewController {
  private let headerHost = NSHostingController(rootView: AnyView(EmptyView()))
  private let bodyScroll = NSScrollView()
  private let bodyHost = NSHostingController(rootView: AnyView(EmptyView()))

  override func loadView() {
    let container = NSView()

    // Add the body scroll view FIRST, then the header, so the header is topmost in z-order — the
    // opaque sticky header always sits above the scrolling body and the content can never bleed over
    // the title during a resize.
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

    headerHost.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(headerHost)
    container.addSubview(headerHost.view)

    NSLayoutConstraint.activate([
      // Sticky header: fixed height at the top.
      headerHost.view.topAnchor.constraint(equalTo: container.topAnchor),
      headerHost.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      headerHost.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      headerHost.view.heightAnchor.constraint(equalToConstant: InspectorPanePolicy.headerHeight),

      // Body scroll view fills the rest of the pane below the header.
      bodyScroll.topAnchor.constraint(equalTo: headerHost.view.bottomAnchor),
      bodyScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      bodyScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bodyScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

      // Document pinned to the clip view's top/width (free height → it grows to content and the
      // scroll view scrolls when the pane is shorter than the content).
      document.topAnchor.constraint(equalTo: bodyScroll.contentView.topAnchor),
      document.leadingAnchor.constraint(equalTo: bodyScroll.contentView.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: bodyScroll.contentView.trailingAnchor),
      document.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),
    ])
    view = container
  }

  /// Swap the hosted header + body. The body scroll view is hidden when collapsed so only the header
  /// shows (the enclosing split also pins a collapsed pane to the header height).
  func setContent(header: AnyView, body: AnyView, collapsed: Bool) {
    _ = view  // ensure loaded
    headerHost.rootView = header
    bodyHost.rootView = body
    bodyScroll.isHidden = collapsed
  }
}

// MARK: - Split container

/// Owns the raw `NSSplitView` and the three pane child controllers. Sizing rules:
///
/// - A per-pane height constraint (swapped on collapse change) pins a collapsed pane to the header
///   and floors an expanded pane at `expandedMinHeight` — this is what a drag and a window resize
///   respect.
/// - The **default** distribution (equal among expanded panes) is applied once via `setPosition`
///   after the first real layout, and re-applied whenever the collapse state changes. Plain window
///   resizes keep the user's proportions (native `NSSplitView` behaviour); only a collapse toggle
///   re-distributes, so a manual drag is preserved until the user collapses/expands a section.
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
  private var collapsedFlags = [Bool](repeating: false, count: InspectorSectionKind.allCases.count)
  private var weights = [CGFloat](repeating: 1, count: InspectorSectionKind.allCases.count)
  private var workroomKey = ""
  private var needsDefaultDistribution = true

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

  /// Install one arranged subview per section, in `InspectorSectionKind.allCases` order. Call once.
  func install(panes: [InspectorPaneViewController]) {
    precondition(panes.count == InspectorSectionKind.allCases.count, "need one pane per section")
    self.panes = panes
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

  /// Reflect the selected workroom's layout: its key, collapse state, and persisted pane weights.
  /// A change of workroom *or* collapse state re-distributes on the next layout (those are exactly
  /// when the saved/default proportions should reassert); a mere weights update coming back from a
  /// drag does not (the divider is already where the user left it).
  func update(workroomKey: String, collapsed: [Bool], weights: [Double]) {
    precondition(collapsed.count == panes.count, "need one collapse flag per section")
    let resolvedWeights =
      weights.count == panes.count ? weights.map { CGFloat($0) } : self.weights
    let workroomChanged = workroomKey != self.workroomKey
    let collapseChanged = collapsed != collapsedFlags
    self.weights = resolvedWeights
    self.workroomKey = workroomKey
    guard workroomChanged || collapseChanged else { return }

    collapsedFlags = collapsed
    swapHeightConstraints()
    needsDefaultDistribution = true
    view.needsLayout = true
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    guard needsDefaultDistribution, splitView.bounds.height > 0 else { return }
    needsDefaultDistribution = false
    redistribute()
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
  /// rest split by the saved weights — equal by default) via divider positions.
  private func redistribute() {
    let heights = InspectorPanePolicy.allocate(
      collapsed: collapsedFlags, weights: weights, capacity: splitView.bounds.height,
      dividerThickness: splitView.dividerThickness)
    var offset: CGFloat = 0
    for index in 0..<(panes.count - 1) {
      offset += heights[index]
      splitView.setPosition(offset, ofDividerAt: index)
      offset += splitView.dividerThickness
    }
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
  /// A stable key for the selected workroom (so the controller re-distributes when it switches).
  var workroomKey: String
  /// The selected workroom's persisted relative pane heights (equal by default).
  var weights: [Double]
  /// Reports the new relative pane heights after the user drags a divider, for persistence.
  var onWeightsChanged: ([Double]) -> Void

  func makeNSViewController(context: Context) -> InspectorSplitContainerController {
    let panes = (0..<InspectorSectionKind.allCases.count).map { _ in InspectorPaneViewController() }
    context.coordinator.panes = panes
    let controller = InspectorSplitContainerController()
    controller.onWeightsChanged = onWeightsChanged
    controller.install(panes: panes)
    pushContent(into: panes)
    controller.update(workroomKey: workroomKey, collapsed: collapsed, weights: weights)
    return controller
  }

  func updateNSViewController(_ controller: InspectorSplitContainerController, context: Context) {
    controller.onWeightsChanged = onWeightsChanged
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

  private func pushContent(into panes: [InspectorPaneViewController]) {
    guard panes.count == headers.count, panes.count == bodies.count, panes.count == collapsed.count
    else { return }
    for (index, pane) in panes.enumerated() {
      pane.setContent(header: headers[index], body: bodies[index], collapsed: collapsed[index])
    }
  }

  final class Coordinator {
    var panes: [InspectorPaneViewController] = []
  }
}

// MARK: - Section header (the sticky bar)

/// One inspector section's header bar: a disclosure chevron, the title, an optional status
/// indicator, and a trailing action accessory. Tapping anywhere toggles `collapsed`. The chevron
/// rotates (a single glyph) so it never changes width. This is hosted as the pane's fixed sticky
/// header — its body content is hosted separately in the pane's scroll view.
struct SectionHeader<Accessory: View>: View {
  let title: String
  @Binding var collapsed: Bool
  var indicator: AnyView = AnyView(EmptyView())
  var indicatorLabel: String = ""
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    Button {
      collapsed.toggle()
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(collapsed ? 0 : 90))
          .frame(width: 12, alignment: .center)
        Text(title).font(.system(size: 11, weight: .semibold))
        indicator
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "\(title) section, \(collapsed ? "collapsed" : "expanded")"
        + (indicatorLabel.isEmpty ? "" : ", \(indicatorLabel)")
    )
    .accessibilityIdentifier("inspector.header.\(title)")
    .help(collapsed ? "Expand \(title)" : "Collapse \(title)")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ThemeService.shared.tokens.surface)
    .overlay(alignment: .trailing) {
      accessory().padding(.trailing, 12)
    }
  }
}
