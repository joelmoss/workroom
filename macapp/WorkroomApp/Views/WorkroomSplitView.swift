import AppKit
import SwiftUI

/// Geometry the workroom pane cards share with the chrome AROUND them.
enum WorkroomPaneMetrics {
  /// The clear gutter on every side of a pane card — between the cards of a split, and between a solo
  /// card and the window. Also the sidebars' and inspector's top/bottom card margin
  /// (`SidebarColumn`/`InspectorColumn`), so the three columns' cards start and end on the same lines
  /// rather than each choosing its own inset; they're side by side, so any difference reads as a
  /// misalignment.
  static let gutter: CGFloat = 2
  /// Extra bottom-only margin, ADDED ON TOP of `gutter`, so the window's bottom edge keeps its
  /// original 8pt clearance even though `gutter` itself was tightened. Bottom-only because only the
  /// bottom margin was asked to stay put — the top, inter-pane, and sidebar/inspector side gutters
  /// are meant to shrink. Mirrored into `SidebarColumn`/`InspectorColumn`'s `bottomMargin` (added to
  /// their own `gutter`) so all three columns still end on the same line.
  static let windowBottomMargin: CGFloat = 4
}

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
  /// The app store, threaded to each leaf as a plain (non-observed) reference so the workroom
  /// context menu (issue #112) can read/mutate it WITHOUT subscribing this terminal-hosting view
  /// tree to the whole churny store. NOT `@EnvironmentObject`/`@ObservedObject` on purpose.
  let store: AppStore
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
  /// The gutter holding the pane cards off the left/right sidebars (issue #110). Unconditional since
  /// issue #139 — a solo workroom is a card too. **Shared** because `RootView`'s chip-drop hit-testing
  /// plans against the *unpadded* detail rect and must subtract this, or every drop lands 3pt off the
  /// pane the renderer actually drew (a drop inside the gutter would split with no preview shown).
  static let outerGutter: CGFloat = 3
  private let theme = ThemeService.shared

  /// The divider ratio being dragged right now — held here rather than written to the store on every
  /// mouse-moved tick. `store.setWorkroomSplitRatio` publishes `workroomSplits`, which invalidates
  /// `RootView` and rebuilds every pane (and every pane title bar) at cursor rate; local state keeps
  /// the churn inside this view and commits once on mouse-up. Same pattern as `SidebarColumn`'s
  /// resize handle.
  @State private var liveRatio: (split: UUID, ratio: CGFloat)?

  var body: some View {
    let leaves = layout.tabIDs
    let multi = leaves.count >= 2
    let shown = displayedLayout
    GeometryReader { geo in
      let plan = PaneTreeLayout.plan(shown, in: CGRect(origin: .zero, size: geo.size))
      ZStack(alignment: .topLeading) {
        ForEach(leaves, id: \.self) { sid in
          if let target = resolve(sid), let rect = plan.panes[sid] {
            WorkroomPaneLeaf(
              store: store, sid: sid, target: target, focused: sid == focusedID, multi: multi,
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
          WorkroomSplitDivider(
            orientation: d.orientation, ratio: d.ratio, total: d.total,
            onLive: { liveRatio = (d.id, $0) },
            onCommit: {
              liveRatio = nil
              onSetRatio($0, d.id)
            }
          )
          .frame(width: d.hitRect.width, height: d.hitRect.height)
          .position(x: d.rect.midX, y: d.rect.midY)
        }
        dropHighlight(plan: plan)
      }
      .coordinateSpace(.named(Self.space))
    }
    // Applied outside the GeometryReader so the panes reflow within the inset.
    .padding(.horizontal, Self.outerGutter)
    .padding(.bottom, WorkroomPaneMetrics.windowBottomMargin)
  }

  /// The layout to draw: the stored one, with the in-flight divider ratio overlaid while a drag is
  /// live. Once committed, `liveRatio` clears and the store's own value takes over.
  private var displayedLayout: PaneLayout<SidebarID> {
    guard let liveRatio else { return layout }
    return layout.settingRatio(liveRatio.ratio, forSplit: liveRatio.split)
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

/// One workroom pane: a title bar naming the workroom and carrying its own actions, above the full
/// terminal body, the pair wrapped in a rounded card. Near-identical solo and split since issue #139 —
/// the remove-from-split ✕, its menu item, and the group-drag gesture are `multi`-only, because only a
/// real member has a group to leave or move within; so is the card's focused treatment (`highlighted`),
/// because only a real member has a peer to be picked out from.
private struct WorkroomPaneLeaf: View {
  /// Plain (non-observed) store reference for the group title bar's context menu (issue #112) —
  /// see `WorkroomSplitView.store`. NOT `@EnvironmentObject`: this view hosts a live terminal and
  /// must not re-evaluate on every unrelated store change.
  let store: AppStore
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

  var body: some View {
    // `content` MUST stay at ONE structural position (the second child of this VStack) — the title bar
    // is a *sibling* above it, never a wrapper around it. A structural
    // `if multi { VStack { titleBar; content } } else { content }` would swap SwiftUI's
    // `_ConditionalContent` branch when a 2-member split dissolves to solo, tearing down + rebuilding
    // `TargetTerminalDetail` and re-parenting the libghostty surface — the blank/stranded-pane bug.
    // This mirrors `PaneLeafView`, which keeps its content in one slot and expresses the `multiPane`
    // chrome as always-mounted overlays (issue #3).
    //
    // Since issue #139 the title bar is UNCONDITIONAL, which strengthens that invariant rather than
    // straining it: with no `if` there is no branch left to flip on this axis. The hazard of the same
    // shape that remains is the missing-directory choice, which is why `TargetTerminalDetail` owns it
    // as a ZStack sibling rather than this view branching on it.
    VStack(spacing: 0) {
      // Every workroom is identified by its own header (issue #139), which in a split also names
      // *which* member this is and offers the way back out of the group.
      WorkroomPaneTitleBar(
        target: target, projectPath: projectPath, projectLabel: projectLabel,
        workroomName: workroomName, focused: focused,
        controls: toolbarControls, onClose: onClose
      )
      // Drag the group by its title bar to move the whole member within the split (issue #110) —
      // the SAME gesture/closures the tab-bar chip uses, so it drops onto the same panes and shows
      // the same drop-edge highlight. A plain click (no movement past `minimumDistance`) still
      // falls through to the leaf's focus tap.
      //
      // `including:` MUST be `.subviews` (not `.none`) when solo: `GestureMask.none` disables every
      // gesture in the SUBVIEW hierarchy as well as the added one, which would kill this bar's own
      // Run / Open-in buttons in exactly the single-workroom case issue #139 exists to serve — and
      // `ToolbarIconButtonStyle`'s hover well is `.onHover`, not a gesture, so they would still light
      // up and look alive. `.subviews` drops only the drag.
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
          },
        including: multi ? .all : .subviews
      )
      // The workroom's right-click menu (issue #112) — the SAME items as the tab chip (incl.
      // "Close"). "Remove from Split" (the menu equivalent of the ✕) is offered only for a real
      // member; `workroomContextMenu` drops the item and its divider on a nil closure. `closeName`
      // matches the chip's `workroomName ?? primaryLabel`. Attached AFTER `.gesture` so both share
      // the bar's `.contentShape`; secondary-click (menu) and the primary-button drag coexist.
      // The bar's own controls are separate hit targets, so a right-click landing directly on one may
      // not raise this menu (already true of the ✕ before issue #139 added its neighbours) — the
      // leading label region always does, and that is the region to aim for.
      .contextMenu {
        workroomContextMenu(
          store: store, sid: sid, target: target, closeName: workroomName ?? projectLabel,
          onRemoveFromSplit: multi ? onClose : nil)
      }
      // One unconditional slot. The "Directory not found" state and the withheld-during-setup state
      // both live INSIDE `TargetTerminalDetail`'s own ZStack, so nothing here ever swaps branches.
      TargetTerminalDetail(target: target, surfaceActive: focused)
    }
    // The pane reads as a unit by a subtle raised fill over the `panel` base plus the shadow +
    // rounded corners (issue #110), and is FRAMED by a stroke whose colour carries focus: the focused
    // member takes a full-strength accent frame, the rest a neutral hairline. Its fill stays
    // accent-tinted as the secondary cue — accent @ 0.10 over a `panel` that is itself only 5.5% off
    // the theme background moves luminance by a couple of percent, which was too faint to pick the
    // focused member out of a split at a glance.
    //
    // All three read `highlighted`, NOT `focused`: the accent means "this member, not that one", so a
    // solo pane — always the focused one, since the no-split layout is `.leaf(selected)` — wears the
    // neutral resting card instead. Both layers stay unconditionally MOUNTED (only their values swap);
    // the treatment, not the mounting, is what's split-only.
    .background(WorkroomPaneCardBackground(highlighted: highlighted))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    // Mounted AFTER the clip (so the frame isn't clipped away) and BEFORE the shadow: `strokeBorder`
    // insets by half its width, so the stroke sits inside the card and the shadow's silhouette — and
    // every pane rect — is unchanged.
    .overlay { WorkroomPaneCardBorder(highlighted: highlighted) }
    .shadow(
      color: .black.opacity(highlighted ? 0.18 : 0.10), radius: highlighted ? 6 : 3, y: 2
    )
    // A clear gutter on every side — between the cards of a split, and between a solo card and the
    // window. The title bar sits at the pane's top, inside this inset. Shared with the two sidebar
    // cards' top/bottom margins so all three columns line up.
    .padding(WorkroomPaneMetrics.gutter)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workroom.pane")
    // Roots aren't workrooms — say what this pane actually is (the chip makes the same distinction).
    .accessibilityLabel(
      Text(workroomName.map { "Workroom \($0)" } ?? "Project \(target.title)")
    )
    // Only meaningful with peers to be selected *among*: this trait tracks MODEL focus, and a solo
    // pane reporting `.isSelected` would say nothing while breaking how tests read it.
    .accessibilityAddTraits(focused && multi ? .isSelected : [])
  }

  /// Whether this card wears the focused treatment — derived ONCE here so the frame, the fill and the
  /// shadow cannot disagree about it. Deliberately narrower than `focused`, which still drives the
  /// title bar's colours and `TargetTerminalDetail(surfaceActive:)` (liveness, not emphasis: a solo
  /// pane's own Run / Open-in controls must stay full strength, and its terminal stays active).
  private var highlighted: Bool {
    WorkroomPaneCardBorder.isHighlighted(focused: focused, multi: multi)
  }

  /// The owning project's path. Handed to the title bar (rather than the `sid`) so a presentation view
  /// doesn't take a dependency on `SidebarID`, and so the lookup happens once for both the label and
  /// the run controls' `hasRunCommand` check.
  private var projectPath: String? { AppStore.projectPath(of: sid) }

  /// Which trailing controls the header shows — resolved in one pass so the group's divider can't
  /// disagree with the buttons on either side of it. The editor list is cached, so this is cheap enough
  /// to compute per render.
  private var toolbarControls: WorkroomPaneToolbarPresentation.Controls {
    WorkroomPaneToolbarPresentation.controls(
      isMissing: target.isMissing, projectPath: projectPath,
      hasEditor: !ExternalEditor.installed.isEmpty, multi: multi)
  }

  /// The project name — the chip's primary label format (`AppStore.projectPath` last component),
  /// matching `WorkroomTabChip.primaryLabel`. Empty only if the sid resolves no project.
  private var projectLabel: String {
    projectPath.map { ($0 as NSString).lastPathComponent } ?? ""
  }

  /// This member's own display name (nil for a project root) — the label-aware `target.title`,
  /// resolved through `WorkroomSplitTitlePresentation` so a relabel (issue #41) shows here
  /// immediately. Feeds both the title bar's visible text and its accessibility label (issue #113);
  /// NOT the raw `SidebarID` name, which never changes on relabel.
  private var workroomName: String? {
    WorkroomSplitTitlePresentation.workroomName(sid: sid, target: target)
  }

}

/// The pane card's fill. Its own view rather than an inline `.background(…)` value for two reasons: it
/// reads `\.controlActiveState` so the accent tint drops when the window isn't key (issue #139 — an
/// inactive window holding a saturated accent band reads as active and is against macOS convention),
/// and as a child it absorbs those activation re-renders itself, keeping them off `WorkroomPaneLeaf`
/// and the libghostty surface it hosts.
///
/// Takes `highlighted`, not `focused` — see `WorkroomPaneCardBorder.isHighlighted`.
private struct WorkroomPaneCardBackground: View {
  let highlighted: Bool
  @Environment(\.controlActiveState) private var activeState
  private let theme = ThemeService.shared

  var body: some View {
    ZStack {
      theme.tokens.panel
      activeState == .inactive || !highlighted
        ? theme.tokens.splitGroupFill : theme.tokens.splitGroupFocusedFill
    }
  }
}

/// The pane card's frame — the primary focus cue. Its own view for the same two reasons as
/// `WorkroomPaneCardBackground`: it reads `\.controlActiveState` (so the accent drops on a background
/// window), and as a child it absorbs those activation re-renders instead of passing them to
/// `WorkroomPaneLeaf` and the libghostty surface below it.
///
/// The stroke is ALWAYS mounted and only its colour swaps — the same shape as the terminal pane's ring
/// (`PaneTreeView`) and the dialogs' highlighted rows. A structural `if highlighted` here would add a
/// `_ConditionalContent` branch beside the leaf's content slot, which is the one thing this pane's
/// hierarchy must not do.
struct WorkroomPaneCardBorder: View {
  let highlighted: Bool
  @Environment(\.controlActiveState) private var activeState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let theme = ThemeService.shared

  var body: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .strokeBorder(
        Self.tint(highlighted: highlighted, active: activeState != .inactive, tokens: theme.tokens),
        lineWidth: 1.5
      )
      .allowsHitTesting(false)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.08), value: highlighted)
  }

  /// Whether the card wears the focused treatment at all. Model focus alone isn't enough: a solo pane
  /// is ALWAYS `focused` (the no-split layout is `.leaf(selected)`), and an accent frame/fill with no
  /// peer to be distinguished FROM is decoration rather than a selection cue — it spends the accent
  /// that should mean "this member, not that one". The same expression the `.isSelected` trait uses,
  /// kept pure so the gate is testable without hosting a view. The frame, the fill and the shadow all
  /// read this one value.
  static func isHighlighted(focused: Bool, multi: Bool) -> Bool { focused && multi }

  /// Which colour frames the card. Pure and static (same rationale as `PaneTreeView.shouldDim`) so the
  /// three-way decision is testable without hosting a view. Its input is `isHighlighted`, so a solo
  /// pane takes the same neutral hairline an unfocused member does.
  ///
  /// 1.5pt of `accent` deliberately matches the terminal pane's focus ring rather than the 2pt accent
  /// box of the drag drop-edge highlight in this file, so a focused pane can't be mistaken for a drop
  /// target. On a background window the frame goes neutral (`focused`, fg @ 0.3) rather than holding a
  /// saturated accent — the same convention the card fill follows.
  static func tint(highlighted: Bool, active: Bool, tokens: ThemeTokens) -> Color {
    guard highlighted else { return tokens.border }
    return active ? tokens.accent : tokens.focused
  }
}

/// Which trailing controls a pane title bar offers. Pure and separate from the view (same rationale as
/// `WorkroomSplitTitlePresentation`) so the matrix — a missing directory has nothing to open, a target
/// with no owning project has no run command to look up, and only a real split member can be removed
/// from one — is unit-testable without instantiating SwiftUI.
///
/// It takes the "is there anything to show" facts as inputs rather than letting each control decide for
/// itself, because the group divider depends on **both** its neighbours: a separator with nothing on one
/// side of it is worse than no separator. Deriving every flag here, in one pass, is what makes it
/// impossible for the divider to disagree with the buttons it separates.
enum WorkroomPaneToolbarPresentation {
  struct Controls: Equatable {
    let run: Bool
    let openIn: Bool
    /// The rule between the run group and "Open in…" — only when both are actually there.
    let divider: Bool
    let removeFromSplit: Bool
  }

  static func controls(
    isMissing: Bool, projectPath: String?, hasEditor: Bool, multi: Bool
  ) -> Controls {
    // Run is deliberately NOT gated on a configured command: the button is always there for a present
    // target, and pressing it with nothing configured opens Project Settings with the warning, the same
    // as ⌘R (issue #139 follow-up). It still needs an owning project, since that's what a command would
    // be keyed to. "Open in…" is gated, because with no editor installed there is nowhere to open.
    let run = !isMissing && projectPath != nil
    let openIn = !isMissing && hasEditor
    return Controls(
      run: run, openIn: openIn, divider: run && openIn, removeFromSplit: multi)
  }
}

/// The header atop **every** workroom pane (issue #110 for split members, issue #139 for all of them):
/// a leading identity glyph, the `project / workroom` label (matching the tab chip's format), and a
/// trailing toolbar carrying this workroom's own actions — "Open in…", run/stop/restart, and (for a
/// real split member) the remove-from-split ✕. It spans the pane's full width and, together with the
/// leaf's rounded card, makes each pane read as a distinct, identifiable unit. Reflects focus by colour
/// (accent + full-strength text when focused, muted otherwise), the pane's selection signal.
///
/// The run/open-in controls used to live in the window title bar keyed on the *selected* target, so a
/// co-displayed split member's were unreachable; here each pane owns its own and acts on its own
/// target.
private struct WorkroomPaneTitleBar: View {
  let target: TerminalTarget
  let projectPath: String?
  /// The project name, derived (with `workroomName`) by the leaf — which needs it for the close prompt
  /// anyway, so deriving it a second time here would be two copies of one format to keep in step.
  let projectLabel: String
  let workroomName: String?
  let focused: Bool
  /// Resolved by the leaf, which has the store — this view stays store-free on purpose (see
  /// `WorkroomSplitView.store`).
  let controls: WorkroomPaneToolbarPresentation.Controls
  let onClose: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 6) {
      // Leading glyph mirrors the tab chip's: a house for a project root, a cube for a workroom
      // (`workroomName` is nil only for a root). Accent on the focused pane, muted otherwise.
      Image(systemName: workroomName == nil ? "house" : "cube")
        .font(.system(size: 10))
        .foregroundStyle(focused ? theme.tokens.accent : theme.tokens.fgMuted)
      if target.isMissing {
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
      // The tab chips' cap, so the identity yields to the actions under width pressure instead of
      // squeezing them out of a narrow split member.
      .frame(maxWidth: TabStripMetrics.maxChipTitle, alignment: .leading)
      // The full name and path, for a label the 180pt cap has truncated.
      .help("\(fullTitle)\n\(target.path)")
      Spacer(minLength: 8)
      // This workroom's own actions. `RunControls` reads the store via `@EnvironmentObject`, which
      // invalidates only ITSELF — `WorkroomPaneLeaf` and the terminal it hosts stay unsubscribed from
      // store churn, the invariant `WorkroomSplitView.store` exists for.
      // ONE styled group, so every control in it — including the ✕, which used to style itself — gets
      // the same 22pt well and the same glyph size. The two numbers live on `ToolbarIconButtonStyle`
      // and `PaneToolbarIcon`; nothing here restates them.
      HStack(spacing: 6) {
        if controls.run, let projectPath {
          RunControls(target: target, projectPath: projectPath)
        }
        // Only when there is something on both sides of it — a rule with nothing to separate reads as a
        // stray mark, and either group can be absent (no run command configured, no editor installed).
        if controls.divider { TitlebarDivider() }
        if controls.openIn { OpenInControl(path: target.path) }
        if controls.removeFromSplit {
          TitlebarDivider()
          CloseWorkroomPaneButton(action: onClose)
        }
      }
      .buttonStyle(ToolbarIconButtonStyle())
      .font(.system(size: PaneToolbarIcon.glyph))
      // Recede with the pane, the way the terminal tab strip below already does (`WorkroomTerminalsView`
      // fades to the same 0.45 on `!surfaceActive`): a non-focused member's actions are still there and
      // still clickable — opacity doesn't block hit-testing, which matters for the ✕, the way out of a
      // cramped split — they just stop competing with the focused pane's. Matching curve and duration so
      // the header, the strip, and the per-pane scrim all fade as one.
      .opacity(focused ? 1 : 0.45)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.07), value: focused)
    }
    // Trailing inset is tighter than the leading so the trailing-most control lines up with the
    // terminal tab strip's own toolbar below it (both land 4pt inside the card's trailing edge; the
    // buttons carry their own hit padding).
    .padding(.leading, 10)
    .padding(.trailing, 4)
    .frame(height: 28)
    .frame(maxWidth: .infinity)
    // No own background and no bottom rule — inherit the card's raised lighter fill (issue #110) so the
    // header and the terminal body below read as one continuous surface.
    // So a tap/drag on the bar's empty area is hit-tested: a tap bubbles to the leaf's focus tap and a
    // drag (handled by the leaf's gesture on this bar) moves the group; each button consumes its own
    // click.
    .contentShape(Rectangle())
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workroom.pane.titlebar")
    .accessibilityLabel(
      Text(workroomName.map { "\(projectLabel), workroom \($0)" } ?? projectLabel)
    )
  }

  /// The tooltip's title, formatted by `WorkroomLabel` — the same one the tab chip and a
  /// notification's origin line use. Built from the parts already passed in rather than resolved from
  /// a `SidebarID`, so this presentation view keeps its store/sid independence.
  private var fullTitle: String {
    WorkroomLabel(project: projectLabel, workroom: workroomName).full
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
  /// The in-flight ratio, per mouse-moved tick. The parent parks it in local `@State`; it must NOT
  /// reach the store, whose `@Published` write would rebuild every pane at cursor rate (issue #139).
  let onLive: (CGFloat) -> Void
  /// The final ratio, once, on mouse-up — this is the one that persists.
  let onCommit: (CGFloat) -> Void
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
            onLive(dragged(from: start, by: value.translation))
          }
          // `startRatio` is set by `onChanged`, so a nil one means the gesture never moved — commit
          // nothing rather than republishing the ratio it already has. The final translation comes from
          // this closure's own value; there's no need to mirror each tick into a second `@State`.
          .onEnded { value in
            guard let start = startRatio else { return }
            onCommit(dragged(from: start, by: value.translation))
            startRatio = nil
          }
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
      // A discrete step is already the final value — commit it straight away, no live phase.
      .accessibilityAdjustableAction { direction in
        let step: CGFloat = 0.05
        switch direction {
        case .increment:
          onCommit(PaneTreeLayout.clampRatio(ratio + step, total: total, along: orientation))
        case .decrement:
          onCommit(PaneTreeLayout.clampRatio(ratio - step, total: total, along: orientation))
        @unknown default: break
        }
      }
  }

  /// The ratio a drag of `translation` from `start` lands on — one formula for both gesture phases, so
  /// the committed value can't drift from the live one it followed.
  private func dragged(from start: CGFloat, by translation: CGSize) -> CGFloat {
    let usable = max(1, total - PaneTreeLayout.dividerThickness)
    let delta = orientation == .horizontal ? translation.width : translation.height
    return PaneTreeLayout.clampRatio(start + delta / usable, total: total, along: orientation)
  }
}
