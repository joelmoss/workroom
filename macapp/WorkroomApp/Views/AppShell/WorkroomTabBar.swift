import AppKit
import Defaults
import DesignSystem
import SwiftUI
import WorkroomDomain

extension Transaction {
  /// Set on the update that shows or hides the title-bar tabs (`showTitleBarTabs`), so the tab
  /// run keeps that update's fade instead of its own unanimated default for tabs coming and going.
  @Entry var togglesTitleBarTabs = false
}

/// The workroom tab bar shown in the title bar (issue #23): a chip per active target (a workroom or
/// project root with ≥1 terminal), drag-to-reorder (reusing the shared `TabReorder` math). A tab
/// appears when its workroom gains a terminal and disappears when it loses its last. The "selected"
/// chip **is** `store.selectedTargetID` — tapping one selects that target (like the sidebar), so every
/// selection-driven command (⌘T/⌘W/splits/run/notifications/⌥⌘1–9) operates on the focused workroom.
/// A tab vanishes when its terminals are closed. Its ✕ shows only while the pointer is over it, laid
/// over its title (`tabHoverClose`), and asks first, as the right-click menu's Close does; at rest the
/// tabs carry no close control, so a row of them reads as places to monitor rather than to close.
///
/// The bar is mounted whether or not there are any tabs: its trailing controls are how a fresh window
/// opens its first workroom, so an empty run still shows them (over the otherwise bare, draggable
/// title bar).
///
/// The trailing controls (open-workroom + "+") are **adaptive** (issue #129), mirroring
/// `TerminalTabStrip`: they sit inline hugging the last chip while everything fits, and pin at the
/// bar's trailing edge once the chips overflow, so the "+" is never scrolled out of reach. They move as
/// one block — they share a size/style and ⌘O/⌘N, and a chevron left behind in the scroller would be
/// the first thing to scroll away. The decision is the shared `TabStripOverflow.pinsControls`, and the
/// scaffolding around it is the shared `OverflowingTabScroller` (so the two strips can't drift).
struct WorkroomTabBar: View {
  /// Everything open in the window, in order; `tabs` is what the bar shows of it.
  let openTabs: [(sid: SidebarID, target: TerminalTarget)]
  /// The tabs on show: all of them, or none with "Show tabs in the title bar" off. With none, the
  /// bar is a window's with no tabs: the buttons sit where it has them, and with no tabs laid out
  /// nothing can be dropped on one. Selection and the workroom-tab shortcuts read the store, not the
  /// bar, so they still work.
  private var tabs: [(sid: SidebarID, target: TerminalTarget)] { showsTabs ? openTabs : [] }
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
  let dropTarget: (CGPoint) -> (sid: SidebarID, edge: PaneEdge, rect: CGRect)?

  @EnvironmentObject var store: AppStore
  @EnvironmentObject var projectStore: ProjectStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.themeTokens) private var tokens

  /// `Defaults[.showTitleBarTabs]`, changed only inside the fade below (`followsShowTitleBarTabs`).
  /// Held here, not passed in: this bar is its own SwiftUI root in the title bar
  /// (`TitlebarAccessoryHost` sets its root view afresh on each update), so an animation begun
  /// outside it never reaches the tabs. And not read through `@Default`, which reads the stored value
  /// live, so whatever re-renders the bar first after a change (a right-click menu closing) would
  /// show it unanimated.
  @State private var showsTabs = Defaults[.showTitleBarTabs]
  /// The fade's animation, for a moment after the tabs show or hide: hiding an overflowing bar's tabs
  /// (or showing them again) moves the controls between pinned and inline, and they slide with it.
  @State private var controlsFlipAnimation: Animation?
  /// Which show or hide set `controlsFlipAnimation`, so only the latest one clears it.
  @State private var controlsFlipGeneration = 0
  @State private var hoveredID: SidebarID?
  @State private var addHovering = false
  @State private var openHovering = false

  // Drag-to-reorder: the order is frozen during a drag (the dragged chip follows the cursor, the rest
  // slide aside to open a gap), committed once on drop — mirrors `TerminalTabStrip`.
  @State private var drag = TabReorderDrag<SidebarID>()
  /// Whether the dragged tab is over somewhere it would drop its terminals (#652, the window's
  /// `terminalDrag`): another tab's middle, a sidebar row, a pane tab or a group's title bar. The
  /// reorder gap closes so the destination stays under the pointer.
  @State private var overTerminalDrop = false
  /// Where a dragged standalone terminal's or group's tab would land, from the pointer against the
  /// tabs as they were when the drag started (#652). Nil for a workroom's tab, which no tab takes
  /// a drop of: that reorders by its translation, as the terminal strip does.
  @State private var pointerReorder: PointerReorder?
  /// The tab just let go on another, whose drop (`AppStore.dropTerminals`) lands a moment later:
  /// till then it stays hidden where it was let go and the rest stay put, so nothing slides back
  /// to where it started only to move again once the tabs change.
  @State private var landing: SidebarID?
  /// The tab just let go, while the bar waits for the tabs to change (`settle`): the row stays as
  /// it was let go, gap and all, so the change slides in from there and nothing jumps back first.
  /// The tabs come from the store a pass after the drop, not in the drop's own update.
  @State private var settling: SidebarID?
  /// Where the tab let go is landing (`settling`), which holds the gap open while the tabs change.
  @State private var settleIndex: Int?
  /// Where the dragged tab's slot began when its drag started, along the row. The tab is drawn at
  /// its translation less how far its slot has moved since, so when the new order puts it in its
  /// new slot it stays exactly where it was let go, in the same pass, and then settles.
  @State private var dragOriginX: CGFloat?

  private let tabSpacing: CGFloat = 4
  /// The tab row's coordinate space, which the tabs' frames are measured in.
  static let runSpace = "workroomTabRun"

  /// Whether the hairline before the trailing controls shows (`TabStripSeparators.atEdge`, the
  /// terminal strip's rule too). Hidden when the last tab stands apart on its own (selected or
  /// hovered — its filled pill already separates it), when it's in a split group (the split bracket
  /// frames it, so a divider would double against its rounded edge), and once the controls have
  /// pinned (issue #129): the fade and gutter already separate the regions. Hidden too when the run
  /// is empty — the bar is mounted with no tabs at all (a fresh window), and a hairline with nothing
  /// to its left is a divider between nothing and the buttons.
  private func showsTrailingDivider(overflowing: Bool, groupOf: [SidebarID: Int]) -> Bool {
    guard !overflowing else { return false }
    return TabStripSeparators.atEdge(
      of: tabs.last?.sid, active: selectedID, hovered: hoveredID, groupOf: groupOf)
  }

  var body: some View {
    let draggedIndex = drag.id.flatMap { id in tabs.firstIndex { $0.sid == id } }
    // While dragging a chip down into the content (forming a split), the strip stops opening a reorder
    // gap — mirrors `TerminalTabStrip`.
    // A tab dragged over another it would drop on keeps the gap where it is: each tab moves once,
    // and stays put while it is the one under the pointer (`TabReorder.dropTargetIndex(spans:…)`).
    let dropIndex =
      settleIndex
      ?? pointerReorder.map { reorder in
        chipPaneDrag != nil || (overTerminalDrop && !reorder.inRow) ? nil : reorder.index
      }
      ?? drag.dropIndex(
        ids: tabs.map(\.sid), spacing: tabSpacing,
        suspendedByPaneDrag: chipPaneDrag != nil || overTerminalDrop)
    let draggedWidth = drag.draggedWidth

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
      // No target while the tabs are hidden, so showing them again is a new one: the scroller then
      // reveals the selected tab once the returning tabs are laid out, as it does a new tab's.
      scrollTarget: showsTabs ? selectedID : nil, scrollSuspended: drag.isDragging,
      flipAnimation: controlsFlipAnimation
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
    .background(WindowMovableController(movable: !drag.isDragging && hoveredID == nil))
    .task { await followsShowTitleBarTabs() }
    // Right-click anywhere else in the title bar for "Show Tabs".
    .background(
      TitlebarContextMenu(isOverTab: { [store] screenPoint in
        guard let point = store.workroomTabRowPoint(screenPoint) else { return false }
        return store.workroomTabFrames.values.contains { $0.contains(point) }
      }))
  }

  /// Shows or hides the tabs as "Show tabs in the title bar" changes, from Settings or a right-click
  /// menu: they fade as they go or come and the buttons slide with them, at once under Reduce Motion.
  private func followsShowTitleBarTabs() async {
    for await shown in Defaults.updates(.showTitleBarTabs) where shown != showsTabs {
      let animation: Animation? =
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ? nil : .easeInOut(duration: 0.2)
      controlsFlipAnimation = animation
      controlsFlipGeneration += 1
      let generation = controlsFlipGeneration
      var transaction = Transaction(animation: animation)
      transaction.togglesTitleBarTabs = true
      withTransaction(transaction) { showsTabs = shown }
      // Long enough for the overflow flip, which lands a layout pass after this change.
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(400))
        if controlsFlipGeneration == generation { controlsFlipAnimation = nil }
      }
    }
  }

  /// The open-workroom + new-workroom buttons as ONE block, rendered inline as the last element of the
  /// scrolling row while everything fits, or pinned at the bar's trailing edge once the chips overflow
  /// (issue #129). Both move together: they share a size/style (see `openWorkroomButton`) and ⌘O/⌘N, and
  /// a chevron left behind in the scroller would sit under the fade as the first thing to scroll away.
  ///
  /// `fixedSize` so the block keeps its intrinsic width and the scrolling chip area yields first in a
  /// cramped window — the same reason `PaneTitleBar`'s trailing controls are fixed-size (that bar
  /// inherited the role when issue #150 emptied the terminal strip's toolbar). `OverflowingTabScroller`
  /// measures this width and feeds it to the overflow predicate; the internal spacing is identical in
  /// both positions, so that one number is valid either way, which is what keeps the predicate
  /// branch-independent.
  private var trailingControls: some View {
    HStack(spacing: tabSpacing) {
      // No projects: nothing to create a workroom in (⌘N is off too); nothing at all: nothing to open.
      // A terminal with no project is still something to open (#662), so the open button stays.
      if store.sidebarHasContent { openWorkroomButton }
      if !projectStore.projects.isEmpty { addWorkroomButton }
    }
    .fixedSize()
  }

  /// The chips themselves, the provisional "Creating…" chip, and the hairline that sets the trailing
  /// controls apart — everything that scrolls, and everything that stays put across an overflow flip.
  /// Measured as one run for the overflow predicate — which covers the provisional chip and the trailing
  /// hairline too, since both live in this measured row (so neither needs its own bookkeeping; notably
  /// the provisional chip is deliberately absent from `WorkroomTabWidthKey`). The split bracket is drawn
  /// behind it (leading-aligned, so x = 0 is the first chip's leading edge, which is what
  /// `TabStripSplitRun.rects` computes against).
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
        let isDragging = drag.id == tab.sid
        let isHovered = hoveredID == tab.sid && !drag.isDragging
        let offsetX =
          isDragging
          ? drag.translation - (dragOriginX.map { slotX(at: index) - $0 } ?? 0)
          : TabReorder.gapShift(
            index: index, draggedIndex: draggedIndex, target: dropIndex,
            amount: draggedWidth + tabSpacing) + incomingShift(at: index)
        WorkroomTabChip(
          sid: tab.sid, target: tab.target, isActive: tab.sid == selectedID,
          isHovered: isHovered, isDragging: isDragging,
          showLeadingSeparator: showsLeadingSeparator(at: index, groupOf: groupOf)
        )
        // Over a tab it would group with, the dragged tab lets the target's accent show through.
        .opacity(isDragging && landing == tab.sid ? 0 : isDragging && overTerminalDrop ? 0.55 : 1)
        // A Quick Terminal pane dragged over this window would join this workroom.
        .overlay {
          if store.incomingQuickTerminalPane == tab.sid
            || store.incomingPaneDrop == .target(tab.sid)
          {
            DropAccent(cornerRadius: Radius.s)
          }
        }
        // A pane let go in the empty space beside this tab becomes a standalone terminal there:
        // the caret marks the gap (#652).
        .overlay(alignment: gapCaretEdge(of: tab.sid, at: index) ?? .leading) {
          if gapCaretEdge(of: tab.sid, at: index) != nil {
            DropInsertionMark(vertical: true).offset(
              x: gapCaretEdge(of: tab.sid, at: index) == .leading
                ? -tabSpacing / 2 - 1 : tabSpacing / 2 + 1)
          }
        }
        .onHover { inside in
          if inside { hoveredID = tab.sid } else if hoveredID == tab.sid { hoveredID = nil }
        }
        .onTapGesture { onSelect(tab.sid) }
        // Measure in .global space (a .local drag reads coordinates relative to the chip, which
        // itself moves via .offset — that feedback loop lags the cursor). Mirrors TerminalTabStrip.
        .gesture(
          DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
              // Clamp the reorder so the dragged chip stops at the leading and trailing ends of the
              // tab run — it can't be pulled left into the leading controls or right across the empty
              // fill (the bar spans the full title-bar width). Vertical drag-into-a-split is
              // unaffected (that reads `value.location`, below).
              if drag.id == nil { dragOriginX = slotX(at: index) }
              drag.update(
                tab.sid,
                translation: clampReorder(value.translation.width, draggedIndex: index))
              // Out of the window: onto the Quick Terminal panel's tabs (#652), else into another
              // window, or a new one (#444).
              if isDragOutsideWindow(value.location) {
                chipPaneDrag = nil
                pointerReorder = nil
                overTerminalDrop = store.terminalDrag.moved(
                  .entry(tab.sid), from: .titleBar, to: NSEvent.mouseLocation)
                if overTerminalDrop { return WorkroomWindowDrag.cancel() }
                WorkroomWindowDrag.update(
                  store: store, sid: tab.sid, target: tab.target,
                  width: drag.widths[tab.sid] ?? 0)
                return
              }
              WorkroomWindowDrag.cancel()
              // A standalone terminal's or group's tab over another tab's middle, a sidebar row, a
              // pane tab or a group's title bar: a drop there takes its terminals (#652).
              overTerminalDrop = store.terminalDrag.moved(
                .entry(tab.sid), from: .titleBar, to: NSEvent.mouseLocation)
              pointerReorder = pointerReorder(draggedIndex: index, at: NSEvent.mouseLocation)
              // Dragged into the detail content → preview a drop-into-pane split (the strip stops
              // gapping); otherwise it's a plain reorder.
              chipPaneDrag =
                overTerminalDrop
                ? nil
                : localize(value.location).map { WorkroomPaneDrag(sid: tab.sid, location: $0) }
            }
            .onEnded { value in
              // Worked out before the session ends, while it still has the tabs it measured.
              let reorder = pointerReorder(draggedIndex: index, at: NSEvent.mouseLocation)
              // Out of the window, only the Quick Terminal panel's tabs take it.
              let outcome = store.terminalDrag.ended(at: NSEvent.mouseLocation)
              endTerminalDrag()
              if outcome == .landedInOpenList {
                // Let go in the Open Tabs view's gap (#819), it lands there: the tab stays in its slot
                // till the new order comes.
                settleIndex = index
                settle(tab.sid, hidden: false)
              } else if outcome == .dropped {
                // The gap stays where it was as the tab goes.
                settleIndex = reorder?.index ?? index
                settle(tab.sid, hidden: true)
              } else if isDragOutsideWindow(value.location) {
                drag.cancel()
                WorkroomWindowDrag.end(store: store, sid: tab.sid)
              } else if let drop = dropTarget(value.location) {
                store.insertWorkroomSplit(
                  tab.sid, beside: drop.sid, edge: drop.edge, destinationRect: drop.rect)
                drag.cancel()
              } else {
                // Recompute the clamp from `value.translation` rather than reading `drag.translation`:
                // that field is only ever written from `onChanged`, and a coarse/fast synthetic drag
                // (XCUITest's interpolation, or a fast real trackpad flick) can deliver its last
                // `onChanged` sample short of the true release point, before `onEnded` fires with the
                // full, accurate displacement — committing off a stale, under-shot translation.
                if let reorder {
                  commitDrag(at: reorder.index)
                } else {
                  commitDrag(
                    translation: clampReorder(value.translation.width, draggedIndex: index))
                }
              }
              chipPaneDrag = nil
            }
        )
        .offset(x: offsetX)
        .zIndex(isDragging ? 1 : 0)
        .animation(
          // Not while a reorder settles: the tabs reach their new slots in one pass with their
          // offsets cleared to match, so animating either alone would fling them out and back.
          isDragging || reduceMotion || (settling != nil && landing == nil)
            ? nil : .easeInOut(duration: 0.18), value: offsetX
        )
        // Scroll target for `OverflowingTabScroller`'s `ScrollViewReader` (issue #129 follow-up) — the
        // same id `ForEach` already keys identity on.
        .id(tab.sid)
      }
      // The HStack's own spacing before it makes up the rest of the gap.
      if let incomingRoom { Color.clear.frame(width: incomingRoom, height: 1) }
      // A divider sets the trailing controls apart from the last tab — see `showsTrailingDivider` for
      // when it hides. Toggled via OPACITY (not removed) so the controls never shift as hover and
      // selection come and go, which also keeps the measured run width stable across those
      // transitions. Negative leading trims the gap to the last tab to ~2pt (HStack `tabSpacing` 4 − 2),
      // matching the inter-chip dividers.
      Rectangle()
        .fill(tokens.border)
        .frame(width: 1, height: 16)
        .padding(.leading, -2)
        .padding(.trailing, 4)
        .opacity(showsTrailingDivider(overflowing: overflowing, groupOf: groupOf) ? 1 : 0)
    }
    .background(alignment: .leading) {
      // One bracket per group: `displayedWorkroomTargets` keeps each group's members contiguous, so
      // every group is one block. Hidden during a drag, and skipped when nothing is grouped.
      if !drag.isDragging, !groupOf.isEmpty {
        TabStripSplitBrackets(
          ids: tabs.map(\.sid), width: { drag.widths[$0] ?? 0 }, groupOf: groupOf,
          spacing: tabSpacing, identifierPrefix: "workroom.tab.splitBracket")
      }
    }
    // The row's own space and its view, so a drop from another window maps a screen point onto
    // these tabs (#444).
    .coordinateSpace(.named(Self.runSpace))
    .background { ViewAnchor { [store] in store.workroomTabRun = $0 } }
    .onPreferenceChange(WorkroomTabWidthKey.self) { drag.setWidths($0) }
    .onPreferenceChange(WorkroomTabFrameKey.self) { store.workroomTabFrames = $0 }
    // A tab let go on another goes: the rest slide up to close its place, offsets and all. Any other
    // change to the tabs is unanimated, except showing or hiding them all, whose fade
    // `followsShowTitleBarTabs` sets.
    .transaction(value: tabs.map(\.sid)) { transaction in
      guard !transaction.togglesTitleBarTabs else { return }
      transaction.animation =
        landing == nil || reduceMotion ? nil : .easeInOut(duration: 0.18)
    }
    .onChange(of: tabs.map(\.sid)) { _, ids in
      if settling != nil { finishSettling() }
      // A tab that goes from under the pointer (hidden from its own right-click menu) gets no
      // hover exit, and a stale hover would keep the window from dragging by its title bar.
      if let hoveredID, !ids.contains(hoveredID) { self.hoveredID = nil }
    }
  }

  /// Tab `sid` was let go: holds the bar as it is till the tabs change (`settling`), or, should
  /// they change none, a moment. `hidden`: it was let go on something that takes it, so it goes.
  private func settle(_ sid: SidebarID, hidden: Bool) {
    settling = sid
    if hidden { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { landing = sid } }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(600))
      if settling == sid { finishSettling() }
    }
  }

  private func finishSettling() {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
      drag.cancel()
      settling = nil
      settleIndex = nil
      landing = nil
    }
  }

  /// How far along the row tab `index`'s slot starts: the tabs before it and their spacing.
  private func slotX(at index: Int) -> CGFloat {
    tabs[..<index].reduce(0) { $0 + (drag.widths[$1.sid] ?? 0) + tabSpacing }
  }

  /// How far a tab moves aside for a workroom dragged in from another window (#444): every tab at or
  /// after the slot it would land in.
  private func incomingShift(at index: Int) -> CGFloat {
    guard let incoming = store.incomingWorkroomDrop, let slot = incoming.slot, index >= slot
    else { return 0 }
    return incoming.width + tabSpacing
  }

  /// The room a workroom dragged in from another window needs at the end of the run (#444): the
  /// tabs after its slot slide into it, so they never ride over the trailing controls. Nil while
  /// nothing hovers, when the run's layout is exactly as without this.
  private var incomingRoom: CGFloat? {
    store.incomingWorkroomDrop.map(\.width)
  }

  /// Whether to draw a hairline on the leading edge of tab `index`. Every tab gets a leading divider
  /// (including the first — so all tabs are bracketed left and right, the right one being the next
  /// tab's leading hairline or the trailing "+" divider); the terminal strip draws none before its
  /// first tab, and that difference is this bar's own. The rules are `TabStripSeparators`': none
  /// beside the selected or hovered pill, and none at a split group's **outer** boundary — the first
  /// member's leading edge (index 0 member, or a member following a non-member or a DIFFERENT group's
  /// member) and, symmetrically, whatever follows a member, where the brackets separate the groups
  /// instead. Interior member↔member boundaries (same group) keep their hairline. Never mid-drag.
  private func showsLeadingSeparator(at index: Int, groupOf: [SidebarID: Int]) -> Bool {
    guard !drag.isDragging else { return false }
    guard index > 0 else {
      return TabStripSeparators.atEdge(
        of: tabs[index].sid, active: selectedID, hovered: hoveredID, groupOf: groupOf)
    }
    return TabStripSeparators.between(
      tabs[index - 1].sid, tabs[index].sid, active: selectedID, hovered: hoveredID,
      groupOf: groupOf)
  }

  /// Which edge of tab `sid` (at `index`) the title bar's caret sits on while a pane hovers in the
  /// empty space there (`PaneDropZone.titleBarGap`): the leading edge of the tab it would land
  /// before, or the trailing edge of the last tab. Nil: no caret on this tab.
  private func gapCaretEdge(of sid: SidebarID, at index: Int) -> Alignment? {
    guard case .titleBarGap(let before) = store.incomingPaneDrop else { return nil }
    if before == sid { return .leading }
    if before == nil, index == tabs.count - 1 { return .trailing }
    return nil
  }

  /// Ends this bar's part in the window's terminal drag, and its highlight.
  private func endTerminalDrag() {
    overTerminalDrop = false
    pointerReorder = nil
    store.terminalDrag.cancel()
  }

  /// A reorder translation kept within the tab run (`TabReorderDrag.clamped`): the bar spans the
  /// full title-bar width, so the chip would otherwise cross the empty fill.
  private func clampReorder(_ translation: CGFloat, draggedIndex index: Int) -> CGFloat {
    drag.clamped(translation, ids: tabs.map(\.sid), index: index, spacing: tabSpacing)
  }

  /// Commit the reorder on drop: rewrite `store.workroomTabOrder` (a `@Published`, so the parent view
  /// re-renders with the new order — a bare `Defaults` write didn't re-render, so the chip snapped
  /// back). The order is filtered through `orderedActiveTargets` on every read, so writing the
  /// current active order is self-healing. `translation` is the caller's own final, clamped
  /// displacement (from `onEnded`'s `value`), never the live `drag.translation`, which a fast drag's
  /// last `onChanged` can leave short.
  private func commitDrag(translation: CGFloat) {
    guard let id = drag.id, let from = tabs.firstIndex(where: { $0.sid == id }) else {
      return drag.cancel()
    }
    commitDrag(
      at: TabReorder.dropTargetIndex(
        widths: tabs.map { drag.widths[$0.sid] ?? 0 }, draggedIndex: from,
        translation: translation, spacing: tabSpacing))
  }

  /// Commit the reorder to drop index `target`. The drag isn't cleared here but once the new order
  /// reaches the bar (`settle`): the tabs arrive a pass later, and clearing it now slid the dropped
  /// tab back toward where it started, then flung it to its new place when they came (#652).
  private func commitDrag(at target: Int) {
    guard let id = drag.id, let from = tabs.firstIndex(where: { $0.sid == id }),
      tabs.indices.contains(target), target != from
    else {
      return withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { drag.cancel() }
    }
    settleIndex = target
    settle(id, hidden: false)
    store.moveWorkroomTab(id, toIndex: target)
  }

  /// Where the tab at `index` would land with the pointer at `point`, when some tab takes its drop.
  struct PointerReorder: Equatable {
    let index: Int
    /// The pointer is in the tabs' row, where the gap stays open.
    let inRow: Bool
  }

  private func pointerReorder(draggedIndex index: Int, at point: CGPoint) -> PointerReorder? {
    let measured = store.terminalDrag.titleBarTabs()
    let spans = tabs.compactMap { measured[$0.sid] }
    guard spans.count == tabs.count, spans.contains(where: \.takes) else { return nil }
    let target = TabReorder.dropTargetIndex(
      spans: spans.map { $0.rect.minX...$0.rect.maxX }, draggedIndex: index, pointerX: point.x,
      joinable: spans.map(\.takes), band: TerminalDragSession.titleBarBandInset)
    let row = spans.map(\.rect).reduce(spans[0].rect) { $0.union($1) }
    return PointerReorder(index: target, inRow: (row.minY...row.maxY).contains(point.y))
  }

  /// The glyph box inside each trailing button's hover well. **Fixed**, not the symbol's intrinsic
  /// size: "chevron.down" is wide and short where "plus" is square, so sizing each well off its own
  /// glyph gave the two side-by-side buttons visibly different wells and different hit areas (the
  /// chevron's was several points shorter). Both glyphs fit inside 13pt at `.system(size: 11)`.
  private static let glyphBox: CGFloat = 13

  /// The "new workroom" (+) button — raises the New Workroom picker (`requestNewWorkroomPicker`, the
  /// same flag File ▸ New Workroom / ⌘N sets). Styled like the terminal strip's `addTerminalButton`:
  /// a hover-washed rounded glyph. Icon-only, and present even with no tabs open — it and ⌘O are the
  /// mouse route to a first workroom in a fresh window.
  private var addWorkroomButton: some View {
    glyphButton(
      "plus", hovering: addHovering,
      help: "New workroom" + Shortcuts.shared.table.hint(for: .newWorkroom), label: "New workroom",
      identifier: "NewWorkroom",
      onHover: { addHovering = $0 },
      action: { store.raiseWorkroomPicker(.new) })
  }

  /// The "open workroom" button — raises the Open Workroom picker (`requestOpenWorkroomPicker`, the
  /// same flag File ▸ Open workroom… / ⌘O sets). Sits just left of the "+" and shares its exact
  /// size/style (a hover-washed rounded glyph).
  private var openWorkroomButton: some View {
    glyphButton(
      "chevron.down", hovering: openHovering,
      help: "Open workroom" + Shortcuts.shared.table.hint(for: .openWorkroom),
      label: "Open workroom",
      identifier: "OpenWorkroom",
      onHover: { openHovering = $0 },
      action: { store.raiseWorkroomPicker(.open) })
  }

  /// One builder for both trailing buttons, so their well and hit area are identical **by
  /// construction** rather than by two modifier chains that agree today. The glyph is centred in the
  /// fixed `glyphBox` before the padding, which is what makes the two wells the same size despite the
  /// symbols not being.
  private func glyphButton(
    _ systemName: String, hovering: Bool, help: String, label: String, identifier: String,
    onHover: @escaping (Bool) -> Void, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: Self.glyphBox, height: Self.glyphBox)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(tokens.hover.opacity(hovering ? 1 : 0))
        )
        // The whole padded glyph (the hover well's area) is clickable/hoverable, not just the symbol —
        // the transparent padding wouldn't hit-test on its own.
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover(perform: onHover)
    .padding(.leading, 2)
    .help(help)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
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
  @EnvironmentObject var vcsStatus: VCSStatusService
  /// Not Observation-tracked: held so the chip re-renders when its unread count changes, which
  /// `marks` reads.
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.themeTokens) private var tokens
  @Default(.showTitleBarTabs) private var showTitleBarTabs
  /// Read through Observation: this chip re-renders when its own workroom's panes change.
  private var terminals: TerminalPanes { store.terminals }

  private var isRoot: Bool {
    if case .root = sid { return true }
    return false
  }

  /// Its names, glyph and close name, shared with its Open Tabs view row (#819).
  private var presentation: WorkroomTabPresentation {
    store.workroomTabPresentation(sid: sid, target: target)
  }

  /// Its state marks, shared with its Open Tabs view row (#819).
  private var marks: WorkroomTabMarks { store.workroomTabMarks(sid: sid, target: target) }

  /// A root's branch (nil for a workroom), reusing the sidebar's root presentation.
  private var branchLabel: String? {
    guard case .root(let project) = sid else { return nil }
    return vcsStatus.rootPresentation(for: project).label
  }

  private var glyph: String { presentation.glyph }
  private var primaryLabel: String { presentation.primaryLabel }
  private var workroomName: String? { presentation.workroomName }
  /// The full, untruncated rendered title, for the tooltip (as `TerminalTabChip.help(tab.title)`).
  private var fullTitle: String { presentation.fullTitle }
  /// The name Close asks about, for the right-click menu and the hover ✕.
  private var closeName: String? { presentation.closeName }
  private var hasActivity: Bool { marks.hasUnread }

  /// Close every terminal of this tab, as the menu's Close does: it asks first.
  private func requestClose() {
    guard let closeName else { return }
    store.modals.pendingWorkroomClose = PendingWorkroomClose(target: target, name: closeName)
  }

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
      // only, a workroom chip shows the full set — same as before the extraction. A create's chip has
      // no terminals to close while its run lasts (#483): its pane's own actions end it.
      .contextMenu {
        WorkroomMenuAdapter(sid: sid, target: target, closeName: closeName, style: .full)
        // The bar's own item (`TitlebarContextMenu`), here too, since a tab covers its stretch of bar.
        Divider()
        Toggle(TitleBarTabsToggle.title, isOn: $showTitleBarTabs)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        accessibilityLabel(hasActivity: hasActivity, running: marks.run == .running)
      )
      // The hover ✕ is hidden until the pointer is over the tab, so Close is an action here too.
      .accessibilityActions {
        if closeName != nil { Button("Close") { requestClose() } }
      }
      .accessibilityIdentifier("workroom.tab.\(target.id)")
      .accessibilityAddTraits(isActive ? .isSelected : [])
      .scaleEffect(isDragging ? 1.04 : 1)
      .shadow(color: .black.opacity(isDragging ? 0.2 : 0), radius: isDragging ? 2.5 : 0, y: 1)
  }

  /// The icons + title row: everything inside the pill's padding.
  private var contentRow: some View {
    // Icons stay vertically centered (center-aligned outer HStack); only the two texts share a
    // baseline, via the inner `.firstTextBaseline` group below.
    HStack(spacing: 6) {
      // Leading glyph: a house marks a project root, a cube an isolated workroom — set before the name.
      // Its tint carries the VCS dirty signal (orange) in place of a separate status dot.
      Image(systemName: glyph)
        .font(.system(size: 10))
        .foregroundStyle(
          VCSStatusPresentation.iconTint(vcsStatus.workroomStatuses[sid] ?? .unresolved, tokens)
        )
        .help(isRoot ? "" : target.hostTooltip)
      if let reason = target.terminalUnavailability {
        WarningGlyph()
          .font(.system(size: 10))
          .help(reason.title)
      }
      // The project name and (for a workroom) its own name, separated by a slash — one shared, smaller
      // size for all the chip text (`.subheadline`). On the focused tab the workroom name is full
      // strength (matches the project name) rather than the dimmer secondary it uses when unfocused.
      // Unread activity is marked by the accent colour on the project name alone (no dot here).
      // A terminal waiting on the user (#358) leads the title.
      if terminals.needsAttention(forTargetID: target.id) {
        ProgramStatusGlyph(
          mark: .blocked, stale: terminals.isWaitingStale(forTargetID: target.id), size: 9
        )
        .help(
          ProgramStatusPresentation.waitingTooltip(
            count: terminals.blockedTerminalCount(forTargetID: target.id)))
      }
      WorkroomTabTitle(
        presentation: presentation, hasUnread: hasActivity, folderFont: .caption,
        emphasizesWorkroom: isActive
      )
      .font(.subheadline)
      // Cap the title group as a whole rather than each `Text`, so the pair shares one budget
      // instead of each name getting its own. Note this does NOT make them truncate as a single
      // unit: an `HStack` satisfies its least-flexible children first, so the longer of the two
      // names absorbs the shortfall and both can end up clipped (`verylongproj…/verylongwo…`). That
      // is the intended trade — the alternative, a fixed per-`Text` cap, clips a short name beside a
      // long one for no reason. A short title stays tight (leading alignment, the HStack sizes to
      // its ideal width up to the cap).
      //
      // The cap is the shared one, so a workroom chip is never wider than a terminal one; it is spent
      // on two names here against that chip's one, which is why a workroom chip starts truncating at a
      // shorter combined length.
      .frame(maxWidth: TabStripMetrics.maxChipTitle, alignment: .leading)
      // VCS dirty status is carried by the leading house/cube tint above (no separate dot here).
      // Run-command dot (issue #7), trailing-most: green play while running; a red octagon if the
      // last run FAILED (#79 — distinct glyph, not just a red tint, for colourblind safety); hidden
      // once it has a run tab but is cleanly stopped.
      if let run = marks.run { WorkroomRunMark(run: run) }
    }
  }

  /// The pill: `contentRow` plus its interior padding, fills, outline, running underline, outer
  /// margin and the width measurement the drag-reorder math reads.
  private var pill: some View {
    contentRow
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      // The ✕ shows on hover only, over the title's trailing end, as on a pane's tabs.
      .tabHoverClose(isHovered: isHovered && closeName != nil) {
        TabCloseButton(action: requestClose)
          .help("Close \(closeName ?? fullTitle)")
          .accessibilityLabel("Close \(closeName ?? fullTitle)")
          .accessibilityIdentifier("workroom.tabClose.\(target.id)")
      }
      // Selection & hover fill — the same treatment as the terminal tab chips: the selected tab is
      // filled with the terminal background (`bg`) so it stands distinct from the strip; a hovered idle
      // tab gets the faint hover wash. Front-most background so a dragged chip's material lift sits
      // behind it. Under Glass the window base already is `bg`, so the selected chip takes the
      // selected-tab wash instead (`ThemeFill.tab`, #725).
      .background {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(ThemeFill.tab(active: isActive, hovered: isHovered))
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHovered)
      }
      // A solid lifted chip while dragging.
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(.thickMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(tokens.border, lineWidth: 1)
          )
          .opacity(isDragging ? 1 : 0)
      }
      // Only the selected tab is outlined — a stronger `fgDim` stroke (not the `border` hairline) so it
      // reads as clearly selected. Mirrors the terminal tab chips.
      .overlay {
        if isActive {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(tokens.fgDim, lineWidth: 1)
        }
      }
      // A flowing accent underline along the chip's base while any of this workroom's terminals is
      // working (OSC 9;4) — the same indeterminate-progress animation as the terminal tabs (issue #28).
      // An overlay so it never enters the width the drag gap math measures.
      // A waiting terminal (#358) or one stopped on an error holds a static line instead.
      .overlay(alignment: .bottom) {
        Group {
          switch marks.busy {
          case .blocked: StatusUnderline(color: tokens.warning)
          case .error: StatusUnderline(color: tokens.failure)
          case .running(let failed): RunningUnderline(failed: failed)
          case .done, .none: EmptyView()
          }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 1)
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
            .fill(tokens.border)
            .frame(width: 1, height: 16)
            .offset(x: -2)
        }
      }
      // Measure the chip's full footprint (pill + margin) for the drag gap math — pairs with the
      // inter-chip spacing to set the reorder pitch.
      .background {
        GeometryReader { geo in
          Color.clear.preference(key: WorkroomTabWidthKey.self, value: [sid: geo.size.width])
            // Where it sits in its row, for a workroom dragged in from another window (#444).
            .preference(
              key: WorkroomTabFrameKey.self,
              value: [sid: geo.frame(in: .named(WorkroomTabBar.runSpace))])
        }
      }
  }

  private func accessibilityLabel(hasActivity: Bool, running: Bool) -> String {
    var parts = [workroomName.map { "\(primaryLabel), workroom \($0)" } ?? primaryLabel]
    if let branchLabel { parts.append("on \(branchLabel)") }
    let vcs = VCSStatusPresentation.accessibilityLabel(
      vcsStatus.workroomStatuses[sid] ?? .unresolved)
    if !vcs.isEmpty { parts.append(vcs) }
    if let reason = target.terminalUnavailability { parts.append(reason.title.lowercased()) }
    if running { parts.append("running") }
    let waiting = terminals.blockedTerminalCount(forTargetID: target.id)
    if waiting > 0 {
      parts.append(
        ProgramStatusPresentation.waitingLabel(
          count: waiting, stale: terminals.isWaitingStale(forTargetID: target.id)))
    }
    // The red underline's spoken twin: a terminal here reported an error.
    if terminals.isProgressFailed(forTargetID: target.id)
      || terminals.hasProgramError(forTargetID: target.id)
    {
      parts.append("a command reported an error")
    }
    if hasActivity { parts.append("unread activity") }
    return parts.joined(separator: ", ")
  }
}

/// Collects each Workrooms tab chip's natural width for the drag gap math (issue #23).
private struct WorkroomTabWidthKey: PreferenceKey {
  static let defaultValue: [SidebarID: CGFloat] = [:]
  static func reduce(value: inout [SidebarID: CGFloat], nextValue: () -> [SidebarID: CGFloat]) {
    value.merge(nextValue()) { _, new in new }
  }
}

private struct WorkroomTabFrameKey: PreferenceKey {
  static let defaultValue: [SidebarID: CGRect] = [:]
  static func reduce(value: inout [SidebarID: CGRect], nextValue: () -> [SidebarID: CGRect]) {
    value.merge(nextValue()) { _, new in new }
  }
}
