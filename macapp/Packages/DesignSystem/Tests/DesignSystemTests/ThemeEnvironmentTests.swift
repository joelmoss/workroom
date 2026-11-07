import AppKit
import SwiftUI
import XCTest

@testable import DesignSystem

/// An un-injected tree reads the system palette, never a theme, so a missing root shows as the
/// native look rather than as a stale theme that looks almost right.
final class ThemeEnvironmentTests: XCTestCase {
  func testTheDefaultIsTheSystemPalette() {
    let tokens = EnvironmentValues().themeTokens
    XCTAssertEqual(tokens.nsBg, .textBackgroundColor)
    XCTAssertEqual(tokens.nsFg, .textColor)
  }

  /// Each read of the default is the same instance, so SwiftUI never sees an un-injected tree's
  /// theme change.
  func testTheDefaultIsOneInstance() {
    XCTAssertTrue(
      EnvironmentValues().themeTokens.nsPanel === EnvironmentValues().themeTokens.nsPanel)
  }
}
