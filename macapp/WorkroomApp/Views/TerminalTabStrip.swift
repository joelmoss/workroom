import Defaults
import SwiftUI

/// The horizontal tab strip above a target's terminal: a chip per terminal tab, a "+" to open a
/// new one, and the drag interactions — reorder within the strip, or drag a chip down into a pane
/// to split (issue #3). Fully owns the reorder drag state; the drop-into-pane wiring is shared with
/// the pane content, so `WorkroomTerminalsView` passes a `chipPaneDrag` binding (the live preview the
/// pane tree renders) plus `localize`/`dropTarget` closures that resolve a cursor point against the
/// pane area (which only the coordinator knows the frame of).
///
/// The "+" is **adaptive** (issue #129): while the tabs fit it sits inline, hugging the last chip;
/// once they overflow it lifts out of the scroller and pins at the strip's trailing edge, so it's
/// never scrolled out of reach. The scroller's trailing edge carries an alpha ramp in that state, so
/// a clipped chip dissolves instead of being cut mid-glyph. The decision itself is
/// `TabStripOverflow.pinsControls`, wired up by the shared `OverflowingTabScroller` (which
/// `WorkroomTabBar` uses too, so the two strips can't drift).
struct TerminalTabStrip: View {
  let tabs: [TerminalTab]
  let activeID: TerminalTab.ID?
  let target: TerminalTarget
  @ObservedObject var sessions: TerminalSessions
  /// In a workroom-split group (issue #110) the strip tightens its leading inset so the leftmost tab
  /// lines up with the left edge of the group's terminal panel below it. Default (solo) keeps 8pt.
  var compact: Bool = false
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @EnvironmentObject var agentManager: TerminalAgentManager
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The tab whose ✦ agent popover is open.
  @State private var agentPopoverTab: TerminalTab.ID?
  /// Global default diff layout — the toolbar's mode toggle shows it as active until this tab gets a
  /// per-tab override (`TerminalTab.diffViewModeOverride`).
  @Default(.diffViewMode) private var defaultDiffViewMode

  /// The live drop-into-pane preview, shared with `PaneTreeView` via the coordinator.
  @Binding var chipPaneDrag: PaneDragState?
  /// The pane-local point for a chip drag at a global location, or nil when the cursor is still over
  /// the strip (→ a reorder, not a drop-into-pane). Owned by the coordinator (needs the pane frame).
  let localize: (CGPoint) -> CGPoint?
  /// Where a chip dropped at a global location lands (pane + edge), or nil if it isn't over a pane.
  let dropTarget: (CGPoint) -> (tab: TerminalTab.ID, edge: PaneEdge)?

  @State private var hoveredTab: TerminalTab.ID?
  @State private var addHovering = false
  /// The last chip click (id + time), so a quick second click on the same chip promotes a preview
  /// content tab to persisted without delaying the eager first-click select (#66).
  @State private var lastChipClick: ChipClick?

  // Drag-to-reorder. The tab order is *frozen* for the duration of a drag: the dragged
  // chip simply follows the cursor (its slot never moves, so it can't jump), and the
  // other chips slide aside to open a gap. The reorder is committed once, on drop.
  @State private var draggingID: TerminalTab.ID?
  @State private var dragTranslation: CGFloat = 0
  @State private var widths: [TerminalTab.ID: CGFloat] = [:]

  private let tabSpacing: CGFloat = 4
  /// The strip's own right inset. Lives here rather than on `tabToolbar` (which renders *nothing* when
  /// there's no active tab) so a pinned "+" is never flush against the pane edge.
  private static let stripTrailingInset: CGFloat = 4

  /// The strip's leading inset: in a workroom-split group the leftmost tab lines up with the group's
  /// terminal panel below (issue #110); solo keeps 8pt.
  private var leadingInset: CGFloat { compact ? 4 : 8 }

  var body: some View {
    // Resolve the drag once per layout: which tab is dragging, and where it would land.
    let draggedIndex = draggingID.flatMap { id in tabs.firstIndex { $0.id == id } }
    // While dragging a chip down into a pane, the strip stops opening a reorder gap.
    let dropIndex =
      chipPaneDrag != nil ? nil : draggedIndex.map { dropTargetIndex(tabs, draggedIndex: $0) }
    let draggedWidth = draggingID.flatMap { widths[$0] } ?? 0
    // Members of the split group (≥2), so a grouped chip's selected pill can inset itself to sit
    // *inside* the `splitWell` bracket rather than overrunning it.
    let groupMembers = splitMemberSet

    HStack(spacing: 0) {
      // The scrolling chips plus the adaptive "+" (issue #129), assembled by the shared
      // `OverflowingTabScroller`. The width it measures for the overflow predicate is the scroller's
      // own: it's the flexible child beside the `fixedSize` toolbar, so it already equals "strip minus
      // toolbar" (and the full strip when there's no active tab and the toolbar renders nothing).
      OverflowingTabScroller(
        leadingInset: leadingInset, spacing: tabSpacing,
        inlineLead: TabStripMetrics.inlineAddLead,
        // Scroll the focused tab into view on selection (issue #129 follow-up); suspended mid-drag,
        // like the reorder gap animation below.
        scrollTarget: activeID, scrollSuspended: draggingID != nil
      ) { overflowing in
        chipRun(
          tabs, draggedIndex: draggedIndex, dropIndex: dropIndex, draggedWidth: draggedWidth,
          groupMembers: groupMembers, overflowing: overflowing)
      } controls: {
        addTerminalButton
      }
      // Per-current-tab actions (issue #72), pinned to the strip's right edge as a fixed-size layout
      // sibling of the scrolling tabs — so the chip area yields first in a cramped split pane and the
      // toolbar never overlaps the chips. An overflowing strip's "+" now sits between the two, pinned
      // to the scroller's trailing edge (issue #129). The remove-from-split ✕ used to sit to its
      // right; it now lives in the workroom-split group title bar (issue #110).
      tabToolbar
    }
    // No top padding: the strip sits flush at the top of the detail pane so the terminal tabs align
    // with the top of the sidebar (the pane's own top inset is dropped too — see `WorkroomPaneLeaf`).
    .padding(.top, 0)
    // Flush with the content below — the active tab's `bg` fill bridges the panel→bg colour step so
    // the strip reads as part of the terminal panel (Chrome-style). No bottom gap.
    .padding(.bottom, 0)
    .padding(.trailing, Self.stripTrailingInset)
  }

  /// The chips themselves plus the hairline that sets the inline "+" apart — everything that scrolls
  /// and stays put across an overflow flip. Measured as one run for the overflow predicate (by
  /// `OverflowingTabScroller`, which also lays the row out with the leading inset: in a split group the
  /// leftmost tab lines up with the group's terminal panel below — 4pt compact gutter, issue #110 —
  /// while solo keeps the 8pt inset). The split bracket is drawn behind it (leading-aligned, so x = 0
  /// is the first chip's leading edge, which is what `splitRunRect` computes against).
  @ViewBuilder
  private func chipRun(
    _ tabs: [TerminalTab], draggedIndex: Int?, dropIndex: Int?, draggedWidth: CGFloat,
    groupMembers: Set<TerminalTab.ID>, overflowing: Bool
  ) -> some View {
    HStack(spacing: tabSpacing) {
      ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
        let isDragging = draggingID == tab.id
        let isHovered = hoveredTab == tab.id && draggingID == nil
        // Activity in an unfocused tab highlights the tab itself (accent title + faint accent
        // fill) instead of a count — a tab is too narrow for a number.
        let hasActivity = notifications.count(tab: tab.id) > 0
        // Run-command state for this tab's chip icon (issue #7): only the dedicated run tab
        // carries one — running (green) vs failed (red octagon, #79) vs stopped/exited (dim).
        // Process-based, distinct from the OSC-9;4 RunningUnderline below.
        let runState: TerminalTabChip.RunState? =
          store.runTabID(for: target.id) == tab.id
          ? (store.isRunCommandRunning(for: target.id)
            ? .running : (store.runFailed(for: target.id) ? .failed : .stopped))
          : nil
        // Dragged chip tracks the cursor; the rest shift to open the gap.
        let offsetX =
          isDragging
          ? dragTranslation
          : gapShift(
            for: index, draggedIndex: draggedIndex, target: dropIndex,
            amount: draggedWidth + tabSpacing)
        // A ✦ badge marks any tab with a live diagnosis (issue #49) — the per-tab signal that
        // complements the active tab's diagnosis shown in the detail-panel status bar.
        let agentBadge = agentManager.banners[tab.id] != nil
        TerminalTabChip(
          tab: tab, isActive: tab.id == activeID, isHovered: isHovered,
          isDragging: isDragging, hasActivity: hasActivity, runState: runState,
          showLeadingSeparator: showsLeadingSeparator(at: index),
          isGrouped: groupMembers.contains(tab.id),
          agentBadge: agentBadge, onAgentTap: { agentPopoverTab = tab.id }
        ) {
          store.requestCloseTerminalTab(tab.id, for: target)
        }
        .popover(
          isPresented: Binding(
            get: { agentPopoverTab == tab.id },
            set: { if !$0 { agentPopoverTab = nil } })
        ) {
          agentPopover(for: tab)
        }
        .onHover { inside in
          if inside { hoveredTab = tab.id } else if hoveredTab == tab.id { hoveredTab = nil }
        }
        .onTapGesture {
          // Eager: select on the first click (changes `active.id`; the view's .onChange hook
          // marks the tab read). A quick second click on the same chip promotes a preview content
          // tab to persisted (#66) — `persist` no-ops on terminal/persisted tabs, so this is safe
          // for every chip and never delays the select.
          let now = Date()
          sessions.select(tab.id, for: target)
          if let last = lastChipClick, last.id == tab.id, now.timeIntervalSince(last.at) < 0.35 {
            sessions.persist(tab.id, for: target)
            lastChipClick = nil
          } else {
            lastChipClick = ChipClick(id: tab.id, at: now)
          }
        }
        .tabChipContextMenu(tab: tab, target: target, store: store, sessions: sessions)
        // Measure in .global space: a .local drag reads coordinates relative to the
        // chip, which itself moves via .offset(dragTranslation) — that feedback loop
        // dampens the translation so the chip lags the cursor. Global space is fixed.
        .gesture(
          DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
              if draggingID == nil { draggingID = tab.id }
              guard draggingID == tab.id else { return }
              dragTranslation = value.translation.width
              // Dragged down over the pane area → preview a drop-into-pane (the strip stops gapping).
              chipPaneDrag = localize(value.location)
                .map { PaneDragState(tabID: tab.id, location: $0) }
            }
            .onEnded { value in
              if let drop = dropTarget(value.location) {
                sessions.moveTabIntoSplit(
                  tab.id, ontoEdge: drop.edge, of: drop.tab, for: target)
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
        .id(tab.id)
      }
      // A divider sets the new-terminal (+) button apart from the last tab (mirrors the workroom
      // tab bar). Hidden when the last tab is set apart on its own — focused or hovered — to match
      // the "no divider beside the focused/hovered tab" rule above, and when the "+" has pinned
      // (issue #129): the fade and the gutter already separate the two regions, and a hairline beside
      // a dissolving edge reads as a cut. Toggled via OPACITY (not removed) so it stays laid out and
      // the "+" never shifts as the hover/focus comes and goes — which also keeps the measured run
      // width stable across those transitions.
      // Only present at all with ≥1 tab (a split member's empty strip is just the "+" and close ✕).
      // Negative leading trims the gap to the last tab to ~2pt (HStack `tabSpacing` 4 − 2), matching
      // the inter-tab dividers.
      if !tabs.isEmpty {
        Rectangle()
          .fill(ThemeService.shared.tokens.border)
          .frame(width: 1, height: 14)
          .padding(.leading, -2)
          .padding(.trailing, 4)
          .opacity(showsTrailingDivider && !overflowing ? 1 : 0)
      }
    }
    .background(alignment: .leading) { splitWell(tabs) }
    .onPreferenceChange(TabWidthKey.self) { widths = $0 }
  }

  /// The "new terminal" (+) button, rendered in one of two positions (issue #129): inline as the last
  /// element of the scrolling row while the tabs fit, so it hugs the rightmost tab; or lifted out and
  /// pinned to the scroller's trailing edge once they overflow, so it can't be scrolled out of reach.
  /// The same view either way; `OverflowingTabScroller` applies its inline positioning pad and takes
  /// its width measurement, so that width stays a pure intrinsic measurement.
  private var addTerminalButton: some View {
    Button {
      sessions.addTab(for: target)
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
    .help("New terminal (⌘T)")
    .accessibilityLabel("New terminal")
    .accessibilityIdentifier("NewTerminal")
  }

  /// Icon-only actions for the *current* (active) tab (issue #72): the diff view-mode toggle + "Open
  /// file in…" (diff tabs only), "Split right", and "Close all". Renders nothing when there's no
  /// active tab. `fixedSize` so it keeps its intrinsic width and the scrolling chip area yields first
  /// in a narrow split pane.
  @ViewBuilder
  private var tabToolbar: some View {
    if let active = tabs.first(where: { $0.id == activeID }) {
      HStack(spacing: 2) {
        // Diff (content) tab: the unified/side-by-side switch (issue #66) + open the working file in
        // the in-app viewer. The switch is one grouped segmented control — the active mode's
        // segment stays lit; clicking sets this tab's override (`TerminalTab.diffViewModeOverride`),
        // which the pane's `DiffViewer` re-renders to. Shows the global default until a choice is made.
        if case .diff(let descriptor) = active.content {
          DiffModeSwitch(mode: active.diffViewModeOverride ?? defaultDiffViewMode) {
            sessions.setDiffViewMode($0, forTab: active.id, in: target)
          }
          // Open the working file in the in-app viewer (issue #117). Disabled when the source was
          // deleted (review D4) — there's no working copy to open.
          TabToolbarButton(
            systemImage: "doc.text", help: "Open File",
            accessibilityLabel: "Open File", identifier: "tab.toolbar.openFile"
          ) {
            store.openFilePreview(path: descriptor.path)
          }
          .disabled(descriptor.change == .deleted)
        }
        // Markdown file tab: the source/preview switch (the toggle lifted out of the file viewer's
        // own header into the tab toolbar, alongside split). Sets this tab's
        // `markdownPreviewOverride`, which the pane's `PlainFileViewer` reads. Markdown-only —
        // other files have no rendered form, so no switch.
        if case .file(let descriptor) = active.content,
          PlainFileViewer.isMarkdown(descriptor.path)
        {
          MarkdownModeSwitch(preview: active.markdownPreviewOverride ?? true) {
            sessions.setMarkdownPreview($0, forTab: active.id, in: target)
          }
        }
        TabToolbarButton(
          systemImage: "rectangle.trailinghalf.inset.filled", help: "Split right (⌘D)",
          accessibilityLabel: "Split right", identifier: "tab.toolbar.splitRight"
        ) {
          sessions.splitTab(active.id, on: .right, for: target)
        }
        TabToolbarButton(
          systemImage: "rectangle.bottomhalf.inset.filled", help: "Split down (⇧⌘D)",
          accessibilityLabel: "Split down", identifier: "tab.toolbar.splitDown"
        ) {
          sessions.splitTab(active.id, on: .bottom, for: target)
        }
        TabToolbarButton(
          systemImage: "xmark.square", help: "Close all tabs in this workroom",
          accessibilityLabel: "Close all tabs in this workroom", identifier: "tab.toolbar.closeAll"
        ) {
          store.requestCloseAllTerminalTabs(for: target)
        }
      }
      .fixedSize()
    }
  }

  /// A rounded *outline* bracketing the split's contiguous chip run, so it's easy to see which tabs
  /// are grouped/split (issue #3). Deliberately an outline, not a filled backing: a fill occupies the
  /// same channel as the active-chip fill, so any visible strength made a grouped-but-inactive chip
  /// read as focused. The border groups without competing with selection. Hidden during a drag
  /// (group-aware strip drag is Phase 2), and only shown for a real split (≥2).
  @ViewBuilder
  private func splitWell(_ tabs: [TerminalTab]) -> some View {
    if draggingID == nil, let run = splitRunRect(tabs) {
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(ThemeService.shared.tokens.border, lineWidth: 1)
        .frame(width: run.width)
        .offset(x: run.x)
    }
  }

  /// The x-offset and width of the split members' contiguous run within the chip strip, in the chips'
  /// coordinate space (x = 0 at the first chip). `nil` when there's no split. Members are guaranteed
  /// contiguous by `displayedTabIDs`. Maps this strip's model to position-indexed widths and delegates
  /// the arithmetic to `TabStripSplitRun` (unit-tested there, and sharing one summation with the
  /// overflow predicate's `runWidth`).
  private func splitRunRect(_ tabs: [TerminalTab]) -> (x: CGFloat, width: CGFloat)? {
    guard let members = sessions.split(for: target)?.tabIDs, members.count >= 2 else { return nil }
    let memberSet = Set(members)
    return TabStripSplitRun.rect(
      widths: tabs.map { widths[$0.id] ?? 0 },
      memberIndices: tabs.indices.filter { memberSet.contains(tabs[$0].id) },
      spacing: tabSpacing)
  }

  /// Where the dragged tab would land given its current translation (delegates to the shared
  /// `TabReorder` math, mapping this strip's tabs to position-indexed widths).
  private func dropTargetIndex(_ tabs: [TerminalTab], draggedIndex di: Int) -> Int {
    TabReorder.dropTargetIndex(
      widths: tabs.map { widths[$0.id] ?? 0 }, draggedIndex: di,
      translation: dragTranslation, spacing: tabSpacing)
  }

  /// Horizontal shift for a non-dragged chip so the row opens a gap at the drop target (delegates to
  /// the shared `TabReorder` math).
  private func gapShift(for index: Int, draggedIndex: Int?, target: Int?, amount: CGFloat)
    -> CGFloat
  {
    TabReorder.gapShift(index: index, draggedIndex: draggedIndex, target: target, amount: amount)
  }

  /// Whether to draw a hairline on the leading edge of tab `index`, separating it from its left
  /// neighbour. A divider sits between every adjacent pair of tabs, dropped around any tab that's set
  /// apart on its own: the **focused** tab (its border frames it) and the **hovered** tab (its wash
  /// frames it) — no divider immediately before or after either, so they don't double up. Also dropped
  /// at a split group's **outer** boundary (the `splitWell` bracket already separates the members
  /// there) and while dragging (reorder / drop-into-pane). Mirrors `WorkroomTabBar`.
  private func showsLeadingSeparator(at index: Int) -> Bool {
    guard index > 0, draggingID == nil, chipPaneDrag == nil else { return false }
    let here = tabs[index].id
    let prev = tabs[index - 1].id
    if here == activeID || prev == activeID { return false }
    if here == hoveredTab || prev == hoveredTab { return false }
    let members = splitMemberSet
    if members.contains(here) != members.contains(prev) { return false }
    return true
  }

  /// Whether the divider between the last tab and the "+" button shows. Dropped when the last tab is
  /// set apart on its own — focused or hovered — and, mirroring `showsLeadingSeparator`'s outer-edge
  /// rule, when the last tab is a split-group member: the `splitWell` bracket's right side already
  /// separates the group from the "+", so a divider there doubles up. Without the split-member case a
  /// group pinned to the far right kept this divider whenever an *inner* member was focused (the last
  /// tab wasn't the active one), so it showed alongside the bracket edge.
  private var showsTrailingDivider: Bool {
    guard let last = tabs.last?.id else { return false }
    if last == activeID || last == hoveredTab { return false }
    if splitMemberSet.contains(last) { return false }
    return true
  }

  /// The split group's members (≥2), or empty when there's no split — used to drop the separator at
  /// the group's outer edges (see `showsLeadingSeparator`).
  private var splitMemberSet: Set<TerminalTab.ID> {
    guard let members = sessions.split(for: target)?.tabIDs, members.count >= 2 else { return [] }
    return Set(members)
  }

  /// Commit the reorder on drop, then clear drag state (animated, so everything settles).
  private func commitDrag() {
    let tabs = sessions.tabs(for: target)
    if let id = draggingID, let di = tabs.firstIndex(where: { $0.id == id }) {
      let ti = dropTargetIndex(tabs, draggedIndex: di)
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
        sessions.moveTab(id, toIndex: ti, for: target)
        draggingID = nil
        dragTranslation = 0
      }
    } else {
      draggingID = nil
      dragTranslation = 0
    }
  }

  /// The ✦ agent popover for a tab (inline presentation): the diagnosis + its actions, off the grid.
  @ViewBuilder private func agentPopover(for tab: TerminalTab) -> some View {
    if let state = agentManager.banners[tab.id] {
      TerminalAgentBanner(
        state: state,
        onDiagnose: { agentManager.diagnose(tab: tab.id, target: target.id) },
        onInsertFix: { fix in
          if case .terminal(let s) = tab.content { s.view.sendText(fix) }
          agentPopoverTab = nil
        },
        onInvestigate: {
          let cwd: String
          if case .terminal(let s) = tab.content {
            cwd = s.view.lastKnownCwd ?? target.path
          } else {
            cwd = target.path
          }
          _ = store.terminals.addRunTab(for: target, command: "claude", cwd: cwd)
          agentManager.dismiss(tab: tab.id)
          agentPopoverTab = nil
        },
        onDismiss: {
          agentManager.dismiss(tab: tab.id)
          agentPopoverTab = nil
        }
      )
      .frame(width: 360)
    }
  }
}

/// A single terminal tab chip: its title, an always-visible close button, and the active/hover/
/// activity/dragging styling. Purely presentational — the strip wraps it with the hover, tap, and
/// drag gestures, since those drive (and read) the strip's shared drag state.
private struct TerminalTabChip: View {
  /// The run-command state shown as a leading chip icon — only the dedicated run tab has one (#7).
  /// `failed` (issue #79) renders a distinct glyph + colour, not just a red tint, so it stays legible
  /// for red/green colourblind users (the running/stopped play glyph vs the failed octagon).
  enum RunState { case running, stopped, failed }

  let tab: TerminalTab
  let isActive: Bool
  let isHovered: Bool
  let isDragging: Bool
  let hasActivity: Bool
  let runState: RunState?
  /// Draw a hairline on the leading edge, separating two adjacent idle tabs (computed by the strip).
  let showLeadingSeparator: Bool
  /// A member of a split group — its fill insets so it sits *inside* the group's bracket, never
  /// overrunning it (the bracket hugs the chip run, so a full-bleed pill would cover the border).
  let isGrouped: Bool
  /// A ✦ badge marking an available inline-agent diagnosis (issue #49); tapping opens its popover.
  var agentBadge: Bool = false
  var onAgentTap: () -> Void = {}
  let onClose: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let theme = ThemeService.shared

  /// The widest a tab title renders before it tail-truncates (~25 chars at `.callout`). Beyond this
  /// the chip would keep stretching; the ellipsis + `.help` tooltip carry the rest.
  private static let maxTitleWidth: CGFloat = 180

  /// Glyph + colour + a11y/help word for the run-state chip icon. Failure is carried by BOTH the
  /// glyph (octagon vs play) and the colour, so it survives red/green colourblindness (#79).
  private func runIconSpec(_ state: RunState) -> (glyph: String, color: Color, label: String) {
    switch state {
    case .running: return ("play.circle.fill", .green, "running")
    case .stopped: return ("play.circle.fill", theme.tokens.fgMuted, "stopped")
    case .failed: return ("xmark.octagon.fill", theme.tokens.failure, "failed")
    }
  }

  var body: some View {
    // Title and close button laid out side by side: a compact gap keeps the ✕ visibly tied to its
    // tab (a wide gap reads as detached) while still clearing the title so they never crowd.
    HStack(spacing: 6) {
      // Inline-agent diagnosis available (issue #49): a ✦ badge that opens the diagnosis popover.
      if agentBadge {
        Button(action: onAgentTap) {
          Image(systemName: "sparkles")
            .font(.system(size: 10))
            .foregroundStyle(theme.tokens.accent)
        }
        .buttonStyle(.plain)
        .help("Show the diagnosis for this command")
        .accessibilityIdentifier("terminal.agentBadge")
        .accessibilityLabel("Diagnosis available")
      }
      // Leading state dot for the run tab (#7): green play while the command runs, dim play once it
      // has cleanly exited, a red octagon if it failed (#79). The fixed 10pt size keeps the chip
      // width stable across the glyph swap. Mirrors the sidebar/workroom run dot — one signal.
      if let runState {
        let spec = runIconSpec(runState)
        Image(systemName: spec.glyph)
          .font(.system(size: 10))
          .foregroundStyle(spec.color)
          .help("Run command \(spec.label)")
          // The state word is the a11y label (and the XCUITest query handle for the failed icon, #79);
          // the chip's own `terminal.tab.<title>` identifier overrides any identifier set here.
          .accessibilityLabel(spec.label)
      }
      // A diff (content) tab gets a leading glyph so it reads as not-a-terminal at a glance (#66).
      if case .diff = tab.content {
        Image(systemName: "plusminus")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(theme.tokens.fgMuted)
          .accessibilityHidden(true)
      }
      // A file (content) tab gets a document glyph, same intent as the diff glyph above.
      if case .file = tab.content {
        Image(systemName: "doc")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(theme.tokens.fgMuted)
          .accessibilityHidden(true)
      }
      // A changeset (commit detail) tab gets a clock glyph (issue #59), same intent as above.
      if case .changeset = tab.content {
        Image(systemName: "clock")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(theme.tokens.fgMuted)
          .accessibilityHidden(true)
      }
      // Unread activity is marked by a leading accent dot (+ accent title) — a different visual
      // primitive from the selected tab's neutral fill, so the two never read alike.
      if hasActivity {
        Circle()
          .fill(theme.tokens.accent)
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
      }
      Text(tab.title)
        .font(.callout)
        // The focused tab's title is brighter (full primary) so it reads as selected; unfocused titles
        // dim to muted. Brightness only — NOT weight: a bold↔regular swap on switch re-measures the
        // title and nudges the chips sideways. Unread activity (accent) overrides either, on any tab.
        .foregroundStyle(
          hasActivity ? theme.tokens.accent : (isActive ? Color.primary : theme.tokens.fgMuted)
        )
        // A preview tab's name is italic until it's persisted (VS-Code semantics, #66).
        .italic(tab.isPreview)
        .lineLimit(1)
        .truncationMode(.tail)
        // Cap the title so a long name (a file path, a shell-set terminal title) tail-truncates with
        // an ellipsis instead of stretching the chip arbitrarily wide; the full title rides in the
        // chip's `.help` tooltip below. A short title stays tight (leading alignment, Text sizes to
        // its ideal width up to the cap).
        .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
      // The ✕ is always shown (every tab is closable at a glance), so the chip width is constant.
      TabCloseButton(action: onClose)
        .help("Close \(tab.title)")
        .accessibilityLabel("Close \(tab.title)")
    }
    .padding(.leading, 10)
    .padding(.trailing, 4)  // tighter than the leading inset — the ✕ sits near the chip's edge
    .padding(.vertical, 6)
    // Every tab is a self-contained pill, rounded on all four corners — no tab bleeds into the panel
    // (the focused pane isn't necessarily the one directly below the strip, e.g. a split). The active
    // tab is filled with the terminal background (`bg`) so it stands distinct from the recessed strip;
    // inactive tabs keep the faint hover wash, the `panel` bar showing through the clear idle fill. A
    // grouped chip insets its pill so it nests inside the `splitWell` bracket instead of overrunning it.
    .background {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isActive ? theme.tokens.bg : (isHovered ? theme.tokens.hover : Color.clear))
        .padding(isGrouped ? EdgeInsets(top: 2, leading: 3, bottom: 2, trailing: 3) : EdgeInsets())
        // Fade the hover wash in/out instead of snapping it on.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHovered)
    }
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(.thickMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(theme.tokens.border, lineWidth: 1)
        )
        .opacity(isDragging ? 1 : 0)
    }
    // Measure the chip's natural width for the drag gap math.
    .background {
      GeometryReader { geo in
        Color.clear.preference(key: TabWidthKey.self, value: [tab.id: geo.size.width])
      }
    }
    // Only the focused tab is outlined: unfocused tabs have a transparent border so they recede into
    // the strip, and the focused tab's outline is a stronger stroke (`fgDim`, not the old `border`
    // hairline) so it reads as clearly selected rather than washed out. Grouped tabs are framed by the
    // shared `splitWell` bracket instead, so they skip it.
    .overlay {
      if !isGrouped && isActive {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(theme.tokens.fgDim, lineWidth: 1)
      }
    }
    // Hairline centred in the gap between this chip and its left neighbour, so it sits cleanly between
    // the tabs and never overlaps either pill. The gap is the HStack's `tabSpacing` (4pt); the overlay
    // is anchored to this chip's leading edge, so the 1pt rect's centre lands at −tabSpacing/2 = −2 →
    // offset −2.5 (the leading-anchored rect's own centre is at +0.5). An overlay (not an HStack
    // element) so it never enters the width the drag-gap math measures.
    .overlay(alignment: .leading) {
      if showLeadingSeparator {
        Rectangle()
          .fill(theme.tokens.border)
          .frame(width: 1, height: 14)
          .offset(x: -2.5)
      }
    }
    // A flowing underline along the chip's base while a command runs in this tab (issue #28).
    // An overlay so it never changes the chip's measured width (the drag gap math reads that).
    .overlay(alignment: .bottom) {
      if tab.isRunning {
        RunningUnderline()
          .padding(.horizontal, 6)
          .padding(.bottom, 1)
      }
    }
    .contentShape(Rectangle())
    // The full, untruncated title as a tooltip — so a tail-truncated chip still reveals its whole
    // name on hover. The close button's own `.help` (inner) wins when the cursor is over the ✕.
    .help(tab.title)
    .accessibilityIdentifier("terminal.tab.\(tab.title)")
    .scaleEffect(isDragging ? 1.04 : 1)
    .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: isDragging ? 6 : 0, y: 2)
  }
}

/// Collects each tab chip's natural width for the drag gap math.
private struct TabWidthKey: PreferenceKey {
  static var defaultValue: [TerminalTab.ID: CGFloat] = [:]
  static func reduce(
    value: inout [TerminalTab.ID: CGFloat], nextValue: () -> [TerminalTab.ID: CGFloat]
  ) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// A thin accent underline that flows left→right while a command runs in a tab (issue #28): a base
/// accent track with a brighter highlight that sweeps across it, conveying indeterminate progress.
/// Under Reduce Motion the sweep is dropped for a static, fuller-opacity track.
/// Reused by `WorkroomTabBar`'s chips so a busy workroom tab shows the same flowing underline.
struct RunningUnderline: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var sweeping = false
  private let theme = ThemeService.shared

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let highlight = max(20, width * 0.4)
      Capsule()
        .fill(theme.tokens.accent.opacity(reduceMotion ? 0.7 : 0.25))
        .overlay(alignment: .leading) {
          if !reduceMotion {
            Capsule()
              .fill(
                LinearGradient(
                  colors: [.clear, theme.tokens.accent, .clear],
                  startPoint: .leading, endPoint: .trailing)
              )
              .frame(width: highlight)
              // Travel the highlight from just off the leading edge to just off the trailing edge.
              .offset(x: sweeping ? width : -highlight)
          }
        }
        .clipShape(Capsule())
    }
    .frame(height: 2)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
        sweeping = true
      }
    }
  }
}

/// A tab's close button, overlaid on the title's right edge. Its own hover paints a subtle
/// background behind the ✕. (Show/hide is handled by the caller's overlay.)
private struct TabCloseButton: View {
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let theme = ThemeService.shared

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(hovering ? .primary : .secondary)
        .padding(3)
        // A circular hover well behind the ✕ (matches a round close affordance), faded in/out.
        .background(
          Circle()
            .fill(theme.tokens.hover.opacity(hovering ? 1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: hovering)
  }
}

/// A grouped two-segment switch for the diff view mode (issue #66): unified | side-by-side, rendered
/// as one control — a faint rounded track with a raised "thumb" behind the active segment — so it
/// reads as a single switch rather than two loose buttons. Clicking a segment reports that mode.
/// The unified / side-by-side segmented switch. Used by the tab toolbar (per-tab override) and the
/// changeset detail's diff header (its local override). Internal so both can share the one control.
struct DiffModeSwitch: View {
  /// The currently effective mode (this tab's override, or the global default) — the lit segment.
  let mode: DiffViewMode
  let select: (DiffViewMode) -> Void
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 0) {
      segment(.unified, help: "Unified diff", identifier: "tab.toolbar.diffUnified")
      segment(.sideBySide, help: "Side-by-side diff", identifier: "tab.toolbar.diffSideBySide")
    }
    .padding(1.5)
    .background(RoundedRectangle(cornerRadius: 6).fill(theme.tokens.surface))
  }

  @ViewBuilder
  private func segment(_ segMode: DiffViewMode, help: String, identifier: String) -> some View {
    let active = mode == segMode
    Button {
      select(segMode)
    } label: {
      Image(systemName: segMode.symbol)
        // A touch smaller than the plain action buttons (size 11): the `doc.*` glyphs render heavier,
        // so matching their size made the switch read as oversized next to them.
        .font(.system(size: 9.5))
        .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(active ? theme.tokens.bg : .clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
    .accessibilityIdentifier(identifier)
    .accessibilityAddTraits(active ? .isSelected : [])
  }
}

/// A grouped two-segment switch for a Markdown file tab's rendered-preview vs. source view, built to
/// match `DiffModeSwitch` (same track + raised-thumb styling) so the two toolbars read as siblings.
/// Clicking a segment reports whether preview should be on. Lives in the tab toolbar (issue: file
/// viewer toggle moved out of the pane header, alongside the split button).
private struct MarkdownModeSwitch: View {
  /// Whether rendered preview is the effective mode (this tab's override, defaulting to preview) — the
  /// lit segment.
  let preview: Bool
  let select: (Bool) -> Void
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 0) {
      segment(
        isPreview: true, symbol: "eye", help: "Rendered preview",
        identifier: "tab.toolbar.markdownPreview")
      segment(
        isPreview: false, symbol: "chevron.left.forwardslash.chevron.right", help: "Source",
        identifier: "tab.toolbar.markdownSource")
    }
    .padding(1.5)
    .background(RoundedRectangle(cornerRadius: 6).fill(theme.tokens.surface))
  }

  @ViewBuilder
  private func segment(isPreview: Bool, symbol: String, help: String, identifier: String)
    -> some View
  {
    let active = preview == isPreview
    Button {
      select(isPreview)
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 9.5))
        .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(active ? theme.tokens.bg : .clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
    .accessibilityIdentifier(identifier)
    .accessibilityAddTraits(active ? .isSelected : [])
  }
}

/// The remove-from-split (✕) control for a workroom split member. Hosted in the split-group title bar
/// (`WorkroomSplitGroupTitleBar`, issue #110) — present above every member regardless of its terminal
/// count or a blocking setup script, which is why it no longer needs to ride the tab strip or a
/// setup-overlay corner. A view (not an inline button) so it carries its own `onHover` — which both
/// gives the subtle hover feedback the other strip controls have AND ensures the `.help` tooltip's
/// tracking area is installed (a bare `.help` without any hover tracking can silently fail to show).
struct CloseWorkroomPaneButton: View {
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      // `pip.exit` (a pane with an arrow leaving its corner) reads as "pop this workroom out of the
      // split", not "close the workroom" — the ✕ was ambiguous (issue #110).
      Image(systemName: "pip.exit")
        .font(.system(size: 10))
        .foregroundStyle(hovering ? .primary : .secondary)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .help("Remove this workroom from the split")
    .accessibilityLabel("Remove workroom from split")
    .accessibilityIdentifier("workroom.pane.close")
  }
}

/// The last chip click — id + time — used by the strip's eager single/double tap discrimination (#66).
private struct ChipClick {
  let id: TerminalTab.ID
  let at: Date
}

extension View {
  /// The right-click menu for a tab chip — **also reused on the diff pane body** (issue #72), so a
  /// diff panel and its tab offer the same actions. Diff (content) tabs lead with "Open File in…"
  /// (disabled when the source was deleted — review D4) and, while still a preview, "Keep Open"
  /// (promotes it to persisted, #66). Both tab types then get the split items — disabled for a tab
  /// outside the currently visible split so it can't silently dissolve it (review D5) — and the close
  /// group (Close / Close Others / Close All).
  @ViewBuilder
  func tabChipContextMenu(
    tab: TerminalTab, target: TerminalTarget, store: AppStore, sessions: TerminalSessions
  ) -> some View {
    self.contextMenu {
      if case .diff(let descriptor) = tab.content {
        // Open the working file in the in-app viewer (issue #117), alongside the external-editor
        // "Open File in…" below — mirrors the Changes-panel row menu. Both no-op / disabled for a
        // deleted source (no working copy).
        Button {
          store.openFilePreview(path: descriptor.path)
        } label: {
          Label("Open File", systemImage: "doc.text")
        }
        .disabled(descriptor.change == .deleted)
        Button {
          store.openDiffTabFile(descriptor, for: target)
        } label: {
          Label("Open File in…", systemImage: "arrow.up.forward.app")
        }
        .disabled(descriptor.change == .deleted)
        if tab.isPreview {
          Button {
            sessions.persist(tab.id, for: target)
          } label: {
            Label("Keep Open", systemImage: "pin")
          }
        }
        Divider()
      }
      // A file tab gets the same actions as a diff tab (open in editor, pin a preview), so the new
      // file panes right-click like diff panes (they share this menu via PaneTreeView).
      if case .file(let descriptor) = tab.content {
        Button {
          store.openFileInEditor(path: descriptor.path)
        } label: {
          Label("Open File in…", systemImage: "doc.text")
        }
        if tab.isPreview {
          Button {
            sessions.persist(tab.id, for: target)
          } label: {
            Label("Keep Open", systemImage: "pin")
          }
        }
        Divider()
      }
      // A changeset (commit detail) tab has no per-file actions of its own, but still offers "Keep
      // Open" while previewed (issue #59) — same pin affordance as diff/file panes.
      if case .changeset = tab.content, tab.isPreview {
        Button {
          sessions.persist(tab.id, for: target)
        } label: {
          Label("Keep Open", systemImage: "pin")
        }
        Divider()
      }
      // Split-membership computed once, shared by the Split-disable gate and the "Remove from
      // Split" item below. `isMember` is true for a member of ANY split — visible or hidden (a
      // split can exist while a solo tab is focused), so removal still works for that member.
      let isMember = sessions.split(for: target)?.tabIDs.contains(tab.id) ?? false
      // Split this tab. Disabled for a tab outside the visible split (review D5) so right-clicking a
      // chip that isn't part of the shown split can't silently replace it.
      let splitDisabled = sessions.isSplitVisible(for: target) && !isMember
      Group {
        Button {
          sessions.splitTab(tab.id, on: .right, for: target)
        } label: {
          Label("Split Right", systemImage: "rectangle.trailinghalf.inset.filled")
        }
        Button {
          sessions.splitTab(tab.id, on: .left, for: target)
        } label: {
          Label("Split Left", systemImage: "rectangle.leadinghalf.inset.filled")
        }
        Button {
          sessions.splitTab(tab.id, on: .bottom, for: target)
        } label: {
          Label("Split Down", systemImage: "rectangle.bottomhalf.inset.filled")
        }
        Button {
          sessions.splitTab(tab.id, on: .top, for: target)
        } label: {
          Label("Split Up", systemImage: "rectangle.tophalf.inset.filled")
        }
      }
      .disabled(splitDisabled)
      // Remove ONLY this tab from the split — the inverse of Split R/L/D/U (issue #122). Shown
      // only for a real split member (hidden on solo tabs), matching the workroom-split menu's
      // "Remove from Split" (WorkroomContextMenu.swift). `extractFromSplit` pops just this leaf,
      // keeps any other members split, and dissolves only when <2 would remain; the removed tab is
      // shown solo. Not `role: .destructive` — the tab keeps running (its surface isn't torn down).
      if isMember {
        Divider()
        Button {
          sessions.extractFromSplit(tab.id, for: target)
        } label: {
          Label("Remove from Split", systemImage: "pip.exit")
        }
      }
      Divider()
      Button(role: .destructive) {
        store.requestCloseTerminalTab(tab.id, for: target)
      } label: {
        Label("Close", systemImage: "xmark")
      }
      Button(role: .destructive) {
        store.requestCloseOtherTerminalTabs(tab.id, for: target)
      } label: {
        Label("Close Others", systemImage: "xmark")
      }
      .disabled(sessions.tabs(for: target).count <= 1)
      Button(role: .destructive) {
        store.requestCloseAllTerminalTabs(for: target)
      } label: {
        Label("Close All", systemImage: "xmark")
      }
    }
  }
}
