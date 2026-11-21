import AppKit
import Defaults
import DesignSystem
import SwiftUI
import XCTest

@testable import Workroom

/// `ThemeFill` is the one path every main-window solid theme fill goes through (#726), so Glass
/// (#725) can change how those fills draw in one place. Today it must draw exactly what the theme
/// token it names drew before: these tests pin that, for SwiftUI (read from the environment, live
/// across a theme switch) and for AppKit (read from the theme service).
@MainActor
final class ThemeFillTests: XCTestCase {
  private var savedFamily: String!

  override func setUp() async throws {
    try await super.setUp()
    savedFamily = Defaults[.themeFamily]
    ThemeService.shared.applyFamily(ThemeCatalog.defaultFamilyName)
  }

  override func tearDown() async throws {
    ThemeService.shared.applyFamily(savedFamily)
    try await super.tearDown()
  }

  private let size = NSSize(width: 40, height: 40)

  private func host<V: View>(_ view: V) -> (NSHostingView<V>, NSWindow) {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFront(nil)
    settle(hosting, seconds: 0.3)
    return (hosting, window)
  }

  private func pixel(_ view: NSView) -> NSColor? {
    view.layoutSubtreeIfNeeded()
    let rect = NSRect(x: 20, y: 20, width: 1, height: 1)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
    view.cacheDisplay(in: rect, to: rep)
    return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
  }

  /// What `view` draws at the centre, as the window composites it.
  private func render<V: View>(_ view: V) throws -> NSColor {
    let (hosting, window) = host(view)
    defer { window.close() }
    return try XCTUnwrap(pixel(hosting))
  }

  private static func near(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
    guard let a = lhs?.usingColorSpace(.sRGB), let b = rhs?.usingColorSpace(.sRGB) else {
      return false
    }
    let tolerance: CGFloat = 2 / 255
    return abs(a.redComponent - b.redComponent) <= tolerance
      && abs(a.greenComponent - b.greenComponent) <= tolerance
      && abs(a.blueComponent - b.blueComponent) <= tolerance
      && abs(a.alphaComponent - b.alphaComponent) <= tolerance
  }

  private func blank() -> some View { Color.clear.frame(width: 40, height: 40) }

  /// Each fill draws, pixel for pixel, the token it names, over the same opaque ground: the
  /// "no visible change" the prefactor promises. Compared with a render of the token itself, not
  /// its value, because colour management shifts both on the way to the window.
  func testEachFillDrawsTheTokenItNames() throws {
    let tokens = ThemeService.shared.tokens
    let cases: [(ThemeFill, Color)] = [
      (.panel, tokens.panel), (.background, tokens.bg), (.raised, tokens.surface),
    ]
    for (fill, token) in cases {
      let drawn = try render(
        blank().background(fill).background(Color.black).themeTokensRoot())
      let expected = try render(blank().background(token).background(Color.black))
      XCTAssertTrue(
        Self.near(drawn, expected), "\(fill) drew \(drawn) where its token draws \(expected)")
    }
  }

  /// The fill reads the theme from the environment, not a snapshot: a tree given other tokens draws
  /// those, so a theme switch (which re-injects at the root) reaches it.
  func testAFillFollowsTheTokensInItsEnvironment() throws {
    let other = try XCTUnwrap(
      ThemeCatalog.families.first { $0.name != Defaults[.themeFamily] })
    let otherTokens = ThemeTokens(
      preview: ThemeService.themePreview(
        named: ThemeCatalog.sanitizedThemeName(
          other.variant(isDark: ThemeService.isCurrentAppearanceDark()))))
    let drawn = try render(
      blank().background(ThemeFill.panel).environment(\.themeTokens, otherTokens))
    let expected = try render(blank().background(otherTokens.panel))
    let active = try render(blank().background(ThemeService.shared.tokens.panel))
    XCTAssertFalse(Self.near(expected, active), "the two families must differ in panel colour")
    XCTAssertTrue(Self.near(drawn, expected), "the fill ignored its environment's tokens")
  }

  /// AppKit drawing has no environment: it reads the live theme service, so a switch reaches it.
  func testTheAppKitColourFollowsTheActiveTheme() throws {
    XCTAssertEqual(ThemeFill.panel.nsColor(), ThemeService.shared.tokens.nsPanel)
    XCTAssertEqual(ThemeFill.background.nsColor(), ThemeService.shared.tokens.nsBg)
    let other = try XCTUnwrap(
      ThemeCatalog.families.first { $0.name != Defaults[.themeFamily] })
    ThemeService.shared.applyFamily(other.name)
    XCTAssertEqual(ThemeFill.panel.nsColor(), ThemeService.shared.tokens.nsPanel)
    XCTAssertEqual(ThemeFill.background.nsColor(), ThemeService.shared.tokens.nsBg)
  }
}
