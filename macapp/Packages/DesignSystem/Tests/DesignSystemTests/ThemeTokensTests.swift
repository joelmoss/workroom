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

  /// Glass draws the chrome as `panelWash` over `bg` (#725), so the wash composited over the
  /// background, per sRGB channel as the screen composites, must come out as `panel`, on dark and
  /// light themes and a coloured one alike. A fixed 5.5% wash drew the cards visibly darker than the
  /// panel on a dark theme, because `panel` is not a 5.5% sRGB blend.
  func testThePanelWashOverTheBackgroundIsThePanel() throws {
    func hex(_ value: Int) -> NSColor {
      NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
    let themes = [
      ("Workroom", hex(0x1c1c1e), hex(0xd8d8dc)), ("Workroom Light", hex(0xfbfbfd), hex(0x1d1d1f)),
      ("Solarized Dark", hex(0x002b36), hex(0x839496)), ("pure", NSColor.black, NSColor.white),
    ]
    for (name, bg, fg) in themes {
      let tokens = ThemeTokens(
        preview: ThemePreview(name: name, background: bg, foreground: fg, palette: []))
      let wash = try XCTUnwrap(tokens.nsPanelWash.usingColorSpace(.sRGB))
      let base = try XCTUnwrap(bg.usingColorSpace(.sRGB))
      let panel = try XCTUnwrap(tokens.nsPanel.usingColorSpace(.sRGB))
      let a = wash.alphaComponent
      XCTAssertEqual(a, tokens.panelWashAlpha)
      for (w, b, p) in [
        (wash.redComponent, base.redComponent, panel.redComponent),
        (wash.greenComponent, base.greenComponent, panel.greenComponent),
        (wash.blueComponent, base.blueComponent, panel.blueComponent),
      ] {
        XCTAssertEqual(a * w + (1 - a) * b, p, accuracy: 1.0 / 255, name)
      }
    }
  }
}
