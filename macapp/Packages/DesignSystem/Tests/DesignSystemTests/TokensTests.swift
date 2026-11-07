import SwiftUI
import XCTest

@testable import DesignSystem

/// The scales took over literals the views already used, so a token's value is what every view
/// built on it measures out to. Changing one moves every one of them; these pin the values so a
/// change to the scale is a deliberate one.
final class TokensTests: XCTestCase {
  func testSpacingScale() {
    XCTAssertEqual(
      [
        Spacing.xxs, Spacing.xs, Spacing.s, Spacing.m, Spacing.l, Spacing.xl, Spacing.xxl,
        Spacing.xxxl,
      ],
      [2, 4, 6, 8, 12, 16, 20, 24])
  }

  func testRadiusScale() {
    XCTAssertEqual([Radius.xs, Radius.s, Radius.m, Radius.l], [5, 6, 8, 12])
  }

  func testFontRoles() {
    XCTAssertEqual(FontRole.headerGlyph, .system(size: 30))
    XCTAssertEqual(FontRole.title, .headline)
    XCTAssertEqual(FontRole.body, .callout)
    XCTAssertEqual(FontRole.detail, .footnote)
    XCTAssertEqual(FontRole.messageGlyph, .title2)
    XCTAssertEqual(FontRole.noticeTitle, .subheadline.weight(.semibold))
    XCTAssertEqual(FontRole.noticeBody, .caption)
  }
}
