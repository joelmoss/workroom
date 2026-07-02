import AppKit
import SwiftUI

/// A drag from the workroom tab bar into the split content (content-local point + the dragged tab's id).
struct WorkroomPaneDrag: Equatable {
  let sid: SidebarID
  var location: CGPoint
}

/// Workroom-into-workroom split renderer (issue #23 follow-up): renders `PaneLayout<SidebarID>` as
/// nested, resizable panes — each a full `TargetTerminalDetail`. Deliberately SEPARATE from the
/// terminal renderer `PaneTreeView` (whose re-parenting/blank-pane history makes surgery risky); it
/// reuses only the pure `PaneTreeLayout` geometry + the generic `PaneLayout` model and duplicates a
/// little view chrome (divider, focus border, drop band).
///
/// Like `PaneTreeView`, panes are laid out in ONE flat `ZStack`, positioned by absolute frames and
/// keyed by `SidebarID`, so a surviving pane keeps the exact same host across a layout change (only its
/// frame moves) — its terminal is never re-parented. `RootView` ALWAYS renders through this view when
/// the tab bar is on (a no-split case is just `.leaf(selected)`), so single↔split is a leaf-set change,
/// not a structural swap — the same lesson that made `WorkroomTerminalsView` always render through
/// `PaneTreeView`.
struct WorkroomSplitView: View {
  let layout: PaneLayout<SidebarID>
  /// Resolve a leaf to its live target (drops a since-deleted workroom). Owned by the store.
  let resolve: (SidebarID) -> TerminalTarget?
  let focusedID: SidebarID?
  /// The live drag of a workroom into the content — from the tab bar OR a split member's group title
  /// bar (issue #110). Drives the drop-edge highlight; a member's title bar writes it while dragging.
  @Binding var externalDrag: WorkroomPaneDrag?
  /// Content-local point for a global drag location (nil when over the title-bar strip). Owned by
  /// `RootView`; shared with the tab bar so a title-bar drag drops onto the same panes a chip would.
  let localize: (CGPoint) -> CGPoint?
  /// Where a drag at a global location lands (member pane + edge), or nil if not over a pane.
  let dropTarget: (CGPoint) -> (sid: SidebarID, edge: PaneEdge)?
  let onFocus: (SidebarID) -> Void
  let onSetRatio: (CGFloat, UUID) -> Void
  let onClose: (SidebarID) -> Void
  /// Move a member to land beside another at an edge (drag a group by its title bar). Wired to
  /// `store.insertWorkroomSplit`, the same transform the tab-bar chip drop uses.
  let onMove: (SidebarID, SidebarID, PaneEdge) -> Void

  private static let space = "workroomSplitContent"
  private let theme = ThemeService.shared

  var body: some View {
    let leaves = layout.tabIDs
    let multi = leaves.count >= 2
    GeometryReader { geo in
      let plan = PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: geo.size))
      ZStack(alignment: .topLeading) {
        ForEach(leaves, id: \.self) { sid in
          if let target = resolve(sid), let rect = plan.panes[sid] {
            WorkroomPaneLeaf(
              sid: sid, target: target, focused: sid == focusedID, multi: multi,
              externalDrag: $externalDrag, localize: localize, dropTarget: dropTarget,
              onClose: { onClose(sid) }, onMove: onMove
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .id(sid)
            // A tap on the pane *chrome* focuses it. Clicking *into* the terminal is handled by the
            // first-responder → selection callback (the libghostty NSView eats SwiftUI taps).
            .onTapGesture { onFocus(sid) }
          }
        }
        ForEach(plan.dividers) { d in
          WorkroomSplitDivider(orientation: d.orientation, ratio: d.ratio, total: d.total) {
            onSetRatio($0, d.id)
          }
          .frame(width: d.hitRect.width, height: d.hitRect.height)
          .position(x: d.rect.midX, y: d.rect.midY)
        }
        dropHighlight(plan: plan)
      }
      .coordinateSpace(.named(Self.space))
    }
    // When split, hold the group cards off the left/right sidebars with an outer gutter (issue #110) —
    // applied outside the GeometryReader so the panes reflow within the inset. Solo is flush as before.
    .padding(.horizontal, multi ? 6 : 0)
  }

  /// The accent band previewing where a dragged workroom tab will land (mirrors `PaneTreeView`).
  @ViewBuilder
  private func dropHighlight(plan: PaneTreeLayout.Plan<SidebarID>) -> some View {
    if let drag = externalDrag,
      let hit = PaneTreeLayout.dropTarget(at: drag.location, panes: plan.panes),
      hit.tab != drag.sid, let rect = plan.panes[hit.tab]
    {
      let band = PaneTreeLayout.edgeBand(hit.edge, in: rect)
      RoundedRectangle(cornerRadius: 8)
        .fill(theme.tokens.accent.opacity(0.25))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.tokens.accent, lineWidth: 2))
        .frame(width: band.width, height: band.height)
        .position(x: band.midX, y: band.midY)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }
}

/// Pure, testable mapping from a split member's `SidebarID` + its resolved `target` to the workroom
/// name shown in the group title bar. Extracted from `WorkroomPaneLeaf` so it is unit-testable without
/// instantiating the view (same rationale as `RootPresentation`).
///
/// INVARIANT: `target` MUST be the resolved target for `sid` (i.e. `AppStore.target(for: sid)`), so
/// `target.title` is *this* workroom's label-aware `displayName` (issue #41). A mismatched target would
/// display an unrelated title; the one caller satisfies this via `resolve(sid)`.
enum WorkroomSplitTitlePresentation {
  static func workroomName(sid: SidebarID, target: TerminalTarget) -> String? {
    // `target.title` is the label-aware `displayName`; NOT the raw `sid` name (issue #113).
    if case .workroom = sid { return target.title }
    return nil
  }
}

/// One workroom pane: the full terminal body + a focus border and a hover ✕ (remove from split). Solo
/// (`multi == false`) it's just the bare `TargetTerminalDetail`, so the single-workroom case renders
/// identically to the old `targetDetail` content.
private struct WorkroomPaneLeaf: View {
  let sid: SidebarID
  let target: TerminalTarget
  let focused: Bool
  let multi: Bool
  /// The shared workroom-drag state — the title bar writes it while dragging this group (issue #110).
  @Binding var externalDrag: WorkroomPaneDrag?
  let localize: (CGPoint) -> CGPoint?
  let dropTarget: (CGPoint) -> (sid: SidebarID, edge: PaneEdge)?
  let onClose: () -> Void
  let onMove: (SidebarID, SidebarID, PaneEdge) -> Void
  private let theme = ThemeService.shared

  var body: some View {
    Group {
      if multi {
        // A real split member: a group header (issue #110) tops the pane, identifying which workroom
        // this is, with the whole pane wrapped in a rounded card so members read as distinct units.
        VStack(spacing: 0) {
          WorkroomSplitGroupTitleBar(
            projectLabel: projectLabel, workroomName: workroomName, focused: focused,
            isMissing: target.isMissing, onClose: onClose
          )
          // Drag the group by its title bar to move the whole member within the split (issue #110) —
          // the SAME gesture/closures the tab-bar chip uses, so it drops onto the same panes and shows
          // the same drop-edge highlight. A plain click (no movement past `minimumDistance`) still
          // falls through to the leaf's focus tap.
          .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
              .onChanged { value in
                externalDrag = localize(value.location).map {
                  WorkroomPaneDrag(sid: sid, location: $0)
                }
              }
              .onEnded { value in
                if let drop = dropTarget(value.location), drop.sid != sid {
                  onMove(sid, drop.sid, drop.edge)
                }
                externalDrag = nil
              }
          )
          content(compact: true)
        }
        // No border now: the group reads as a unit by a subtle raised fill over the `panel` base plus
        // the shadow + rounded corners (issue #110). The focused member's fill is accent-tinted so focus
        // reads as a colour; the rest take a faint neutral lift — both dedicated theme tokens.
        .background(focused ? theme.tokens.splitGroupFocusedFill : theme.tokens.splitGroupFill)
        .background(theme.tokens.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(focused ? 0.18 : 0.10), radius: focused ? 6 : 3, y: 2)
        // A clear inter-group gutter on every side — the title bar (not the tab strip) sits at the
        // pane's top, so the old top:0 sidebar-alignment no longer applies to a split member.
        .padding(4)
      } else {
        // Solo: no header, no frame — the bordered terminals inside do the framing. Keep the 2pt gutter
        // on the sides and bottom, but NOT the top: the top edge sits flush so the terminal tab strip
        // aligns with the top of the sidebar (the single-workroom case renders identically to before).
        content(compact: false)
          .padding(EdgeInsets(top: 0, leading: 2, bottom: 2, trailing: 2))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workroom.pane")
    .accessibilityLabel(Text("Workroom \(target.title)"))
    .accessibilityAddTraits(focused && multi ? .isSelected : [])
  }

  /// The project name — the chip's primary label format (`AppStore.projectPath` last component),
  /// matching `WorkroomTabChip.primaryLabel`. Empty only if the sid resolves no project (never for a
  /// real split member).
  private var projectLabel: String {
    AppStore.projectPath(of: sid).map { ($0 as NSString).lastPathComponent } ?? ""
  }

  /// This member's own display name (nil for a project root) — the label-aware `target.title`,
  /// resolved through `WorkroomSplitTitlePresentation` so a relabel (issue #41) shows here
  /// immediately. Feeds both the title bar's visible text and its accessibility label (issue #113);
  /// NOT the raw `SidebarID` name, which never changes on relabel.
  private var workroomName: String? {
    WorkroomSplitTitlePresentation.workroomName(sid: sid, target: target)
  }

  @ViewBuilder
  private func content(compact: Bool) -> some View {
    if target.isMissing {
      // The workroom's directory has gone away (deleted on disk). Don't mount a terminal over a dead
      // path — show the same "Directory not found" state the solo detail uses. A co-displayed member
      // must be guarded here: `RootView`'s solo `isMissing` branch only covers the *selected* target,
      // so without this a non-focused member with a vanished path would render live terminal chrome
      // (issue #23 follow-up). The way out of the split is the title bar's ✕ (issue #110), which the
      // leaf draws above this content for every split member.
      ContentUnavailableView {
        Label("Directory not found", systemImage: "questionmark.folder")
      } description: {
        Text("\(target.title) points at a path that no longer exists.\n\(target.path)")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      // `surfaceActive: focused` so only the focused workroom pane's terminal grabs first responder —
      // a co-displayed non-focused pane must not steal focus (and retarget the selection) as it mounts.
      // The remove-from-split control now lives in the leaf's title bar (issue #110), not on the strip.
      TargetTerminalDetail(target: target, surfaceActive: focused, compact: compact)
    }
  }
}

/// The group header atop each workroom-split member (issue #110): a leading cube glyph, the
/// `project / workroom` label (matching the tab chip's format), and the relocated remove-from-split ✕.
/// Shown only for a real split member (`multi`), it spans the pane's full width and — together with the
/// leaf's rounded card — makes each member read as a distinct, identifiable group. Reflects focus by
/// colour (accent + full-strength text when focused, muted otherwise), the pane's selection signal.
private struct WorkroomSplitGroupTitleBar: View {
  let projectLabel: String
  let workroomName: String?
  let focused: Bool
  let isMissing: Bool
  let onClose: () -> Void
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 6) {
      // Leading glyph mirrors the workroom tab chip's cube; accent on the focused member, muted else.
      Image(systemName: "cube")
        .font(.system(size: 10))
        .foregroundStyle(focused ? theme.tokens.accent : theme.tokens.fgMuted)
      if isMissing {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.orange)
          .help("Directory not found")
      }
      // `project / workroom`, same format and size as `WorkroomTabChip`. Full-strength on the focused
      // member, muted otherwise — the brighter header is the in-content "this is the active pane" cue.
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(projectLabel)
          .foregroundStyle(focused ? Color.primary : theme.tokens.fgMuted)
        if let workroomName {
          Text("/").foregroundStyle(.tertiary)
          Text(workroomName)
            .foregroundStyle(focused ? Color.primary : theme.tokens.fgMuted)
        }
      }
      .font(.subheadline)
      .lineLimit(1)
      Spacer(minLength: 8)
      CloseWorkroomPaneButton(action: onClose)
    }
    // Trailing inset is tighter than the leading so the remove-from-split ✕ sits closer to the group's
    // right edge (the button carries its own 8pt hit padding).
    .padding(.leading, 10)
    .padding(.trailing, 4)
    .frame(height: 28)
    .frame(maxWidth: .infinity)
    // No own background and no bottom rule — inherit the card's raised lighter fill (issue #110) so the
    // header and the terminal body below read as one continuous surface.
    // So a tap/drag on the bar's empty area is hit-tested: a tap bubbles to the leaf's focus tap and a
    // drag (handled by the leaf's gesture on this bar) moves the group; the ✕ consumes its own click.
    .contentShape(Rectangle())
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workroom.pane.titlebar")
    .accessibilityLabel(
      Text(workroomName.map { "\(projectLabel), workroom \($0)" } ?? projectLabel)
    )
  }
}

/// A draggable divider that writes a new ratio for one split node. A near-twin of `PaneTreeView`'s
/// private `SplitDivider` (kept separate so the terminal renderer stays untouched), reusing the shared
/// `PaneTreeLayout.clampRatio`/`dividerThickness` math. Unlike `SplitDivider` it draws **no** separator
/// rule — each workroom pane already has its own rounded border, so a line in the gap would double up;
/// this is just the (invisible) resize hit-zone, surfaced only by the resize cursor on hover.
private struct WorkroomSplitDivider: View {
  let orientation: SplitOrientation
  let ratio: CGFloat
  let total: CGFloat
  let onRatio: (CGFloat) -> Void
  @State private var startRatio: CGFloat?

  var body: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.0001))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(coordinateSpace: .global)
          .onChanged { value in
            let start = startRatio ?? ratio
            if startRatio == nil { startRatio = start }
            let usable = max(1, total - PaneTreeLayout.dividerThickness)
            let delta =
              orientation == .horizontal ? value.translation.width : value.translation.height
            onRatio(PaneTreeLayout.clampRatio(start + delta / usable, total: total))
          }
          .onEnded { _ in startRatio = nil }
      )
      .onHover { inside in
        if inside {
          (orientation == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
          NSCursor.pop()
        }
      }
      .accessibilityElement()
      .accessibilityIdentifier("workroom.pane.divider")
      .accessibilityLabel(
        orientation == .horizontal ? "Vertical workroom divider" : "Horizontal workroom divider"
      )
      .accessibilityValue("\(Int((ratio * 100).rounded()))%")
      .accessibilityAdjustableAction { direction in
        let step: CGFloat = 0.05
        switch direction {
        case .increment: onRatio(PaneTreeLayout.clampRatio(ratio + step, total: total))
        case .decrement: onRatio(PaneTreeLayout.clampRatio(ratio - step, total: total))
        @unknown default: break
        }
      }
  }
}
