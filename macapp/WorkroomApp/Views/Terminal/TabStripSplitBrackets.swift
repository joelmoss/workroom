import SwiftUI

/// A rounded *outline* bracketing EACH split group's contiguous chip run, so it's easy to see which
/// tabs are grouped/split (issue #3) — including a group that isn't the one on screen, since groups
/// persist while you look at a tab outside them. Shared by the terminal strip (`TerminalTabStrip`)
/// and the Workrooms tab bar (`WorkroomTabBar`), each placing it behind its chip run with
/// `.background(alignment: .leading)` and hiding it during a drag. Deliberately an outline, not a
/// filled backing: a fill occupies the same channel as the active-chip fill, so any visible strength
/// made a grouped-but-inactive chip read as focused. The border groups without competing with
/// selection.
///
/// The `ZStack(alignment: .leading)` is load-bearing and NOT redundant with the caller's
/// `.background(alignment: .leading)`: that alignment places the background *content as a whole*,
/// and several `ForEach` brackets are wrapped in an implicit stack whose own alignment is the
/// default `.center` — so every bracket narrower than the widest one was centred inside it and drawn
/// `(widest − mine) / 2` too far right, while the widest one alone landed correctly. With one group
/// (all a strip could hold before several groups) the sole bracket *was* the widest, so the fault
/// was invisible until then. `TabStripSplitRun.rect` was right all along — each `run.x` is relative
/// to the first chip's leading edge, which is what this stack restores as every bracket's origin.
struct TabStripSplitBrackets: View {
  /// Each group's run, from `TabStripSplitRun.rects`.
  let runs: [(x: CGFloat, width: CGFloat)]
  /// Bracket `i`'s accessibility identifier is `"\(identifierPrefix).\(i)"`.
  let identifierPrefix: String
  @Environment(\.themeTokens) private var tokens

  /// The brackets of the strip whose chips are `ids` in display order (`TabStripSplitRun.rects`).
  init<ID: Hashable>(
    ids: [ID], width: (ID) -> CGFloat, groupOf: [ID: Int], spacing: CGFloat,
    identifierPrefix: String
  ) {
    runs = TabStripSplitRun.rects(ids: ids, width: width, groupOf: groupOf, spacing: spacing)
    self.identifierPrefix = identifierPrefix
  }

  var body: some View {
    ZStack(alignment: .leading) {
      ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(tokens.border, lineWidth: 1)
          .frame(width: run.width)
          .offset(x: run.x)
          // A frame XCUITest can read, so the misalignment above is testable at all — a stroked
          // shape is otherwise invisible to it, and the arithmetic was never the faulty half. Kept
          // OUT of the a11y tree in a normal run (`accessibilityHidden`): it's pure decoration, and
          // VoiceOver users get the grouping from each chip's own label. Same fixture-gated handle
          // idea as `PaneTreeView`'s single-pane `.isSelected`.
          .accessibilityElement()
          #if DEBUG
            .accessibilityHidden(!AppEnvironment.current.isFixture)
          #else
            .accessibilityHidden(true)
          #endif
          .accessibilityIdentifier("\(identifierPrefix).\(index)")
      }
    }
  }
}
