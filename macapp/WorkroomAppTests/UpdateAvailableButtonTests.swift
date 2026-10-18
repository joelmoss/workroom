import AppKit
import DesignSystem
import XCTest

@testable import Workroom

/// The Update pill's legibility, and the scrolling note beside it, which must cost no per-frame main
/// thread work while it sits in the title bar for days.
@MainActor
final class UpdateAvailableButtonTests: XCTestCase {
  // Value: protects=the pill's white "Update" stays readable on every bundled theme, idle and
  // hovered; fails_when=the fill goes back to the raw accent (#5293D6 gives white 3.2:1) or hover
  // lightens it; why_new=no test measured the pill; seam=none; no_claim=the system accent fallback.
  func testWhiteInkReadsOnThePillInEveryBundledTheme() throws {
    for theme in try bundledThemes() {
      let tokens = ThemeTokens(preview: theme)
      for hovering in [false, true] {
        let fill = UpdateAvailableButton.fill(
          accent: tokens.nsAccent, panel: tokens.nsPanel, hovering: hovering, dimmed: false)
        XCTAssertGreaterThanOrEqual(
          ThemeTokens.contrastRatio(
            UpdateAvailableButton.ink(panel: tokens.nsPanel, dimmed: false), fill),
          4.5, "\(theme.name)\(hovering ? " (hovered)" : ""): white on the pill")
      }
    }
  }

  // Value: protects=the dimmed pill (a check in flight) is an opaque mix toward the theme's title
  // bar, with its label still legible; fails_when=dimming goes back to opacity, or stops moving the
  // fill toward the panel; why_new=the state had no test; seam=none; no_claim=how dim it looks.
  func testDimmedPillRecedesIntoTheTitleBarOpaquely() throws {
    for theme in try bundledThemes() {
      let tokens = ThemeTokens(preview: theme)
      let normal = UpdateAvailableButton.fill(
        accent: tokens.nsAccent, panel: tokens.nsPanel, hovering: false, dimmed: false)
      let dimmed = UpdateAvailableButton.fill(
        accent: tokens.nsAccent, panel: tokens.nsPanel, hovering: true, dimmed: true)
      let ink = UpdateAvailableButton.ink(panel: tokens.nsPanel, dimmed: true)
      XCTAssertEqual(dimmed.alphaComponent, 1, "\(theme.name): opaque, not translucent")
      XCTAssertEqual(ink.alphaComponent, 1, "\(theme.name): opaque ink")
      XCTAssertLessThan(
        ThemeTokens.contrastRatio(dimmed, tokens.nsPanel),
        ThemeTokens.contrastRatio(normal, tokens.nsPanel),
        "\(theme.name): dimmed sits closer to the title bar, even under the pointer")
      XCTAssertGreaterThanOrEqual(
        ThemeTokens.contrastRatio(ink, dimmed), 2.0, "\(theme.name): the dimmed label still reads")
    }
  }

  func testScrollsOnlyOverflowingTextInAKeyVisibleWindow() {
    XCTAssertTrue(MarqueeView.shouldScroll(showing: true, textWidth: 300, width: 134))
    XCTAssertFalse(MarqueeView.shouldScroll(showing: false, textWidth: 300, width: 134), "hidden")
    XCTAssertFalse(MarqueeView.shouldScroll(showing: true, textWidth: 100, width: 134), "fits")
    XCTAssertFalse(MarqueeView.shouldScroll(showing: true, textWidth: 300, width: 0), "unlaid-out")
  }

  func testScrollTravelsOneTextAndGapAtReadingSpeed() throws {
    let view = MarqueeView(text: "Safe to update: your terminals keep running.", color: .labelColor)
    view.frame = NSRect(x: 0, y: 0, width: 80, height: 20)
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.isScrolling, "no window → no animation")

    view.setScrolling(true)
    let strip = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers?.first)
    let scroll = try XCTUnwrap(
      strip.animation(forKey: MarqueeView.animationKey) as? CABasicAnimation)
    let travel = view.textWidth + MarqueeView.gap
    XCTAssertEqual(scroll.keyPath, "transform.translation.x")
    XCTAssertEqual(scroll.toValue as? CGFloat, -travel, "one copy's width, so the wrap is seamless")
    XCTAssertEqual(scroll.duration, travel / MarqueeView.speed, accuracy: 0.001)
    XCTAssertEqual(scroll.repeatCount, .infinity)

    view.setScrolling(true)
    XCTAssertTrue(
      strip.animation(forKey: MarqueeView.animationKey) === scroll,
      "re-asking to scroll must not jump the text back to the start")

    view.setScrolling(false)
    XCTAssertFalse(view.isScrolling)
  }

  func testTheNoteNeverTakesTheClick() {
    let view = MarqueeView(text: "note", color: .labelColor)
    view.frame = NSRect(x: 0, y: 0, width: 80, height: 20)
    XCTAssertNil(view.hitTest(NSPoint(x: 40, y: 10)), "the title bar behind it drags the window")
  }
}
