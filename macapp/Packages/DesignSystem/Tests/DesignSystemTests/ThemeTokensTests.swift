import AppKit
import SwiftUI
import XCTest

@testable import DesignSystem

final class ThemeTokensTests: XCTestCase {
  func testSuccessIsPaletteGreenWithSystemFallback() {
    let green = NSColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1)
    let palette = (0..<16).map { $0 == 2 ? green : NSColor.black }
    let themed = ThemeTokens(
      preview: ThemePreview(name: "t", background: .black, foreground: .white, palette: palette))
    XCTAssertEqual(themed.success, Color(nsColor: green))
    XCTAssertEqual(ThemeTokens(preview: nil).success, Color(nsColor: .systemGreen))
  }
}
