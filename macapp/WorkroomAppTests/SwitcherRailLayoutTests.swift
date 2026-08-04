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
    let wide = L.cardWidth(count: 5, available: 1100)
    let tight = L.cardWidth(count: 6, available: 1100)
    XCTAssertLessThan(tight, wide, "more cards ⇒ narrower cards, before any scrolling")
    XCTAssertLessThanOrEqual(wide, L.maxCardWidth)
  }

  func testCardWidthNeverGoesBelowTheFloor() {
    // The whole point of the 180pt floor (Codex #1): at 140 the label column is ~36pt, so every name
    // fragments and the badge collides — the densest state would read the worst.
    for count in [8, 12, 40, 200] {
      XCTAssertEqual(
        L.cardWidth(count: count, available: 1100), L.minCardWidth,
        "\(count) cards must shrink to the floor and then scroll, never past it")
    }
  }

  func testTheFloorIs180Not140() {
    XCTAssertEqual(L.minCardWidth, 180)
    // And the floor must leave a usable label column: card − well − padding − gap.
    let label = L.minCardWidth - L.wellSize.width - 10 * 2 - 10
    XCTAssertGreaterThan(label, 60, "a 13pt name plus a badge needs real width")
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
      L.scrolls(count: 12, available: 1100),
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
