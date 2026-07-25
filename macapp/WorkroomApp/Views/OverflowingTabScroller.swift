import SwiftUI

// The overflow *scaffolding* for the two horizontal tab strips — the terminal strip
// (`TerminalTabStrip`) and the Workrooms tab bar (`WorkroomTabBar`, issue #129). One home for the
// wiring, not just the numbers: `TabReorderMath.swift` shares the constants and the predicate, but the
// assembly around them is where the traps are, and a wrong modifier order in one strip was invisible
// from the other. This owns all three width measurements, the inline↔pinned decision, the trailing
// alpha ramp, and the load-bearing modifier order, so neither strip hand-maintains any of it.

/// The scrolling chip run, plus the trailing controls in whichever position the overflow state calls
/// for (issue #129): inline, hugging the last chip, while everything fits; lifted out of the scroller
/// and pinned at its trailing edge once it doesn't, so they can never be scrolled out of reach.
///
/// Always a `ScrollView` — in BOTH states — so no chip ever changes branch: their hover state, open
/// popovers, `RunningUnderline` animations and any in-flight `DragGesture` all survive a flip, and
/// the dragged chip's `.offset` stays clipped to the strip. Only the controls' position and the mask's
/// ramp colour change, which are value changes (matching the "always-applied, value-only" convention
/// in `WorkroomSplitView`).
struct OverflowingTabScroller<Content: View, Controls: View, ScrollID: Hashable>: View {
  /// The scrolling row's leading inset (4pt in a workroom split, else 8pt) — applied to the row AND
  /// charged to the overflow predicate, which measures the whole *inline* layout.
  let leadingInset: CGFloat
  /// The row's spacing: between the chip run and the inline controls, and (as `spacing + inlineLead`)
  /// the inline gap the predicate charges for.
  let spacing: CGFloat
  /// The *inline* controls' own leading pad, applied here rather than by the control itself so their
  /// measured width stays a pure intrinsic measurement — identical inline or pinned. The terminal
  /// strip's "+" hugs the last chip with `TabStripMetrics.inlineAddLead`; the workroom bar's block adds
  /// no pad of its own, so it passes 0.
  let inlineLead: CGFloat
  /// The currently selected chip's `.id()` (issue #129 follow-up): scrolled into view whenever it
  /// changes, so a selection made off-screen — ⌘1-9, ⌥⌘1-9, a cycle shortcut, a sidebar tap,
  /// close-reselection, new-tab creation, surface-focus routing — doesn't swap the pane with no
  /// visible feedback. Deliberately no default: with nothing to infer `ScrollID` from, it would be
  /// ambiguous at the call site, and both strips always have a real selection to pass.
  let scrollTarget: ScrollID?
  /// True while a chip drag is in flight, so the container skips the scroll — the drag already moves
  /// the run, and scrolling under the user's cursor would fight it.
  let scrollSuspended: Bool
  /// The scrolling chip run, built against the current overflow state: both strips drop the hairline
  /// that sets the trailing controls apart once those controls pin — the fade and the gutter already
  /// separate the two regions, and a hairline beside a dissolving edge reads as a cut.
  private let content: (Bool) -> Content
  /// The trailing controls — ONE view, rendered inline or pinned, never a pair. The same view in both
  /// positions is what makes a single measured width valid either way, which in turn is what keeps the
  /// predicate branch-independent.
  private let controls: () -> Controls
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    leadingInset: CGFloat, spacing: CGFloat, inlineLead: CGFloat,
    scrollTarget: ScrollID?, scrollSuspended: Bool,
    @ViewBuilder content: @escaping (Bool) -> Content,
    @ViewBuilder controls: @escaping () -> Controls
  ) {
    self.leadingInset = leadingInset
    self.spacing = spacing
    self.inlineLead = inlineLead
    self.scrollTarget = scrollTarget
    self.scrollSuspended = scrollSuspended
    self.content = content
    self.controls = controls
  }

  // Overflow measurements (issue #129). Each is read from something that CANNOT change as a result of
  // the decision it feeds, which is what makes the inline↔pinned choice unable to oscillate on resize:
  //
  //   chipRunWidth ──┐
  //   controlsWidth ─┼─► TabStripOverflow.pinsControls ─► inline controls | pinned controls + fade
  //   availableWidth ┘
  //
  /// Natural width of the chip run — measured INSIDE the scroller, so it's the content's width and not
  /// the viewport's. Includes the strips' trailing divider, which is toggled by opacity and so always
  /// laid out.
  @State private var chipRunWidth: CGFloat = 0
  /// The controls' own intrinsic width, measured before any positioning pad — identical inline or
  /// pinned.
  @State private var controlsWidth: CGFloat = 0
  /// Width available to the chip run + controls: the allocation this view's parent granted it (read
  /// after the `.frame(maxWidth: .infinity)` below, never before — see there). Crucially it does NOT
  /// change when the controls pin — `safeAreaInset` reduces the scroller's safe area, not its frame —
  /// so feeding it back into the predicate can't create a layout feedback loop.
  @State private var availableWidth: CGFloat = 0

  /// Whether the chips no longer fit with the controls inline, so they pin at the trailing edge and the
  /// scroller takes its fade (issue #129). See `TabStripOverflow.pinsControls` for why this can't
  /// oscillate. The inline gap is the row's spacing plus the controls' own pad.
  private var overflowing: Bool {
    TabStripOverflow.pinsControls(
      runWidth: chipRunWidth, add: controlsWidth, available: availableWidth,
      leadingInset: leadingInset, inlineAddLead: spacing + inlineLead)
  }

  var body: some View {
    // The reader wraps the WHOLE scroller so `proxy` is in scope for the `.onChange` below, which is
    // appended at the end of the chain — after every load-bearing modifier — so it can't perturb their
    // order (see the comments on each below; that order is the trap this file exists to guard).
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: spacing) {
          content(overflowing)
            .onGeometryChange(
              for: CGFloat.self, of: { $0.size.width }, action: { chipRunWidth = $0 })
          // Fits: the controls stay inline, hugging the last chip — today's look, unchanged.
          if !overflowing { measuredControls.padding(.leading, inlineLead) }
        }
        .padding(.leading, leadingInset)
      }
      // The scroll content's trailing inset, as a *content margin* rather than padding inside the row:
      // padding inside the content only manifests once you've scrolled to the very end, which is
      // exactly why a clipped chip used to abut the toolbar (issue #129). Sized to the fade so at full
      // scroll-end the ramp lands on this empty margin and the last chip renders crisp.
      .contentMargins(.trailing, TabStripMetrics.fade, for: .scrollContent)
      // Hug the chips' height; otherwise the horizontal ScrollView grabs all the vertical slack when
      // there's nothing below it (the terminal strip's empty state), ballooning the bar — and it's
      // what lets the title-bar HStack centre the workroom bar on the traffic-light line.
      .fixedSize(horizontal: false, vertical: true)
      // BEFORE the `safeAreaInset` below, always: masking *after* it would let the ramp dissolve the
      // pinned control itself.
      .mask { trailingFade }
      // `mask` composites away hit testing in its transparent region, so restore the full-rect
      // interaction shape — a partially faded chip must keep its tap/close/drag targets.
      .contentShape(.interaction, Rectangle())
      // Overflowing: the controls lift OUT of the scroller and pin here, always visible (issue #129).
      // `safeAreaInset` both places them and *reserves* their width, so the chips stop before them
      // rather than sliding underneath (the idiom's documented behaviour — see `ProjectSidebar`'s
      // footer), and `spacing:` is the gutter, so there's no second constant to keep in sync with
      // their width.
      .safeAreaInset(edge: .trailing, spacing: TabStripMetrics.gutter) {
        if overflowing { measuredControls }
      }
      // Take the whole allocation the parent offers, chips left-aligned, so the width read below is
      // that allocation. The workroom bar has always had this (it fills the gap between the title
      // bar's leading and trailing controls); for the terminal strip it should be a no-op, since its
      // scroller is already the flexible sibling of the `fixedSize()` per-tab toolbar — but that is
      // UNVERIFIED, and `TabStripOverflowUITests.testAddButtonStaysInlineWhenTabsFit` /
      // `testPinnedAddButtonKeepsGutterFromToolbar` are what gate it. If either regresses, parameterise
      // this frame per strip rather than reordering anything else in this chain.
      .frame(maxWidth: .infinity, alignment: .leading)
      // Read AFTER the inset and the frame: `safeAreaInset` doesn't change the modified view's frame,
      // so this is the width the parent granted the chips + controls either way — the
      // branch-independent input the predicate needs. Read before the frame it would report the ideal
      // content width, so overflow would never fire (a silent failure, and one that has actually been
      // written).
      .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { availableWidth = $0 })
      // Scroll the selected chip into view (issue #129 follow-up). Every selection path — ⌘1-9,
      // ⌥⌘1-9, the cycle shortcuts, chip taps, sidebar taps, close-reselection, new-tab creation, and
      // surface-focus routing — funnels through one write (`TerminalSessions.setFocused` /
      // `AppStore.selectedTargetID`), so this one `.onChange` sees all of them. Skipped mid-drag
      // (`scrollSuspended`): a reorder drag already moves the run, and scrolling under the cursor
      // would fight it. Duration matches the reorder gap's `.easeInOut(duration: 0.18)` so a selection
      // that also reorders reads as one motion, not two.
      .onChange(of: scrollTarget) { _, newValue in
        guard let newValue, !scrollSuspended else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
          proxy.scrollTo(newValue, anchor: .center)
        }
      }
    }
  }

  /// The trailing controls carrying the width measurement the predicate reads. Attached outside the
  /// control but INSIDE the inline positioning pad, so the number excludes that pad and is therefore
  /// the same in both positions.
  private var measuredControls: some View {
    controls()
      .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { controlsWidth = $0 })
  }

  /// The alpha ramp over the scroller's trailing edge, so a clipped chip DISSOLVES instead of being cut
  /// mid-glyph (issue #129). ALWAYS applied — only the ramp's end colour changes with `overflowing` —
  /// so switching states is a value change, not a structural one, and no chip loses its identity. The
  /// leading `Rectangle` fills the rest of the frame: anything *outside* a mask's bounds reads as alpha
  /// 0, so this has to be a filling shape and not a bare gradient.
  ///
  /// A mask rather than a painted scrim because the strip's backdrop isn't one flat colour: solo it's
  /// `tokens.panel`, but in a workroom split it's panel *plus* the group fill (accent-tinted when
  /// focused, `WorkroomSplitView`), and `WorkroomTerminalsView` fades the whole strip to 0.45 opacity
  /// for a backgrounded pane — a scrim would go translucent along with the chip it's meant to hide.
  private var trailingFade: some View {
    HStack(spacing: 0) {
      Rectangle()
      LinearGradient(
        colors: [.black, overflowing ? .clear : .black],
        startPoint: .leading, endPoint: .trailing
      )
      .frame(width: TabStripMetrics.fade)
    }
  }
}
