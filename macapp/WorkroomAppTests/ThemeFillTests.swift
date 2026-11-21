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

  private func blank() -> some View { Color.clear.frame(width: 40, height: 40) }

  /// Each fill draws, pixel for pixel, the token it names, over the same opaque ground: the
  /// "no visible change" the prefactor promises. Compared with a render of the token itself, not
  /// its value, because colour management shifts both on the way to the window.
  func testEachFillDrawsTheTokenItNames() throws {
    let tokens = ThemeService.shared.tokens
    let cases: [(ThemeFill, Color)] = [
      (.panel, tokens.panel), (.background, tokens.bg), (.raised, tokens.surface),
      (.nestedRaised, tokens.surface), (.textBackground, Color(nsColor: .textBackgroundColor)),
      (.selectedTab, tokens.bg), (.hoveredTab, tokens.hover), (.idleTab, .clear),
    ]
    for (fill, token) in cases {
      let drawn = try renderedCentre(
        blank().background(fill).background(Color.black).themeTokensRoot())
      let expected = try renderedCentre(blank().background(token).background(Color.black))
      XCTAssertTrue(
        nearColor(drawn, expected), "\(fill) drew \(drawn) where its token draws \(expected)")
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
    let drawn = try renderedCentre(
      blank().background(ThemeFill.panel).environment(\.themeTokens, otherTokens))
    let expected = try renderedCentre(blank().background(otherTokens.panel))
    let active = try renderedCentre(blank().background(ThemeService.shared.tokens.panel))
    XCTAssertFalse(nearColor(expected, active), "the two families must differ in panel colour")
    XCTAssertTrue(nearColor(drawn, expected), "the fill ignored its environment's tokens")
  }

  /// Under glass (#725) the window base is the one tint, so no fill tints at the Glass opacity again: the
  /// panel is a wash of the foreground, the background and the ground draw nothing, the raised wash
  /// is drawn as it always is but nowhere a host already lays it, the system text background draws
  /// nothing, and a selected tab takes the selected-tab wash.
  func testUnderGlassEachFillDrawsItsOwnRule() throws {
    let tokens = ThemeService.shared.tokens
    let glass = GlassAppearance.glass(opacity: 0.9)
    let cases: [(ThemeFill, Color)] = [
      (.panel, tokens.fg.opacity(0.055)), (.background, .clear), (.ground, .clear),
      (.raised, tokens.surface), (.nestedRaised, .clear), (.textBackground, .clear),
      (.selectedTab, tokens.tabActive), (.hoveredTab, tokens.hover), (.idleTab, .clear),
    ]
    for (fill, expectedFill) in cases {
      let drawn = try renderedCentre(
        blank().background(fill).background(Color.black).environment(\.glassAppearance, glass)
          .themeTokensRoot())
      let expected = try renderedCentre(blank().background(expectedFill).background(Color.black))
      XCTAssertTrue(
        nearColor(drawn, expected), "\(fill) drew \(drawn) under glass, expected \(expected)")
    }
  }

  /// The panel wash over the window base is the panel colour: the two-layer glass chrome reads as
  /// the opaque chrome does, less what shows through.
  func testThePanelWashOverTheBackgroundIsThePanel() throws {
    let tokens = ThemeService.shared.tokens
    let drawn = try renderedCentre(blank().background(tokens.panelWash).background(tokens.bg))
    let expected = try renderedCentre(blank().background(tokens.panel))
    XCTAssertTrue(nearColor(drawn, expected), "\(drawn) is not the panel, \(expected)")
  }

  /// Opaque, the ground is the panel it always was.
  func testOpaqueTheGroundDrawsThePanel() throws {
    let drawn = try renderedCentre(
      blank().background(ThemeFill.ground).background(Color.black).themeTokensRoot())
    let expected = try renderedCentre(
      blank().background(ThemeService.shared.tokens.panel).background(Color.black))
    XCTAssertTrue(nearColor(drawn, expected))
  }

  /// The AppKit form takes the window's appearance and applies the same rules.
  func testTheAppKitColourUnderGlass() {
    let tokens = ThemeService.shared.tokens
    let glass = GlassAppearance.glass(opacity: 0.9)
    XCTAssertEqual(ThemeFill.panel.nsColor(glass: glass), tokens.nsPanelWash)
    XCTAssertEqual(tokens.nsPanelWash, tokens.nsFg.withAlphaComponent(0.055))
    XCTAssertEqual(ThemeFill.background.nsColor(glass: glass), .clear)
    XCTAssertEqual(ThemeFill.ground.nsColor(glass: glass), .clear)
    XCTAssertNil(ThemeFill.background.nsFill(tokens, glass: glass), "so a view stops drawing")
    XCTAssertEqual(ThemeFill.background.nsFill(tokens, glass: .opaque), tokens.nsBg)
    XCTAssertEqual(ThemeFill.ground.nsColor(), tokens.nsPanel)
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

/// A tab's fill picks the selected, hovered or idle case, selection first.
extension ThemeFillTests {
  func testATabsFillIsSelectedThenHoveredThenIdle() {
    XCTAssertEqual(ThemeFill.tab(active: true, hovered: true), .selectedTab)
    XCTAssertEqual(ThemeFill.tab(active: true, hovered: false), .selectedTab)
    XCTAssertEqual(ThemeFill.tab(active: false, hovered: true), .hoveredTab)
    XCTAssertEqual(ThemeFill.tab(active: false, hovered: false), .idleTab)
  }
}

extension XCTestCase {
  /// What `view` draws at the centre of a 40-point window, as the window composites it.
  @MainActor
  func renderedCentre<V: View>(_ view: V) throws -> NSColor {
    let (window, hosting) = hostInWindow(view, size: NSSize(width: 40, height: 40))
    defer { window.close() }
    // Mounts the hosted tree now: its update runs in layout, so there is nothing to wait for.
    hosting.layoutSubtreeIfNeeded()
    let rect = NSRect(x: 20, y: 20, width: 1, height: 1)
    let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: rect))
    hosting.cacheDisplay(in: rect, to: rep)
    return try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
  }

  /// Whether two rendered colours match within a step of 8-bit rounding.
  func nearColor(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
    guard let a = lhs?.usingColorSpace(.sRGB), let b = rhs?.usingColorSpace(.sRGB) else {
      return false
    }
    let tolerance: CGFloat = 2 / 255
    return abs(a.redComponent - b.redComponent) <= tolerance
      && abs(a.greenComponent - b.greenComponent) <= tolerance
      && abs(a.blueComponent - b.blueComponent) <= tolerance
      && abs(a.alphaComponent - b.alphaComponent) <= tolerance
  }
}
