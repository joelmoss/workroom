import CoreGraphics

// Pure geometry for the two horizontal tab strips — the terminal strip (`TerminalTabStrip`) and the
// Workrooms tab bar (`WorkroomTabBar`). Everything here is view-free so it's unit-testable, and
// shared so the two strips can't drift: drag-to-reorder (`TabReorder`, issue #23), the
// overflow/pinning decision and its constants (`TabStripOverflow` / `TabStripMetrics`, issue #129),
// and the split-group bracket's geometry (`TabStripSplitRun`).

/// Pure drag-to-reorder math, shared by the terminal tab strip (`TerminalTabStrip`) and the
/// Workrooms tab bar (`WorkroomTabBar`, issue #23). Lifted out of `TerminalTabStrip` so the index
/// resolution and gap offsets are unit-testable without a view, and the two strips can't drift.
///
/// Operates on **position-indexed** chip widths (`widths[i]` is the natural width of the chip at
/// position `i`), so it's agnostic to what the chips are — terminal tabs (`UUID`) or workroom
/// targets (`String`). The caller maps its own model to a `[CGFloat]` before calling.
enum TabReorder {
  /// Where the dragged chip lands given its current translation: walk outward from `draggedIndex`,
  /// crossing each neighbour once the drag passes that neighbour's half-width (chip width +
  /// `spacing`). Reaches index 0 and the last slot.
  static func dropTargetIndex(
    widths: [CGFloat], draggedIndex di: Int, translation: CGFloat, spacing: CGFloat
  ) -> Int {
    var idx = di
    if translation > 0 {
      var accumulated: CGFloat = 0
      var j = di + 1
      while j < widths.count {
        let span = widths[j] + spacing
        if translation > accumulated + span / 2 {
          idx = j
          accumulated += span
          j += 1
        } else {
          break
        }
      }
    } else if translation < 0 {
      var accumulated: CGFloat = 0
      var j = di - 1
      while j >= 0 {
        let span = widths[j] + spacing
        if -translation > accumulated + span / 2 {
          idx = j
          accumulated += span
          j -= 1
        } else {
          break
        }
      }
    }
    return idx
  }

  /// Horizontal shift for a non-dragged chip at `index` so the row opens a gap at the drop `target`.
  /// `amount` is the dragged chip's width plus inter-chip spacing.
  static func gapShift(index: Int, draggedIndex: Int?, target: Int?, amount: CGFloat) -> CGFloat {
    guard let di = draggedIndex, let ti = target else { return 0 }
    if di < ti, index > di, index <= ti { return -amount }  // dragging right: slide left
    if di > ti, index >= ti, index < di { return amount }  // dragging left: slide right
    return 0
  }
}

/// Shared drag-to-reorder STATE for a horizontal tab strip (issue #23), generic over the chip
/// identity type (`TerminalTab.ID` for `TerminalTabStrip`, `SidebarID` for `WorkroomTabBar`) — the
/// stateful choreography around `TabReorder`'s pure math, which had drifted into two
/// hand-synchronized copies. Both strips independently discovered and fixed the SAME bug: `commit`
/// must resolve off the gesture's own final translation, never the live `translation` this type
/// tracks for rendering, because a fast/coarse drag's last `onChanged` sample can land short of
/// `onEnded`'s true displacement. Each strip owns one `@State private var drag = TabReorderDrag<ID>()`
/// and supplies its own commit action and drop-into-pane wiring as call-site closures — the
/// division of labor `TabReorder` already uses successfully. Reorder-clamping (`WorkroomTabBar`'s
/// `clampReorder`, absent in `TerminalTabStrip`) stays a call-site transform on `finalTranslation`/
/// `translation`, not a flag on this type.
struct TabReorderDrag<ID: Hashable> {
  /// The chip currently dragging, or nil.
  private(set) var id: ID?
  /// Live translation for the render-time gap preview — NOT what `commit` resolves against.
  private(set) var translation: CGFloat = 0
  private(set) var widths: [ID: CGFloat] = [:]

  var isDragging: Bool { id != nil }

  /// The dragged chip's own measured width, or 0 while nothing is dragging / unmeasured.
  var draggedWidth: CGFloat { id.flatMap { widths[$0] } ?? 0 }

  mutating func setWidths(_ widths: [ID: CGFloat]) { self.widths = widths }

  /// `DragGesture.onChanged` handler: latches `id` on the first call for this drag (subsequent
  /// calls for a different id are ignored — mirrors both strips' `if draggingID == nil` guard),
  /// then records the live translation for the render pass.
  mutating func update(_ chipID: ID, translation: CGFloat) {
    if id == nil { id = chipID }
    guard id == chipID else { return }
    self.translation = translation
  }

  /// Where the dragged chip would land right now, for the render-time gap preview. `nil` while
  /// nothing is dragging, the dragged id isn't present in `ids`, or `suspendedByPaneDrag` is true
  /// (a chip dragged down into a pane stops opening a reorder gap).
  func dropIndex(ids: [ID], spacing: CGFloat, suspendedByPaneDrag: Bool) -> Int? {
    guard !suspendedByPaneDrag, let id, let di = ids.firstIndex(of: id) else { return nil }
    return TabReorder.dropTargetIndex(
      widths: ids.map { widths[$0] ?? 0 }, draggedIndex: di, translation: translation,
      spacing: spacing)
  }

  /// Resolve + clear the drag on drop. `finalTranslation` must be the gesture's own final value
  /// (`onEnded`'s `value.translation`), never `translation` above — see the type's doc. Returns
  /// the reorder to perform (`from`/`to` position indices), or `nil` when nothing was dragging or
  /// the drop index didn't move (a caller that always wants to call its move action anyway can
  /// ignore the nil case and use `id`/`ids.firstIndex(of:)` itself, but neither strip needs that).
  mutating func commit(ids: [ID], spacing: CGFloat, finalTranslation: CGFloat) -> (
    from: Int, to: Int
  )? {
    defer {
      id = nil
      translation = 0
    }
    guard let id, let di = ids.firstIndex(of: id) else { return nil }
    let ti = TabReorder.dropTargetIndex(
      widths: ids.map { widths[$0] ?? 0 }, draggedIndex: di, translation: finalTranslation,
      spacing: spacing)
    return ti != di ? (di, ti) : nil
  }

  /// Clear the drag without resolving a reorder (e.g. dropped into a pane instead).
  mutating func cancel() {
    id = nil
    translation = 0
  }
}

/// Geometry both tab strips must agree on (issue #129). One home, because the title-bar Workrooms bar
/// and the terminal strip are on screen at the same time — a fade or gutter that differs between them
/// is directly comparable, so a per-view copy of these numbers would drift visibly.
enum TabStripMetrics {
  /// Gap between the scrolling chip run and the pinned trailing controls, so a clipped chip never
  /// abuts them. Passed as the `spacing:` of the controls' `safeAreaInset`, which also *reserves* the
  /// controls' own width — so this is the only hand-set number in that relationship.
  static let gutter: CGFloat = 8
  /// Width of the dissolve at the scroller's trailing edge, so a clipped chip fades out instead of
  /// being cut mid-glyph. Deliberately equal to the scroll content's trailing inset: at full
  /// scroll-end the ramp then lands on empty margin and the last chip renders crisp, so the fade only
  /// ever dissolves content that really is cut off.
  static let fade: CGFloat = 8
  /// The *inline* "+"'s own leading pad (it hugs the last chip). Applied by the call site, not by the
  /// button, so the button's measured width stays free of positioning padding.
  static let inlineAddLead: CGFloat = 2
  /// Sub-pixel slack in the overflow comparison, so a live window resize can't thrash the mode on
  /// rounding alone.
  static let epsilon: CGFloat = 0.5
  /// Widest a chip's title renders before it tail-truncates (the ellipsis + tooltip carry the rest).
  /// One number for both strips *and* the workroom pane header, which deliberately matches them: all
  /// three can be on screen at once, so a per-view copy — this was three, each cross-referenced only by
  /// comment — is directly comparable and drifts visibly. Note a workroom chip spends it on two names
  /// (project + workroom) against a terminal chip's one, so it starts truncating sooner.
  static let maxChipTitle: CGFloat = 180
}

/// The overflow decision for a horizontal tab strip (issue #129): does the *inline* layout — the chip
/// run with the "+" hugging the last chip — still fit the width available to it? When it doesn't, the
/// trailing controls lift out of the scroller and pin at its trailing edge, so the "+" is always
/// reachable.
enum TabStripOverflow {
  /// Natural width of a chip run: every chip plus the inter-chip spacing.
  static func runWidth(_ widths: [CGFloat], spacing: CGFloat) -> CGFloat {
    guard !widths.isEmpty else { return 0 }
    return widths.reduce(0, +) + spacing * CGFloat(widths.count - 1)
  }

  /// Whether the trailing controls must pin.
  ///
  /// Takes **only** quantities that are independent of where those controls currently sit, so the
  /// answer cannot depend on the layout it selects: the predicate has one fixed point and cannot
  /// oscillate as the window resizes. There is deliberately no `isPinned` parameter — a
  /// "scroll content vs viewport" comparison *would* oscillate, because lifting the controls out
  /// shrinks the content and the viewport by different amounts, leaving a band of widths that pins,
  /// then fits, then pins.
  ///
  /// - Parameters:
  ///   - runWidth: measured width of the whole chip run **including the trailing divider and its
  ///     pads** — the divider lives inside the measured run and is toggled by opacity, never removed,
  ///     so it is always laid out. Passing a chips-only width would let the boundary tests pass while
  ///     the rendered threshold sits a few points off.
  ///   - add: the trailing controls' intrinsic width, without any positioning pad.
  ///   - available: width the strip has for the chips + controls (its own width minus any
  ///     fixed-size sibling such as the per-tab toolbar).
  ///   - leadingInset: the row's leading inset (4pt in a workroom split, else 8pt).
  ///   - inlineAddLead: gap between the run and the controls while inline (spacing + their own pad).
  static func pinsControls(
    runWidth: CGFloat, add: CGFloat, available: CGFloat,
    leadingInset: CGFloat, inlineAddLead: CGFloat, gutter: CGFloat = TabStripMetrics.gutter,
    epsilon: CGFloat = TabStripMetrics.epsilon
  ) -> Bool {
    // Nothing measured yet (first layout pass): render inline. Every input is branch-independent, so
    // the correction that follows happens exactly once — it can't become a loop.
    guard available > 0, runWidth > 0, add > 0 else { return false }
    let inlineWidth = leadingInset + runWidth + inlineAddLead + add + gutter
    return inlineWidth > available + epsilon
  }
}

/// Geometry of a split group's contiguous chip run within a strip — the `x`/`width` of the rounded
/// bracket drawn around the members (issue #3). Lifted out of `TerminalTabStrip.splitRunRect` so the
/// arithmetic is unit-testable without a view, and so it shares one summation with
/// `TabStripOverflow.runWidth` instead of carrying a second copy of it.
enum TabStripSplitRun {
  /// - Parameters:
  ///   - widths: position-indexed chip widths (`widths[i]` is the chip at position `i`).
  ///   - memberIndices: positions of the group's members. Guaranteed contiguous by the caller's
  ///     display order; only the first and last are used, so a stray gap is spanned rather than
  ///     rejected.
  ///   - spacing: the strip's inter-chip spacing.
  /// - Returns: `nil` when there's no real split (fewer than two members) or the indices are out of
  ///   range — both mean "draw no bracket".
  static func rect(widths: [CGFloat], memberIndices: [Int], spacing: CGFloat)
    -> (x: CGFloat, width: CGFloat)?
  {
    guard memberIndices.count >= 2,
      let first = memberIndices.min(), let last = memberIndices.max(),
      first >= 0, last < widths.count
    else { return nil }
    // x: everything before the first member, chips + the spacing that follows each of them.
    var x: CGFloat = 0
    for i in 0..<first { x += widths[i] + spacing }
    // width: the members' own chips, plus the spacing *between* them (one fewer gap than chips).
    var width: CGFloat = 0
    for i in first...last { width += widths[i] }
    width += spacing * CGFloat(last - first)
    return (x, width)
  }
}
