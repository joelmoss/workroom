import SwiftUI

/// The workroom tab bar shown in the title bar (issue #23): a chip per active target (a workroom or
/// project root with ≥1 terminal), drag-to-reorder (reusing the shared `TabReorder` math). A tab
/// appears when its workroom gains a terminal and disappears when it loses its last. The "selected"
/// chip **is** `store.selectedTargetID` — tapping one selects that target (like the sidebar), so every
/// selection-driven command (⌘T/⌘W/splits/run/notifications/⌥⌘1–9) operates on the focused workroom.
/// No per-chip close button: a tab vanishes when its terminals are closed, and closing-as-kill would
/// defeat the parallel-monitoring purpose.
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

    ScrollView(.horizontal, showsIndicators: false) {
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
            showLeadingSeparator: showsLeadingSeparator(at: index)
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
            isDragging || reduceMotion ? nil : .easeInOut(duration: 0.18), value: offsetX)
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
        // A divider sets the "new workroom" (+) button apart from the last tab. Hidden when the last
        // tab is selected or hovered (its filled pill stands apart, mirroring the inter-chip dividers)
        // or is in a split group (the `splitWell` bracket already frames it, so a divider would double
        // against its rounded edge). Toggled via OPACITY (not removed) so the "+" never shifts. Negative
        // leading trims the gap to the last tab to ~2pt (HStack `tabSpacing` 4 − 2), matching the
        // inter-chip dividers.
        Rectangle()
          .fill(ThemeService.shared.tokens.border)
          .frame(width: 1, height: 16)
          .padding(.leading, -2)
          .padding(.trailing, 4)
          .opacity(
            tabs.last.map {
              !splitMemberSet.contains($0.sid) && $0.sid != selectedID && $0.sid != hoveredID
            } ?? true ? 1 : 0)
        // Open-workroom + new-workroom buttons, immediately after the last chip (scroll with them).
        // Open sits to the left of the "+" and shares its exact size/style.
        openWorkroomButton
        addWorkroomButton
      }
      .background(alignment: .leading) { splitWell }
      .padding(.horizontal, 8)
      .onPreferenceChange(WorkroomTabWidthKey.self) { widths = $0 }
    }
    // The bar fills the gap between the leading and trailing title-bar controls
    // (`frame(maxWidth: .infinity)`), chips left-aligned; it scrolls horizontally when the chips
    // overflow that gap — the chips are never resized (issue #23). `fixedSize` (vertical) hugs the chip
    // height so the parent title-bar HStack centres the bar on the traffic-light line.
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    // Disable AppKit's title-bar window drag only while the cursor is over (or dragging) a chip, so a
    // chip drag reorders instead of moving the window — the empty bar still drags it. See
    // `WindowMovableController`.
    .background(WindowMovableController(movable: draggingID == nil && hoveredID == nil))
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
  /// member's leading edge (index 0 member, or a member following a non-member) and, symmetrically, a
  /// non-member following a member. The `splitWell` bracket separates the group there instead. Interior
  /// member↔member boundaries keep their hairline. Never mid-drag.
  private func showsLeadingSeparator(at index: Int) -> Bool {
    guard draggingID == nil else { return false }
    let members = splitMemberSet
    let here = tabs[index].sid
    // First tab: a leading divider unless it's the leading (outer) edge of a split group, or is itself
    // the selected/hovered pill (which stands alone).
    guard index > 0 else {
      return !members.contains(here) && here != selectedID && here != hoveredID
    }
    let prev = tabs[index - 1].sid
    // Drop the divider on both sides of the selected or hovered tab so its filled pill stands apart
    // from its neighbours (mirrors `TerminalTabStrip`).
    if here == selectedID || prev == selectedID { return false }
    if here == hoveredID || prev == hoveredID { return false }
    if members.contains(here) != members.contains(prev) { return false }
    return true
  }

  /// The split group's members (≥2), or empty when there's no split — used to drop the separator at
  /// the group's outer edges (see `showsLeadingSeparator`).
  private var splitMemberSet: Set<SidebarID> {
    guard let members = store.workroomSplit?.tabIDs, members.count >= 2 else { return [] }
    return Set(members)
  }

  /// A rounded outline bracketing the workroom-split members' contiguous run, so the grouping is
  /// visible even while you're viewing a non-member workroom (the split persists). Mirrors
  /// `TerminalTabStrip.splitWell` — an outline, not a fill, so it doesn't compete with the active-chip
  /// fill. Hidden during a drag; only for a real split (`displayedWorkroomTargets` keeps members
  /// contiguous, so the run is one block).
  @ViewBuilder private var splitWell: some View {
    if draggingID == nil, let run = splitRunRect() {
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(ThemeService.shared.tokens.border, lineWidth: 1)
        .frame(width: run.width)
        .offset(x: run.x)
    }
  }

  /// The x-offset and width of the split members' contiguous run within the chip row (x = 0 at the
  /// first chip), from the measured chip widths — or nil when there's no split. Mirrors
  /// `TerminalTabStrip.splitRunRect`.
  private func splitRunRect() -> (x: CGFloat, width: CGFloat)? {
    guard let members = store.workroomSplit?.tabIDs, members.count >= 2 else { return nil }
    let memberSet = Set(members)
    let idxs = tabs.indices.filter { memberSet.contains(tabs[$0].sid) }
    guard let first = idxs.first, let last = idxs.last else { return nil }
    var x: CGFloat = 0
    for i in 0..<first { x += (widths[tabs[i].sid] ?? 0) + tabSpacing }
    var width: CGFloat = 0
    for i in first...last { width += widths[tabs[i].sid] ?? 0 }
    width += tabSpacing * CGFloat(last - first)
    return (x, width)
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
/// full path is the tooltip, so two same-named workrooms across projects stay distinct. Reads the
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

  var body: some View {
    let hasActivity = notifications.count(target: target.id) > 0
    let hasRunTab = store.runTabID(for: target.id) != nil
    let runRunning = store.isRunCommandRunning(for: target.id)
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
    .help(target.path)
    // The workroom's right-click menu, shared with the split group title bar (issue #112). The tab
    // keeps "Close" (whole-workroom close), so `closeName` is non-nil: a root chip shows Close only,
    // a workroom chip shows the full set — same as before the extraction.
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
