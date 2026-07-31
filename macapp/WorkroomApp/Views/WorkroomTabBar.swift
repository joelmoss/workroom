import SwiftUI

/// The workroom tab bar shown in the title bar (issue #23): a chip per active target (a workroom or
/// project root with ≥1 terminal), drag-to-reorder (reusing the shared `TabReorder` math). A tab
/// appears when its workroom gains a terminal and disappears when it loses its last. The "selected"
/// chip **is** `store.selectedTargetID` — tapping one selects that target (like the sidebar), so every
/// selection-driven command (⌘T/⌘W/splits/run/notifications/⌥⌘1–9) operates on the focused workroom.
/// No per-chip close button: a tab vanishes when its terminals are closed, and closing-as-kill would
/// defeat the parallel-monitoring purpose.
///
/// The trailing controls (open-workroom + "+") are **adaptive** (issue #129), mirroring
/// `TerminalTabStrip`: they sit inline hugging the last chip while everything fits, and pin at the
/// bar's trailing edge once the chips overflow, so the "+" is never scrolled out of reach. They move as
/// one block — they share a size/style and ⌘O/⌘N, and a chevron left behind in the scroller would be
/// the first thing to scroll away. The decision is the shared `TabStripOverflow.pinsControls`, and the
/// scaffolding around it is the shared `OverflowingTabScroller` (so the two strips can't drift).
struct WorkroomTabBar: View {
  let tabs: [(sid: SidebarID, target: TerminalTarget)]
  let selectedID: SidebarID?
  let onSelect: (SidebarID) -> Void
  /// The live drag of a chip into the detail content (to form a split), in content-local coords —
  /// shared with `WorkroomSplitView` via `RootView` so the same drop-edge highlight renders (issue #23
  /// follow-up). nil while not dragging into the content (a plain strip reorder).
  @Binding var chipPaneDrag: WorkroomPaneDrag?
  /// The content-local point for a chip drag at a global location, or nil when the cursor is still over
  /// the bar (→ a reorder, not a drop-into-content). Owned by `RootView` (it knows the content frame).
  let localize: (CGPoint) -> CGPoint?
  /// Where a chip dropped at a global location lands (workroom pane + edge), or nil if not over a pane.
  let dropTarget: (CGPoint) -> (sid: SidebarID, edge: PaneEdge)?

  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var hoveredID: SidebarID?
  @State private var addHovering = false
  @State private var openHovering = false

  // Drag-to-reorder: the order is frozen during a drag (the dragged chip follows the cursor, the rest
  // slide aside to open a gap), committed once on drop — mirrors `TerminalTabStrip`.
  @State private var draggingID: SidebarID?
  @State private var dragTranslation: CGFloat = 0
  @State private var widths: [SidebarID: CGFloat] = [:]

  private let tabSpacing: CGFloat = 4

  /// Whether the hairline before the trailing controls shows. Hidden when the last tab stands apart on
  /// its own (selected or hovered — its filled pill already separates it), when it's in a split group
  /// (the `splitWell` bracket frames it, so a divider would double against its rounded edge), and once
  /// the controls have pinned (issue #129): the fade and gutter already separate the regions.
  private func showsTrailingDivider(overflowing: Bool, groupOf: [SidebarID: Int]) -> Bool {
    guard !overflowing else { return false }
    guard let last = tabs.last else { return true }
    return groupOf[last.sid] == nil && last.sid != selectedID && last.sid != hoveredID
  }

  var body: some View {
    let draggedIndex = draggingID.flatMap { id in tabs.firstIndex { $0.sid == id } }
    // While dragging a chip down into the content (forming a split), the strip stops opening a reorder
    // gap — mirrors `TerminalTabStrip`.
    let dropIndex =
      chipPaneDrag != nil
      ? nil
      : draggedIndex.map {
        TabReorder.dropTargetIndex(
          widths: tabs.map { widths[$0.sid] ?? 0 }, draggedIndex: $0,
          translation: dragTranslation, spacing: tabSpacing)
      }
    let draggedWidth = draggingID.flatMap { widths[$0] } ?? 0

    // The bar fills the gap between the leading and trailing title-bar controls (the container's
    // `frame(maxWidth: .infinity)`), chips left-aligned; it scrolls horizontally when the chips overflow
    // that gap — the chips are never resized (issue #23). The 8pt leading inset is also what the
    // container's trailing content margin is sized against (`TabStripMetrics.fade` is the same 8pt), so
    // nothing moves in the fits case. The controls' block carries its own leading pad inside its
    // measured width, so it needs no positioning pad of its own (`inlineLead: 0`).
    OverflowingTabScroller(
      leadingInset: 8, spacing: tabSpacing, inlineLead: 0,
      // Scroll the selected workroom into view on selection (issue #129 follow-up); suspended
      // mid-drag, like the reorder gap animation below.
      scrollTarget: selectedID, scrollSuspended: draggingID != nil
    ) { overflowing in
      chipRun(
        draggedIndex: draggedIndex, dropIndex: dropIndex, draggedWidth: draggedWidth,
        overflowing: overflowing)
    } controls: {
      trailingControls
    }
    // Disable AppKit's title-bar window drag only while the cursor is over (or dragging) a chip, so a
    // chip drag reorders instead of moving the window — the empty bar still drags it. See
    // `WindowMovableController`. Deliberately NOT widened to the trailing buttons: they already work
    // while the window is movable, and churning a window-wide flag on button hover buys nothing.
    .background(WindowMovableController(movable: draggingID == nil && hoveredID == nil))
  }

  /// The open-workroom + new-workroom buttons as ONE block, rendered inline as the last element of the
  /// scrolling row while everything fits, or pinned at the bar's trailing edge once the chips overflow
  /// (issue #129). Both move together: they share a size/style (see `openWorkroomButton`) and ⌘O/⌘N, and
  /// a chevron left behind in the scroller would sit under the fade as the first thing to scroll away.
  ///
  /// `fixedSize` so the block keeps its intrinsic width and the scrolling chip area yields first in a
  /// cramped window — the same reason `TerminalTabStrip.tabToolbar` is fixed-size. `OverflowingTabScroller`
  /// measures this width and feeds it to the overflow predicate; the internal spacing is identical in
  /// both positions, so that one number is valid either way, which is what keeps the predicate
  /// branch-independent.
  private var trailingControls: some View {
    HStack(spacing: tabSpacing) {
      openWorkroomButton
      addWorkroomButton
    }
    .fixedSize()
  }

  /// The chips themselves, the provisional "Creating…" chip, and the hairline that sets the trailing
  /// controls apart — everything that scrolls, and everything that stays put across an overflow flip.
  /// Measured as one run for the overflow predicate — which covers the provisional chip and the trailing
  /// hairline too, since both live in this measured row (so neither needs its own bookkeeping; notably
  /// the provisional chip is deliberately absent from `WorkroomTabWidthKey`). The split bracket is drawn
  /// behind it (leading-aligned, so x = 0 is the first chip's leading edge, which is what `splitRunRects`
  /// computes against).
  ///
  /// The split-group map is built ONCE here and threaded into the three readers (per-chip separator,
  /// trailing divider, brackets) — it walks every leaf of every group, and this body re-renders on every
  /// hover and every divider-drag frame.
  @ViewBuilder
  private func chipRun(
    draggedIndex: Int?, dropIndex: Int?, draggedWidth: CGFloat, overflowing: Bool
  ) -> some View {
    let groupOf = store.workroomSplitGroupIndices()
    HStack(spacing: tabSpacing) {
      ForEach(Array(tabs.enumerated()), id: \.element.sid) { index, tab in
        let isDragging = draggingID == tab.sid
        let isHovered = hoveredID == tab.sid && draggingID == nil
        let offsetX =
          isDragging
          ? dragTranslation
          : TabReorder.gapShift(
            index: index, draggedIndex: draggedIndex, target: dropIndex,
            amount: draggedWidth + tabSpacing)
        WorkroomTabChip(
          sid: tab.sid, target: tab.target, isActive: tab.sid == selectedID,
          isHovered: isHovered, isDragging: isDragging,
          showLeadingSeparator: showsLeadingSeparator(at: index, groupOf: groupOf)
        )
        .onHover { inside in
          if inside { hoveredID = tab.sid } else if hoveredID == tab.sid { hoveredID = nil }
        }
        .onTapGesture { onSelect(tab.sid) }
        // Measure in .global space (a .local drag reads coordinates relative to the chip, which
        // itself moves via .offset — that feedback loop lags the cursor). Mirrors TerminalTabStrip.
        .gesture(
          DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
              if draggingID == nil { draggingID = tab.sid }
              guard draggingID == tab.sid else { return }
              // Clamp the reorder so the dragged chip stops at the leading and trailing ends of the
              // tab run — it can't be pulled left into the leading controls or right across the empty
              // fill (the bar spans the full title-bar width). Vertical drag-into-a-split is
              // unaffected (that reads `value.location`, below).
              dragTranslation = clampReorder(value.translation.width, draggedIndex: index)
              // Dragged into the detail content → preview a drop-into-pane split (the strip stops
              // gapping); otherwise it's a plain reorder.
              chipPaneDrag = localize(value.location).map {
                WorkroomPaneDrag(sid: tab.sid, location: $0)
              }
            }
            .onEnded { value in
              if let drop = dropTarget(value.location) {
                store.insertWorkroomSplit(tab.sid, beside: drop.sid, edge: drop.edge)
                draggingID = nil
                dragTranslation = 0
              } else {
                commitDrag()  // a plain strip reorder
              }
              chipPaneDrag = nil
            }
        )
        .offset(x: offsetX)
        .zIndex(isDragging ? 1 : 0)
        .animation(
          isDragging || reduceMotion ? nil : .easeInOut(duration: 0.18), value: offsetX
        )
        // Scroll target for `OverflowingTabScroller`'s `ScrollViewReader` (issue #129 follow-up) — the
        // same id `ForEach` already keys identity on.
        .id(tab.sid)
      }
      // A provisional "Creating…" chip while a workroom is being created in this window (issue
      // #116), shown from the first click until its real named chip resolves into `tabs`. Tapping it
      // refocuses the creating slot (its loader/dialog); it takes no part in drag/reorder.
      if let creating = provisionalCreation {
        ProvisionalWorkroomChip(
          project: creating.project, isActive: store.isCreationFocused,
          onSelect: {
            if let name = creating.name {
              store.selectedTargetID = .workroom(project: creating.project.path, name: name)
            } else {
              store.selectedTargetID = nil
            }
            store.selectedProjectID = creating.project.id
          })
      }
      // A divider sets the trailing controls apart from the last tab — see `showsTrailingDivider` for
      // when it hides. Toggled via OPACITY (not removed) so the controls never shift as hover and
      // selection come and go, which also keeps the measured run width stable across those
      // transitions. Negative leading trims the gap to the last tab to ~2pt (HStack `tabSpacing` 4 − 2),
      // matching the inter-chip dividers.
      Rectangle()
        .fill(ThemeService.shared.tokens.border)
        .frame(width: 1, height: 16)
        .padding(.leading, -2)
        .padding(.trailing, 4)
        .opacity(showsTrailingDivider(overflowing: overflowing, groupOf: groupOf) ? 1 : 0)
    }
    .background(alignment: .leading) { splitWell(groupOf: groupOf) }
    .onPreferenceChange(WorkroomTabWidthKey.self) { widths = $0 }
  }

  /// The in-progress create whose chip isn't yet a real tab (issue #116): shown as a provisional
  /// "Creating…" chip until its named chip resolves into `tabs` (which happens once the CLI reports
  /// the workroom and the reload lands it in `projects`). nil otherwise — no double chip.
  private var provisionalCreation: WorkroomCreation? {
    guard let creation = store.creation else { return nil }
    if let tid = creation.targetID, tabs.contains(where: { $0.target.id == tid }) { return nil }
    return creation
  }

  /// Whether to draw a hairline on the leading edge of tab `index`. Every tab gets a leading divider
  /// (including the first — so all tabs are bracketed left and right, the right one being the next
  /// tab's leading hairline or the trailing "+" divider). The exception is a split group: it only
  /// divides **within** itself, so a hairline is dropped at the group's **outer** boundary — the first
  /// member's leading edge (index 0 member, or a member following a non-member or a DIFFERENT group's
  /// member) and, symmetrically, whatever follows a member. The `splitWell` brackets separate the groups
  /// there instead. Interior member↔member boundaries (same group) keep their hairline. Never mid-drag.
  private func showsLeadingSeparator(at index: Int, groupOf: [SidebarID: Int]) -> Bool {
    guard draggingID == nil else { return false }
    let here = tabs[index].sid
    // First tab: a leading divider unless it's the leading (outer) edge of a split group, or is itself
    // the selected/hovered pill (which stands alone).
    guard index > 0 else {
      return groupOf[here] == nil && here != selectedID && here != hoveredID
    }
    let prev = tabs[index - 1].sid
    // Drop the divider on both sides of the selected or hovered tab so its filled pill stands apart
    // from its neighbours (mirrors `TerminalTabStrip`).
    if here == selectedID || prev == selectedID { return false }
    if here == hoveredID || prev == hoveredID { return false }
    // A group boundary — including group A ↔ group B, where BOTH sides are members of *different*
    // groups and each has its own bracket.
    if groupOf[here] != groupOf[prev] { return false }
    return true
  }

  /// A rounded outline bracketing each workroom-split group's contiguous chip run, so the grouping is
  /// visible even while you're viewing a workroom outside it (groups persist). Mirrors
  /// `TerminalTabStrip.splitWell` — an outline, not a fill, so it doesn't compete with the active-chip
  /// fill. Hidden during a drag. One bracket per group: `displayedWorkroomTargets` keeps each group's
  /// members contiguous, so every group is one block.
  ///
  /// The `ZStack(alignment: .leading)` is load-bearing and NOT redundant with the caller's
  /// `.background(alignment: .leading)`: that alignment places the background *content as a whole*, and
  /// several `ForEach` brackets are wrapped in an implicit stack whose own alignment is the default
  /// `.center` — so every bracket narrower than the widest one was centred inside it and drawn
  /// `(widest − mine) / 2` too far right, while the widest one alone landed correctly. With one group
  /// (all this bar could hold before several groups per window) the sole bracket *was* the widest, so
  /// the fault was invisible until then. `TabStripSplitRun.rect` was right all along — each `run.x` is
  /// relative to the first chip's leading edge, which is what this stack restores as every bracket's
  /// origin.
  @ViewBuilder private func splitWell(groupOf: [SidebarID: Int]) -> some View {
    if draggingID == nil {
      ZStack(alignment: .leading) {
        ForEach(Array(splitRunRects(groupOf: groupOf).enumerated()), id: \.offset) { index, run in
          RoundedRectangle(cornerRadius: 7)
            .strokeBorder(ThemeService.shared.tokens.border, lineWidth: 1)
            .frame(width: run.width)
            .offset(x: run.x)
            // A frame XCUITest can read, so the misalignment above is testable at all — a stroked
            // shape is otherwise invisible to it, and the arithmetic was never the faulty half. Kept
            // OUT of the a11y tree in a normal run (`accessibilityHidden`): it's pure decoration, and
            // VoiceOver users get the grouping from each chip's own label. Same fixture-gated handle
            // idea as `PaneTreeView`'s single-pane `.isSelected`.
            .accessibilityElement()
            .accessibilityHidden(!UITestFixture.isActive)
            .accessibilityIdentifier("workroom.tab.splitBracket.\(index)")
        }
      }
    }
  }

  /// The x-offset and width of every split group's contiguous run within the chip row (x = 0 at the
  /// first chip), from the measured chip widths — empty when nothing is grouped. Maps this bar's model to
  /// position-indexed widths and delegates the arithmetic to the shared `TabStripSplitRun` (unit-tested
  /// there), exactly as `TerminalTabStrip.splitRunRect` does; a group with fewer than two chips in the
  /// bar yields no bracket.
  private func splitRunRects(groupOf: [SidebarID: Int]) -> [(x: CGFloat, width: CGFloat)] {
    guard !groupOf.isEmpty else { return [] }
    let chipWidths = tabs.map { widths[$0.sid] ?? 0 }
    // Bucket the chips by group in ONE pass over the bar (a filter per group would be O(groups × chips)).
    var byGroup: [Int: [Int]] = [:]
    for (index, tab) in tabs.enumerated() {
      guard let group = groupOf[tab.sid] else { continue }
      byGroup[group, default: []].append(index)
    }
    // Sorted by group index so the brackets keep a stable draw order across renders.
    return byGroup.keys.sorted().compactMap { group in
      TabStripSplitRun.rect(
        widths: chipWidths, memberIndices: byGroup[group] ?? [], spacing: tabSpacing)
    }
  }

  /// Clamp a reorder translation so the dragged chip stays within the tab run: its leading edge can't
  /// pass the run's leading end (x = 0, just right of the leading-controls divider) and its trailing
  /// edge can't pass the last chip's trailing end. `runWidth` is the chips' contiguous run (the trailing
  /// `+` button isn't a reorder slot). Keeps a dragged chip from being pulled into the leading controls
  /// or across the empty fill now that the bar spans the full title-bar width.
  private func clampReorder(_ translation: CGFloat, draggedIndex index: Int) -> CGFloat {
    guard let id = draggingID, let chipW = widths[id] else { return translation }
    let startX = (0..<index).reduce(CGFloat(0)) { $0 + (widths[tabs[$1].sid] ?? 0) + tabSpacing }
    let runWidth =
      tabs.reduce(CGFloat(0)) { $0 + (widths[$1.sid] ?? 0) }
      + tabSpacing * CGFloat(max(0, tabs.count - 1))
    let minT = -startX
    let maxT = max(minT, (runWidth - chipW) - startX)
    return min(max(translation, minT), maxT)
  }

  /// Commit the reorder on drop: rewrite `store.workroomTabOrder` (a `@Published`, so the parent view
  /// re-renders with the new order — a bare `Defaults` write didn't re-render, so the chip snapped
  /// back), then clear drag state (animated, so the row settles). The order is filtered through
  /// `orderedActiveTargets` on every read, so writing the current active order is self-healing.
  private func commitDrag() {
    guard let id = draggingID, let di = tabs.firstIndex(where: { $0.sid == id }) else {
      draggingID = nil
      dragTranslation = 0
      return
    }
    let ti = TabReorder.dropTargetIndex(
      widths: tabs.map { widths[$0.sid] ?? 0 }, draggedIndex: di,
      translation: dragTranslation, spacing: tabSpacing)
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
      if ti != di {
        var order = tabs.compactMap { AppStore.targetIDString(for: $0.sid) }
        let moved = order.remove(at: di)
        order.insert(moved, at: ti)
        store.workroomTabOrder = order
      }
      draggingID = nil
      dragTranslation = 0
    }
  }

  /// The "new workroom" (+) button — raises the New Workroom picker (`requestNewWorkroomPicker`, the
  /// same flag File ▸ New Workroom / ⌘N sets). Styled like the terminal strip's `addTerminalButton`:
  /// a hover-washed rounded glyph. Shown only alongside open tabs (the bar itself is hidden when
  /// nothing's open), so it's icon-only.
  private var addWorkroomButton: some View {
    Button {
      store.requestNewWorkroomPicker = true
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(ThemeService.shared.tokens.hover.opacity(addHovering ? 1 : 0))
        )
        // The whole padded glyph (the hover well's area) is clickable/hoverable, not just the "+" —
        // the transparent padding wouldn't hit-test on its own.
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { addHovering = $0 }
    .padding(.leading, 2)
    .help("New workroom (⌘N)")
    .accessibilityLabel("New workroom")
    .accessibilityIdentifier("NewWorkroom")
  }

  /// The "open workroom" button — raises the Open Workroom picker (`requestOpenWorkroomPicker`, the
  /// same flag File ▸ Open workroom… / ⌘O sets). Sits just left of the "+" and shares its exact
  /// size/style (a hover-washed rounded glyph).
  private var openWorkroomButton: some View {
    Button {
      store.requestOpenWorkroomPicker = true
    } label: {
      Image(systemName: "chevron.down")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(ThemeService.shared.tokens.hover.opacity(openHovering ? 1 : 0))
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { openHovering = $0 }
    .padding(.leading, 2)
    .help("Open workroom (⌘O)")
    .accessibilityLabel("Open workroom")
    .accessibilityIdentifier("OpenWorkroom")
  }
}

/// A single Workrooms View tab chip: a leading glyph, the project name, then run / unread / active
/// styling. A workroom chip leads with a cube glyph and trails its own name in secondary text; a root
/// chip leads with a house glyph (its branch is dropped from the chip; it lives in the inspector). The
/// title is capped so a long project or workroom name tail-truncates instead of stretching the chip
/// (mirrors `TerminalTabChip`); the tooltip carries the full title AND the path, so a truncated chip
/// still reveals its whole name and two same-named workrooms across projects stay distinct. Reads the
/// store for unread + run-command state; the bar wraps it with the gestures.
private struct WorkroomTabChip: View {
  let sid: SidebarID
  let target: TerminalTarget
  let isActive: Bool
  let isHovered: Bool
  let isDragging: Bool
  /// Draw a hairline on the leading edge, separating two adjacent idle tabs (computed by the bar).
  let showLeadingSeparator: Bool

  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @EnvironmentObject var terminals: TerminalSessions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let theme = ThemeService.shared

  /// The widest the title (project name + `/` + workroom name) renders before it tail-truncates.
  /// Beyond this the chip would keep stretching for a long workroom name; the ellipsis + `.help`
  /// tooltip carry the rest. Mirrors `TerminalTabChip.maxTitleWidth` (same 180pt).
  private static let maxTitleWidth: CGFloat = 180

  private var isRoot: Bool {
    if case .root = sid { return true }
    return false
  }

  /// The project name — the chip's primary label for every kind of target. A workroom's own name
  /// rides alongside as `workroomName` (secondary text); a root is marked by its house glyph.
  private var primaryLabel: String {
    switch sid {
    case .workroom(let project, _), .root(let project), .project(let project):
      return (project as NSString).lastPathComponent
    }
  }

  /// A workroom's own name (nil for a root/project) — rendered as trailing secondary text. Resolves
  /// to the display label when one is set (issue #41); this also feeds the "Close" prompt below, so
  /// that dialog shows the label too.
  private var workroomName: String? {
    if case .workroom(let project, let name) = sid {
      return store.displayName(forWorkroom: name, inProject: project)
    }
    return nil
  }

  /// A root's branch/bookmark (nil for a workroom), reusing the sidebar's root presentation.
  private var branchLabel: String? {
    guard case .root(let project) = sid else { return nil }
    return RootPresentation.make(store.rootRefs[project] ?? .unresolved).label
  }

  /// The full, untruncated rendered title — `primaryLabel`, plus `/` + `workroomName` for a workroom —
  /// exactly what the (possibly capped) title HStack shows. Feeds the tooltip so a tail-truncated chip
  /// still reveals its whole name on hover, mirroring `TerminalTabChip.help(tab.title)`.
  private var fullTitle: String {
    workroomName.map { "\(primaryLabel)/\($0)" } ?? primaryLabel
  }

  private var hasActivity: Bool { notifications.count(target: target.id) > 0 }
  private var hasRunTab: Bool { store.runTabID(for: target.id) != nil }
  private var runRunning: Bool { store.isRunCommandRunning(for: target.id) }

  // The chip is deliberately built in three stages — `contentRow` (the icons + title), `pill` (its
  // fills, outline and margin) and `body` (the tooltip, menu and a11y) — rather than one long
  // modifier chain: as a single expression it tipped Xcode 26.3's solver over the "unable to
  // type-check this expression in reasonable time" limit and broke CI.
  var body: some View {
    pill
      // The full, untruncated title (mirrors `TerminalTabChip.help(tab.title)`) plus the path on a
      // second line — genuinely useful on its own (two same-named workrooms across projects stay
      // distinct), and reads cleanly stacked under the title in a tooltip.
      .help("\(fullTitle)\n\(target.path)")
      // The workroom's right-click menu, shared with the split group title bar (issue #112). The tab
      // keeps "Close" (whole-workroom close), so `closeName` is non-nil: a root chip shows Close
      // only, a workroom chip shows the full set — same as before the extraction.
      .contextMenu {
        workroomContextMenu(
          store: store, sid: sid, target: target, closeName: workroomName ?? primaryLabel)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        accessibilityLabel(hasActivity: hasActivity, running: hasRunTab && runRunning)
      )
      .accessibilityIdentifier("workroom.tab.\(target.id)")
      .accessibilityAddTraits(isActive ? .isSelected : [])
      .scaleEffect(isDragging ? 1.04 : 1)
      .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: isDragging ? 6 : 0, y: 2)
  }

  /// The icons + title row: everything inside the pill's padding.
  private var contentRow: some View {
    // Icons stay vertically centered (center-aligned outer HStack); only the two texts share a
    // baseline, via the inner `.firstTextBaseline` group below.
    HStack(spacing: 6) {
      // Leading glyph: a house marks a project root, a cube an isolated workroom — set before the name.
      // Its tint carries the VCS dirty signal (orange) in place of a separate status dot.
      Image(systemName: isRoot ? "house" : "cube")
        .font(.system(size: 10))
        .foregroundStyle(VCSStatusPresentation.iconTint(store.workroomStatuses[sid] ?? .unresolved))
      if target.isMissing {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.orange)
          .help("Directory not found")
      }
      // The project name and (for a workroom) its own name, separated by a slash — one shared, smaller
      // size for all the chip text (`.subheadline`). On the focused tab the workroom name is full
      // strength (matches the project name) rather than the dimmer secondary it uses when unfocused.
      // Unread activity is marked by the accent colour on the project name alone (no dot here).
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(primaryLabel)
          .foregroundStyle(hasActivity ? theme.tokens.accent : Color.primary)
        if let workroomName {
          Text("/").foregroundStyle(.tertiary)
          Text(workroomName).foregroundStyle(isActive ? Color.primary : .secondary)
        }
      }
      .font(.subheadline)
      .lineLimit(1)
      .truncationMode(.tail)
      // Cap the title group as a whole rather than each `Text`, so the pair shares one budget
      // instead of each name getting its own. Note this does NOT make them truncate as a single
      // unit: an `HStack` satisfies its least-flexible children first, so the longer of the two
      // names absorbs the shortfall and both can end up clipped (`verylongproj…/verylongwo…`). That
      // is the intended trade — the alternative, a fixed per-`Text` cap, clips a short name beside a
      // long one for no reason. A short title stays tight (leading alignment, the HStack sizes to
      // its ideal width up to the cap).
      //
      // The cap matches `TerminalTabChip`'s, so a workroom chip is never wider than a terminal one;
      // it is shared by two names here against that chip's one, which is why a workroom chip starts
      // truncating at a shorter combined length.
      .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
      // VCS dirty status is carried by the leading house/cube tint above (no separate dot here).
      // Run-command dot (issue #7), trailing-most: green play while running; a red octagon if the
      // last run FAILED (#79 — distinct glyph, not just a red tint, for colourblind safety); hidden
      // once it has a run tab but is cleanly stopped.
      if hasRunTab {
        if runRunning {
          Image(systemName: "play.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(Color.green)
            .help("Run command running")
            .accessibilityLabel("run running")
        } else if store.runFailed(for: target.id) {
          Image(systemName: "xmark.octagon.fill")
            .font(.system(size: 10))
            .foregroundStyle(theme.tokens.failure)
            .help("Run command failed")
            .accessibilityLabel("run failed")
        }
      }
    }
  }

  /// The pill: `contentRow` plus its interior padding, fills, outline, running underline, outer
  /// margin and the width measurement the drag-reorder math reads.
  private var pill: some View {
    contentRow
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      // Selection & hover fill — the same treatment as the terminal tab chips: the selected tab is
      // filled with the terminal background (`bg`) so it stands distinct from the strip; a hovered idle
      // tab gets the faint hover wash. Front-most background so a dragged chip's material lift sits
      // behind it.
      .background {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(isActive ? theme.tokens.bg : (isHovered ? theme.tokens.hover : Color.clear))
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHovered)
      }
      // A solid lifted chip while dragging.
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(.thickMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(theme.tokens.border, lineWidth: 1)
          )
          .opacity(isDragging ? 1 : 0)
      }
      // Only the selected tab is outlined — a stronger `fgDim` stroke (not the `border` hairline) so it
      // reads as clearly selected. Mirrors the terminal tab chips.
      .overlay {
        if isActive {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(theme.tokens.fgDim, lineWidth: 1)
        }
      }
      // A flowing accent underline along the chip's base while any of this workroom's terminals is
      // working (OSC 9;4) — the same indeterminate-progress animation as the terminal tabs (issue #28).
      // An overlay so it never enters the width the drag gap math measures.
      .overlay(alignment: .bottom) {
        if terminals.isRunning(forTargetID: target.id) {
          RunningUnderline()
            .padding(.horizontal, 6)
            .padding(.bottom, 1)
        }
      }
      // The pill (fill + border) is the interactive shape; the margin added below stays dead gap space.
      .contentShape(Rectangle())
      // Outer margin OUTSIDE the pill/border — the space reclaimed from the interior padding, so the
      // pill floats with breathing room from its neighbours. Kept equal to the removed padding so the
      // chip's total footprint (and thus the drag-reorder pitch) is unchanged.
      .padding(.horizontal, 2)
      .padding(.vertical, 3)
      // Hairline between two idle neighbours, centred in the inter-chip gap. Anchored to the outer box
      // (after the margin) so it centres in the inter-chip spacing. An overlay so it never enters the
      // width the drag math measures.
      .overlay(alignment: .leading) {
        if showLeadingSeparator {
          Rectangle()
            .fill(theme.tokens.border)
            .frame(width: 1, height: 16)
            .offset(x: -2)
        }
      }
      // Measure the chip's full footprint (pill + margin) for the drag gap math — pairs with the
      // inter-chip spacing to set the reorder pitch.
      .background {
        GeometryReader { geo in
          Color.clear.preference(key: WorkroomTabWidthKey.self, value: [sid: geo.size.width])
        }
      }
  }

  private func accessibilityLabel(hasActivity: Bool, running: Bool) -> String {
    var parts = [workroomName.map { "\(primaryLabel), workroom \($0)" } ?? primaryLabel]
    if let branchLabel { parts.append("on \(branchLabel)") }
    let vcs = VCSStatusPresentation.accessibilityLabel(store.workroomStatuses[sid] ?? .unresolved)
    if !vcs.isEmpty { parts.append(vcs) }
    if target.isMissing { parts.append("directory not found") }
    if running { parts.append("running") }
    if hasActivity { parts.append("unread activity") }
    return parts.joined(separator: ", ")
  }
}

/// The provisional "Creating…" chip shown while a workroom is being created and its real named chip
/// hasn't resolved yet (issue #116). Mirrors `WorkroomTabChip`'s layout — a leading cube glyph, the
/// project name, then a small spinner in place of the (not-yet-known) workroom name — with the same
/// selected/hover fill. Tapping it refocuses the creating slot; it takes no part in drag/reorder
/// or width measurement, so it never enters the tab-reorder math.
private struct ProvisionalWorkroomChip: View {
  let project: Project
  var isActive: Bool
  var onSelect: () -> Void
  @State private var hovered = false
  private let theme = ThemeService.shared

  private var projectName: String { (project.path as NSString).lastPathComponent }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "cube")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(projectName).foregroundStyle(.secondary)
        Text("/").foregroundStyle(.tertiary)
      }
      .font(.subheadline)
      .lineLimit(1)
      ProgressView().controlSize(.small).scaleEffect(0.7)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    // The same fill + outline the real chips use for the selected/hover state — so the creating slot
    // reads as the active tab while its loader/dialog owns the detail.
    .background {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isActive ? theme.tokens.bg : (hovered ? theme.tokens.hover : Color.clear))
    }
    .overlay {
      if isActive {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(theme.tokens.fgDim, lineWidth: 1)
      }
    }
    .contentShape(Rectangle())
    // Outer margin outside the pill — matches the real chips so the creating slot lines up with them.
    .padding(.horizontal, 2)
    .padding(.vertical, 3)
    .onHover { hovered = $0 }
    .onTapGesture(perform: onSelect)
    .help("Creating workroom in \(projectName)…")
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Creating workroom in \(projectName)")
    .accessibilityIdentifier("workroom.tab.creating")
    .transition(.opacity)
  }
}

/// Collects each Workrooms tab chip's natural width for the drag gap math (issue #23).
private struct WorkroomTabWidthKey: PreferenceKey {
  static var defaultValue: [SidebarID: CGFloat] = [:]
  static func reduce(value: inout [SidebarID: CGFloat], nextValue: () -> [SidebarID: CGFloat]) {
    value.merge(nextValue()) { _, new in new }
  }
}
