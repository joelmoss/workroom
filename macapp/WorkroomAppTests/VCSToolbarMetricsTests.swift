import XCTest

@testable import Workroom

/// `VCSToolbarMetrics` — the toolbar's geometry, asserted rather than eyeballed.
///
/// Two properties matter and neither is visible in a screenshot: the segments must FIT the inspector's
/// 260pt minimum (below that something clips, and the clipping is what a user sees, not the cause), and
/// the toolbar must align with the section header beneath it by construction rather than by luck.
final class VCSToolbarMetricsTests: XCTestCase {

  /// The inspector's minimum content width. `InspectorColumn` clamps to 260-520 and applies the width to
  /// `RightInspector` before the card's padding, so the toolbar gets exactly this.
  private let inspectorMinWidth: CGFloat = 260

  /// The floors plus both dividers must fit the narrowest inspector. If a future tweak pushes this over,
  /// the toolbar clips at the minimum width — which is the default for anyone who has never dragged the
  /// divider.
  func testSegmentFloorsFitTheNarrowestInspector() {
    let required =
      VCSToolbarMetrics.segmentMinWidth * 2  // branch + sync, equal by construction
      + VCSToolbarMetrics.fetchWidth + 2  // one 1pt divider between each pair
    XCTAssertLessThanOrEqual(
      required, inspectorMinWidth,
      "the three segments need \(required)pt but the inspector can be \(inspectorMinWidth)pt wide")
  }

  /// The toolbar's leading geometry is deliberately identical to `SectionHeader.headerLabel`'s, so the
  /// branch glyph's centre and the branch name's left edge line up with the Changes header's chevron
  /// centre and title. Alignment by construction; this is the assertion that keeps it that way.
  func testLeadingGeometryMatchesTheSectionHeader() {
    // SectionHeader: .padding(.horizontal, 12), chevron .frame(width: 12), HStack(spacing: 7).
    let headerInset: CGFloat = 12
    let headerGlyphSlot: CGFloat = 12
    let headerSpacing: CGFloat = 7

    XCTAssertEqual(VCSToolbarMetrics.outerInset, headerInset)
    XCTAssertEqual(VCSToolbarMetrics.glyphSlot, headerGlyphSlot)
    XCTAssertEqual(VCSToolbarMetrics.glyphSpacing, headerSpacing)

    let glyphCentre = VCSToolbarMetrics.outerInset + VCSToolbarMetrics.glyphSlot / 2
    let textLeadingEdge =
      VCSToolbarMetrics.outerInset + VCSToolbarMetrics.glyphSlot + VCSToolbarMetrics.glyphSpacing
    XCTAssertEqual(glyphCentre, 18, "glyph centre must sit where the header's chevron centre does")
    XCTAssertEqual(textLeadingEdge, 31, "text must start where the header's title does")
  }

  /// 11pt semibold (13pt line) + 1pt + 10pt (12pt line) = 26, plus 5pt above and below. The section
  /// headers are 34pt, which two lines don't fit — so this must be taller than them, not equal.
  func testHeightFitsTwoLinesAndExceedsASectionHeader() {
    XCTAssertGreaterThan(
      VCSToolbarMetrics.height, InspectorPanePolicy.headerHeight,
      "two stacked lines don't fit a section header's height")
    XCTAssertEqual(VCSToolbarMetrics.height, 36)
  }

  /// The fetch cell has to hold a standard 22pt hover well.
  func testFetchCellFitsAStandardWell() {
    XCTAssertGreaterThanOrEqual(
      VCSToolbarMetrics.fetchWidth, ToolbarIconButtonStyle.wellSize,
      "the fetch glyph's well would overflow its cell")
  }

  /// The branch and sync cells are equal width, which only holds if they share ONE floor — an `HStack`
  /// divides slack evenly, so two different minimums stay different by their gap at every width. A single
  /// constant is what makes that true by construction, and this asserts nothing reintroduces a second one.
  ///
  /// It also has to leave the fetch cell room: with equal halves the floor is bounded above by
  /// `(inspectorMin − fetchWidth − dividers) / 2`, so this is the tight version of the sum test above.
  func testBranchAndSyncShareOneFloorThatLeavesRoomForFetch() {
    let available = inspectorMinWidth - VCSToolbarMetrics.fetchWidth - 2
    XCTAssertLessThanOrEqual(
      VCSToolbarMetrics.segmentMinWidth, available / 2,
      "two equal segments of \(VCSToolbarMetrics.segmentMinWidth)pt don't fit \(available)pt")
    XCTAssertGreaterThan(
      VCSToolbarMetrics.segmentMinWidth, VCSToolbarMetrics.fetchWidth,
      "a text segment squeezed below the icon cell's width would be unreadable")
  }

  /// Pill geometry is copied from `PRNumberBadge` so the toolbar's count pill matches the ref pill in the
  /// Changes header ~40pt below it. Two pills that nearly match read worse than two that differ clearly.
  func testPillGeometryMatchesThePRBadge() {
    XCTAssertEqual(VCSToolbarMetrics.pillHorizontalPadding, 5)
    XCTAssertEqual(VCSToolbarMetrics.pillVerticalPadding, 1)
  }
}
