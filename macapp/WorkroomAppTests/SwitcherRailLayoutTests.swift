import AppKit
import XCTest

@testable import Workroom

/// The rail's geometry and contrast decisions (issue #132, T11 — D9, D14, D15). Pure, so the things
/// that fail *silently* on someone else's display or theme are pinned here rather than eyeballed.
final class SwitcherRailLayoutTests: XCTestCase {

  private typealias L = SwitcherRailLayout

  // MARK: Card width (D9)

  func testCardsStayComfortableWhileTheyFit() {
    XCTAssertEqual(L.cardWidth(count: 3, available: 1100), L.maxCardWidth, "room to spare ⇒ 200pt")
  }

  func testCardsShrinkTowardsTheFloorAsTheCountGrows() {
    let wide = L.cardWidth(count: 9, available: 1100)
    let tight = L.cardWidth(count: 10, available: 1100)
    XCTAssertLessThan(tight, wide, "more cards ⇒ narrower cards, before any scrolling")
    XCTAssertLessThanOrEqual(wide, L.maxCardWidth)
  }

  func testCardWidthNeverGoesBelowTheFloor() {
    // The floor exists so the densest state never becomes the least readable one — the original 140pt
    // side-by-side card left ~36pt of label, which fragmented every name.
    for count in [12, 20, 40, 200] {
      XCTAssertEqual(
        L.cardWidth(count: count, available: 1100), L.minCardWidth,
        "\(count) cards must shrink to the floor and then scroll, never past it")
    }
  }

  func testTheFloorLeavesAUsableLabelWidth() {
    XCTAssertEqual(L.minCardWidth, 104)
    // Stacked cards give the label the FULL card width (the well is above it, not beside it), so only
    // the horizontal padding comes off — which is why the card could shrink from 180 to 104 and still
    // hold MORE label than before.
    let label = L.minCardWidth - 6 * 2
    XCTAssertGreaterThan(label, 80, "a 12pt name needs real width")
    XCTAssertGreaterThan(
      label, L.maxCardWidth - L.wellSize.width - 30,
      "the stacked label beats what a side-by-side card of the same width would give it")
  }

  func testStackingRoughlyDoubledHowManyCardsFit() {
    // The reason for the layout change: at the old 200pt a 1100pt rail held 5 cards, and it now holds 8.
    let viewport: CGFloat = 1100
    let fits = Int((viewport - L.railPadding * 2) / (L.maxCardWidth + L.cardSpacing))
    XCTAssertGreaterThanOrEqual(fits, 8, "the whole point of stacking was horizontal room")
  }

  // MARK: Panel width — snug, so the cards read as centred

  func testThePanelIsOnlyAsWideAsItsCards() {
    let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let panel = L.panelWidth(count: 4, visibleFrame: visible)
    let expected = L.contentWidth(
      count: 4, cardWidth: L.cardWidth(count: 4, available: L.viewportWidth(visibleFrame: visible)))
    XCTAssertEqual(
      panel, expected, "sizing the panel to the viewport made 4 cards look left-aligned")
    XCTAssertLessThan(panel, L.viewportWidth(visibleFrame: visible))
  }

  func testThePanelTakesTheWholeViewportOnceCardsOverflow() {
    let visible = CGRect(x: 0, y: 0, width: 1200, height: 900)
    let viewport = L.viewportWidth(visibleFrame: visible)
    XCTAssertEqual(
      L.panelWidth(count: 40, visibleFrame: visible), viewport,
      "past the floor the row scrolls inside a full-width panel")
  }

  func testASingleCardGetsASnugPanel() {
    let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let panel = L.panelWidth(count: 1, visibleFrame: visible)
    XCTAssertEqual(panel, L.maxCardWidth + L.railPadding * 2)
  }

  func testCardWidthWithNoCards() {
    XCTAssertEqual(L.cardWidth(count: 0, available: 1100), L.maxCardWidth, "no division by zero")
  }

  // MARK: Overflow (D9)

  func testFewCardsDoNotScroll() {
    XCTAssertFalse(L.scrolls(count: 3, available: 1100))
  }

  func testManyCardsScrollRatherThanWrapping() {
    XCTAssertTrue(
      L.scrolls(count: 40, available: 1100),
      "past the floor the single row scrolls — never a second row")
  }

  func testContentWidthCountsGapsAndPadding() {
    let width = L.contentWidth(count: 3, cardWidth: 200)
    XCTAssertEqual(width, 200 * 3 + L.cardSpacing * 2 + L.railPadding * 2)
    XCTAssertEqual(L.contentWidth(count: 0, cardWidth: 200), 0)
  }

  // MARK: Viewport (D15)

  func testViewportIsCappedOnAWideDisplay() {
    let ultrawide = CGRect(x: 0, y: 0, width: 5120, height: 1440)
    XCTAssertEqual(
      L.viewportWidth(visibleFrame: ultrawide), L.maxViewportWidth,
      "the rail must not stretch the full width of a very wide display")
  }

  func testViewportShrinksToFitASmallDisplay() {
    let small = CGRect(x: 0, y: 0, width: 800, height: 600)
    XCTAssertEqual(L.viewportWidth(visibleFrame: small), 800 - L.screenMargin * 2)
  }

  func testViewportNeverGoesBelowOneCard() {
    let sliver = CGRect(x: 0, y: 0, width: 120, height: 400)
    XCTAssertEqual(L.viewportWidth(visibleFrame: sliver), L.minCardWidth)
  }

  // MARK: Placement (D15)

  func testPanelCentresOnTheKeyWindowNotTheScreen() {
    let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    // An off-centre window (Stage Manager, a window shoved to one side): the rail follows it.
    let window = CGRect(x: 1400, y: 300, width: 400, height: 400)
    let size = CGSize(width: 600, height: 120)
    let origin = L.panelOrigin(size: size, windowFrame: window, visibleFrame: visible)
    XCTAssertEqual(origin.x + size.width / 2, window.midX, accuracy: 0.5)
    XCTAssertEqual(origin.y + size.height / 2, window.midY, accuracy: 0.5)
  }

  func testPanelIsClampedBackInsideTheVisibleFrame() {
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
    // Window near the right edge: centring on it would hang the rail off-screen.
    let window = CGRect(x: 900, y: 700, width: 200, height: 200)
    let size = CGSize(width: 600, height: 120)
    let origin = L.panelOrigin(size: size, windowFrame: window, visibleFrame: visible)
    XCTAssertLessThanOrEqual(
      origin.x + size.width, visible.maxX - L.screenMargin + 0.5, "kept inside the right edge")
    XCTAssertLessThanOrEqual(origin.y + size.height, visible.maxY - L.screenMargin + 0.5)
    XCTAssertGreaterThanOrEqual(origin.x, visible.minX + L.screenMargin - 0.5)
  }

  func testPanelRespectsAMenuBarInsetVisibleFrame() {
    // `visibleFrame` on a notched display starts above 0 and stops below the menu bar — the origin
    // must be expressed in those coordinates, not the full screen's.
    let visible = CGRect(x: 0, y: 60, width: 1512, height: 900)
    let window = CGRect(x: 0, y: 60, width: 1512, height: 900)
    let size = CGSize(width: 800, height: 120)
    let origin = L.panelOrigin(size: size, windowFrame: window, visibleFrame: visible)
    XCTAssertGreaterThanOrEqual(origin.y, visible.minY + L.screenMargin - 0.5)
    XCTAssertLessThanOrEqual(origin.y + size.height, visible.maxY - L.screenMargin + 0.5)
  }

  func testPanelLargerThanTheScreenStillLandsInside() {
    let visible = CGRect(x: 0, y: 0, width: 400, height: 300)
    let size = CGSize(width: 900, height: 400)  // wider than the screen
    let origin = L.panelOrigin(
      size: size, windowFrame: visible, visibleFrame: visible)
    XCTAssertEqual(
      origin.x, visible.minX + L.screenMargin, "degrades to the leading margin, not NaN")
  }

  // MARK: Contrast floors (D14)

  /// Tokens from a deliberately low-contrast theme: foreground almost equal to background, which is
  /// what silently kills the name and subtitle while the cursor ring still passes 3:1.
  private func lowContrastTokens() -> ThemeTokens {
    ThemeTokens(
      preview: ThemePreview(
        name: "low-contrast fixture",
        background: NSColor(srgbRed: 0.50, green: 0.50, blue: 0.50, alpha: 1),
        foreground: NSColor(srgbRed: 0.56, green: 0.56, blue: 0.56, alpha: 1),
        palette: (0..<8).map { _ in NSColor(srgbRed: 0.52, green: 0.52, blue: 0.55, alpha: 1) }))
  }

  func testTextRolesAreLiftedToTheTextFloorWherePossible() {
    let tokens = ThemeTokens(preview: nil)  // system fallback: a sane, high-contrast baseline
    let palette = SwitcherRailLayout.palette(for: tokens)
    let base = tokens.nsPanel
    XCTAssertGreaterThanOrEqual(
      ThemeTokens.contrastRatio(palette.nsName, base),
      SwitcherRailLayout.Palette.textTarget - 0.01, "the 13pt name must clear 4.5:1")
    XCTAssertGreaterThanOrEqual(
      ThemeTokens.contrastRatio(palette.nsSubtitle, base),
      SwitcherRailLayout.Palette.textTarget - 0.01, "the 11pt subtitle too — this is body text")
  }

  func testIndicatorRolesClearTheIndicatorFloor() {
    let tokens = ThemeTokens(preview: nil)
    let palette = SwitcherRailLayout.palette(for: tokens)
    let base = tokens.nsPanel
    for (role, color) in [
      ("ring", palette.nsRing), ("dot", palette.nsDot), ("diffAdd", palette.nsDiffAdd),
      ("diffRemove", palette.nsDiffRemove),
    ] {
      XCTAssertGreaterThanOrEqual(
        ThemeTokens.contrastRatio(color, base),
        SwitcherRailLayout.Palette.indicatorTarget - 0.01, "\(role) must clear 3:1")
    }
  }

  func testAThemeThatCannotMeetTheTextFloorFallsBackToAnOpaqueFill() {
    // `legible` walks towards the foreground and stops there. If even the pure foreground can't clear
    // the floor against this fill, the fill is the problem — so the card drops vibrancy. Legibility
    // outranks the material.
    let palette = SwitcherRailLayout.palette(for: lowContrastTokens())
    XCTAssertTrue(palette.needsOpaqueFill, "a washed-out theme must not keep the translucent card")
  }

  func testAHealthyThemeKeepsItsVibrancy() {
    XCTAssertFalse(
      SwitcherRailLayout.palette(for: ThemeTokens(preview: nil)).needsOpaqueFill,
      "the normal case keeps the frosted material")
  }
}
