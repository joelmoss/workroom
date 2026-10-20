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
  }

  /// With no theme, success is system green: kept as the dynamic colour where it already reads
  /// (dark), made readable where it doesn't (light, where it is about 2.2:1 on white). Resolved
  /// under each appearance explicitly, so the result doesn't depend on the Mac running the test.
  func testSystemGreenFallbackIsReadableInBothAppearances() throws {
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = try XCTUnwrap(NSAppearance(named: name))
      appearance.performAsCurrentDrawingAppearance {
        let tokens = ThemeTokens(preview: nil)
        let grounds = ThemeTokens.statusGrounds(
          bg: tokens.nsBg, panel: tokens.nsPanel, fg: tokens.nsFg, accent: tokens.nsAccent)
        for ground in grounds {
          XCTAssertGreaterThanOrEqual(
            ThemeTokens.contrastRatio(tokens.nsSuccess, ground), 3 - 0.01, "\(name.rawValue)")
        }
        if grounds.allSatisfy({ ThemeTokens.contrastRatio(.systemGreen, $0) >= 3 }) {
          XCTAssertEqual(tokens.nsSuccess, .systemGreen, "\(name.rawValue): a readable fallback")
        }
      }
    }
  }
}
