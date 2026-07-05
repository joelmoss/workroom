import AppKit

/// Which inspector section a pane hosts. Mirrors the `RightInspector` sections, top to bottom:
/// Changes, Files, Pull Request. Used for ordering and the section count. (Notifications moved to
/// the left sidebar, issue #118.)
enum InspectorSectionKind: CaseIterable {
  case changes
  case files
  case pullRequest
}

/// The vertical sizing constraints one inspector pane imposes on the `NSSplitView`, derived purely
/// from whether the section is collapsed.
///
/// ```
///                  minHeight          maxHeight        holdingPriority
///   collapsed      headerHeight       headerHeight     high   (pinned — only the header shows)
///   expanded       expandedMinHeight  .infinity        low    (resizable, floored, fills/yields)
/// ```
///
/// `holdingPriority` is NSSplitView's resize-resistance: a window resize between explicit
/// re-layouts is absorbed by the lowest-priority (expanded) panes, never a collapsed/pinned one.
/// The deterministic *default* distribution (equal thirds) is set explicitly via
/// `InspectorPanePolicy.allocate`; these constraints only bound what a drag can do.
struct PaneConstraints: Equatable {
  var minHeight: CGFloat
  var maxHeight: CGFloat
  var holdingPriority: NSLayoutConstraint.Priority

  /// A collapsed pane is pinned: it can't be resized in either direction.
  var isPinned: Bool { minHeight == maxHeight }
}

/// Pure, headless-testable sizing rules for the inspector's `NSSplitView` panes. No SwiftUI, no
/// view tree, no content measurement — `NSSplitViewController` *fills and distributes* space (it
/// does not hug content), so the policy decides the floors/ceilings each pane imposes on a drag
/// plus the deterministic default distribution (`allocate`). The pane's own `NSScrollView` handles
/// any overflow when content is taller than the allocated height.
enum InspectorPanePolicy {
  /// Header-bar height. Also the height of a collapsed pane (only the header shows) and the sticky
  /// header that sits above each expanded pane's scrollable body. Constant by decision — measuring
  /// it would reintroduce the timing-dependent layout state this migration removed.
  static let headerHeight: CGFloat = 34

  /// The smallest an *expanded* pane may be dragged to: its header plus a couple of body rows, so a
  /// section always stays usable (and, when its content is taller, scrollable) rather than being
  /// squeezed to an unreadable sliver. This is the drag floor and the per-pane minimum.
  static let expandedMinHeight: CGFloat = 120

  static func constraints(collapsed: Bool) -> PaneConstraints {
    // Collapsed: pin to the header, body hidden. Pinned, so holding priority is moot but kept high
    // so a window resize never tries to steal from a pinned pane.
    if collapsed {
      return PaneConstraints(
        minHeight: headerHeight, maxHeight: headerHeight, holdingPriority: .defaultHigh)
    }
    // Expanded: floor at expandedMinHeight, no ceiling (free to drag/grow), and lowest holding
    // priority so a window resize is absorbed here rather than by a pinned pane.
    return PaneConstraints(
      minHeight: expandedMinHeight,
      maxHeight: .greatestFiniteMagnitude,
      holdingPriority: .defaultLow)
  }

  /// The pane heights for the given collapse state and available `capacity` (the split view's
  /// height), accounting for the dividers between panes.
  ///
  /// - Collapsed panes take exactly `headerHeight`.
  /// - The remaining space goes to the expanded panes: **equally** when `weights` is `nil` (the
  ///   default — three equal sections when all are open), or in proportion to the persisted
  ///   `weights` of the *currently expanded* panes (renormalised among them) once the user has
  ///   dragged a divider. Each expanded pane is floored at `expandedMinHeight`; when the floors
  ///   don't fit, panes still get their floor and overflow into their own scroll views.
  ///
  /// The result is realised by the controller via `setPosition(ofDividerAt:)`; the user can then
  /// drag dividers freely within the `constraints` floors.
  static func allocate(
    collapsed: [Bool], weights: [CGFloat]? = nil, capacity: CGFloat, dividerThickness: CGFloat
  ) -> [CGFloat] {
    let n = collapsed.count
    guard n > 0 else { return [] }
    guard capacity > 0 else { return Array(repeating: 0, count: n) }

    let dividers = dividerThickness * CGFloat(max(0, n - 1))
    let expanded = (0..<n).filter { !collapsed[$0] }
    let collapsedTotal = CGFloat(n - expanded.count) * headerHeight
    let available = max(0, capacity - dividers - collapsedTotal)

    var heights = Array(repeating: 0 as CGFloat, count: n)
    for i in 0..<n where collapsed[i] { heights[i] = headerHeight }
    guard !expanded.isEmpty else { return heights }

    // Per-expanded-pane share: each expanded pane's weight (default 1 = equal) over the sum of the
    // expanded panes' weights. A non-positive or missing weight falls back to an equal share.
    let rawWeights = expanded.map { index -> CGFloat in
      guard let weights, index < weights.count, weights[index] > 0 else { return 1 }
      return weights[index]
    }
    let totalWeight = rawWeights.reduce(0, +)
    for (slot, index) in expanded.enumerated() {
      let share = totalWeight > 0 ? available * (rawWeights[slot] / totalWeight) : 0
      heights[index] = max(expandedMinHeight, share)
    }
    return heights
  }

  /// Re-derive pane heights after a **single** section's collapse state toggled, preserving the
  /// heights of every *other* pane so a manual resize elsewhere isn't disturbed (issue: collapsing
  /// one section reset a divider the user had dragged between two others). `allocate`'s proportional
  /// renormalisation moves every divider on a collapse; this keeps them put.
  ///
  /// - The toggled pane goes to the header when it collapsed, or to `expandedMinHeight` when it
  ///   expanded (so it re-opens to a usable size).
  /// - Every other expanded pane keeps its current height (floored at `expandedMinHeight`).
  /// - The resulting surplus (a collapse frees space) or deficit (an expand needs space) is absorbed
  ///   by / taken from the nearest expanded neighbour — the pane directly below the toggled section
  ///   first (content below slides up to fill), then the one above, widening outward. A deficit that
  ///   would push a neighbour below its floor spills to the next-nearest expanded pane; if nothing
  ///   fits, panes hold their floor and overflow into their own scroll views.
  ///
  /// Because only a neighbour flexes, every divider *not* adjacent to the toggle stays exactly where
  /// the user left it. Used only for a lone toggle within one workroom; a workroom switch or a
  /// multi-flag change re-derives the whole layout from the saved weights via `allocate`.
  static func reallocateOnToggle(
    previous: [CGFloat], collapsed: [Bool], toggled: Int, capacity: CGFloat,
    dividerThickness: CGFloat
  ) -> [CGFloat] {
    let n = collapsed.count
    guard n > 0, previous.count == n, toggled >= 0, toggled < n else { return previous }
    guard capacity > 0 else { return Array(repeating: 0, count: n) }

    let dividers = dividerThickness * CGFloat(max(0, n - 1))
    let target = max(0, capacity - dividers)

    // Fix every pane: collapsed → header; the toggled (now-expanded) pane → its floor; every other
    // expanded pane keeps its current height (floored). Only the anchor(s) flex to reconcile the sum.
    var heights = previous
    for i in 0..<n {
      if collapsed[i] {
        heights[i] = headerHeight
      } else if i == toggled {
        heights[i] = expandedMinHeight
      } else {
        heights[i] = max(expandedMinHeight, heights[i])
      }
    }

    let anchors = anchorOrder(around: toggled, collapsed: collapsed)
    guard !anchors.isEmpty else {
      // The toggled pane is the only expanded one — it fills whatever the collapsed headers leave.
      heights[toggled] = max(expandedMinHeight, target - CGFloat(n - 1) * headerHeight)
      return heights
    }

    var delta = target - heights.reduce(0, +)
    if delta >= 0 {
      heights[anchors[0]] += delta  // freed space → the nearest expanded neighbour
    } else {
      for anchor in anchors {  // deficit → take from neighbours, nearest first, down to their floor
        let room = max(0, heights[anchor] - expandedMinHeight)
        let take = min(-delta, room)
        heights[anchor] -= take
        delta += take
        if delta >= 0 { break }
      }
    }
    return heights
  }

  /// Expanded panes other than `toggled`, ordered by proximity to it — the pane directly below the
  /// toggled section first, then the one above, widening outward. The anchor a collapse/expand flexes.
  private static func anchorOrder(around toggled: Int, collapsed: [Bool]) -> [Int] {
    let n = collapsed.count
    var order: [Int] = []
    var distance = 1
    while toggled + distance < n || toggled - distance >= 0 {
      let below = toggled + distance
      if below < n, !collapsed[below] { order.append(below) }
      let above = toggled - distance
      if above >= 0, !collapsed[above] { order.append(above) }
      distance += 1
    }
    return order
  }
}
