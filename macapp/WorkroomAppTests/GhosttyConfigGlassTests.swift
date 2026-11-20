import AppKit
import DesignSystem
import GhosttyKit
import XCTest

@testable import Workroom

/// Glass (#727) reaches the terminals through the one generated Ghostty config: `background-opacity
/// = 0` under glass, so the window base is the terminal's default background, absent when opaque,
/// and accepted by the linked engine, which still draws cells' own backgrounds. A window that
/// resolves opaque under glass keeps that config and lays the theme background behind its
/// terminals (`GlassOtherWindowsTests`). Ghostty's
/// own `background-blur` stays off, since the window's one blur layer is the only blur. Prior art:
/// `GhosttyConfigMinimumContrastTests`.
@MainActor
final class GhosttyConfigGlassTests: XCTestCase {
  private var url: URL!

  override func setUp() async throws {
    try await super.setUp()
    // The engine must be initialised before a config can be built.
    _ = GhosttyApp.shared
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-glass-config-\(UUID().uuidString).conf")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: url)
    try await super.tearDown()
  }

  private func write(_ glass: GlassAppearance) throws -> String {
    XCTAssertTrue(
      GhosttyApp.writeThemeConfig(
        theme: ThemeService.activeThemeName(for: .light), glass: glass, to: url))
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// The engine's diagnostics for the file as written.
  private func diagnostics() throws -> [String] {
    let cfg = try XCTUnwrap(ghostty_config_new())
    defer { ghostty_config_free(cfg) }
    url.path.withCString { ghostty_config_load_file(cfg, $0) }
    ghostty_config_finalize(cfg)
    return (0..<ghostty_config_diagnostics_count(cfg)).map {
      String(cString: ghostty_config_get_diagnostic(cfg, $0).message)
    }
  }

  func testGlassWritesAClearDefaultBackground() throws {
    let contents = try write(.glass(opacity: 0.9))
    XCTAssertTrue(contents.split(separator: "\n").contains("background-opacity = 0"), contents)
    XCTAssertFalse(contents.contains("background-blur"), "the window's blur is the only blur")
    XCTAssertEqual(try diagnostics(), [])
  }

  /// The config is the same at every opacity: the window base carries the tint, so moving the
  /// Glass slider within glass has nothing to rewrite.
  func testTheConfigDoesNotDependOnTheOpacity() throws {
    let low = try write(.glass(opacity: 0.7))
    XCTAssertEqual(try write(.glass(opacity: 0.85)), low)
    XCTAssertEqual(try write(.glass(opacity: 0.99)), low)
    XCTAssertNotEqual(try write(.opaque), low, "only turning opaque changes it")
  }

  /// Under glass `minimum-contrast` would measure against black (the clear default background), so
  /// it is left out, and the floor is written into the colours instead, with no diagnostics.
  func testGlassOmitsMinimumContrastAndOverridesTheColoursUnderIt() throws {
    let theme = ThemeService.activeThemeName(for: .light)
    let contents = try write(.glass(opacity: 0.9))
    XCTAssertFalse(contents.contains("minimum-contrast"), contents)
    let preview = try XCTUnwrap(ThemeService.themePreview(named: theme))
    for line in GhosttyApp.glassContrastOverrides(for: preview) {
      XCTAssertTrue(contents.split(separator: "\n").contains(Substring(line)), line)
    }
    XCTAssertEqual(try diagnostics(), [])
  }

  /// A light theme whose bright white (palette 15) is its own background gets that colour, and only
  /// colours under 3:1, overridden to one that clears 3:1 on the background.
  func testALightThemesFailingBrightWhiteIsOverridden() throws {
    let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    let ink = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    var palette = Array(repeating: ink, count: 16)
    palette[15] = NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
    let preview = ThemePreview(name: "Test", background: white, foreground: ink, palette: palette)

    let lines = GhosttyApp.glassContrastOverrides(for: preview)
    XCTAssertEqual(lines.count, 1, "\(lines)")
    let line = try XCTUnwrap(lines.first)
    XCTAssertTrue(line.hasPrefix("palette = 15=#"), line)
    let hex = String(line.dropFirst("palette = 15=#".count))
    let value = try XCTUnwrap(Int(hex, radix: 16))
    let color = NSColor(
      srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
      blue: CGFloat(value & 0xff) / 255, alpha: 1)
    XCTAssertGreaterThanOrEqual(ThemeTokens.contrastRatio(color, white), 3)

    // And the engine takes it.
    var contents = try write(.glass(opacity: 0.9))
    contents += "\n" + line + "\nforeground = #1a1a1a\n"
    try contents.write(to: url, atomically: true, encoding: .utf8)
    XCTAssertEqual(try diagnostics(), [])
  }

  /// A glass write takes the contrast overrides from the preview it is handed when that preview is
  /// the theme's (`ThemeService.activePreview`), so it parses no theme file, and ignores one for
  /// another theme.
  func testAGlassWriteReusesTheThemesPreview() throws {
    let theme = ThemeService.activeThemeName(for: .light)
    let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    let ink = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    var palette = Array(repeating: ink, count: 16)
    palette[15] = white
    func preview(named name: String) -> ThemePreview {
      ThemePreview(name: name, background: white, foreground: ink, palette: palette)
    }
    let overrides = GhosttyApp.glassContrastOverrides(for: preview(named: theme))
    XCTAssertEqual(overrides.count, 1, "\(overrides)")

    XCTAssertTrue(
      GhosttyApp.writeThemeConfig(
        theme: theme, glass: .glass(opacity: 0.9), preview: preview(named: theme), to: url))
    let reused = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    XCTAssertTrue(reused.contains(Substring(overrides[0])), "\(reused)")

    XCTAssertTrue(
      GhosttyApp.writeThemeConfig(
        theme: theme, glass: .glass(opacity: 0.9), preview: preview(named: "Another"), to: url))
    XCTAssertEqual(
      try String(contentsOf: url, encoding: .utf8), try write(.glass(opacity: 0.9)),
      "another theme's preview is ignored")
  }

  /// The engine reads the file as written: a clear default background, while a cell with a
  /// background colour of its own still draws it opaque (`background-opacity-cells` off).
  func testTheEngineKeepsCellBackgroundsUnderGlass() throws {
    _ = try write(.glass(opacity: 0.9))
    let cfg = try XCTUnwrap(ghostty_config_new())
    defer { ghostty_config_free(cfg) }
    url.path.withCString { ghostty_config_load_file(cfg, $0) }
    ghostty_config_finalize(cfg)
    var opacity = 1.0
    let opacityKey = "background-opacity"
    XCTAssertTrue(ghostty_config_get(cfg, &opacity, opacityKey, UInt(opacityKey.utf8.count)))
    XCTAssertEqual(opacity, 0, accuracy: 0.001)
    var cells = true
    let cellsKey = "background-opacity-cells"
    XCTAssertTrue(ghostty_config_get(cfg, &cells, cellsKey, UInt(cellsKey.utf8.count)))
    XCTAssertFalse(cells, "cells with their own background stay opaque")
  }

  func testOpaqueOmitsBackgroundOpacity() throws {
    let contents = try write(.opaque)
    XCTAssertFalse(contents.contains("background-opacity"), contents)
    XCTAssertTrue(
      contents.split(separator: "\n").contains("minimum-contrast = 3.0"),
      "opaque keeps the engine's contrast floor")
    XCTAssertFalse(contents.contains("palette ="), "and overrides no colour")
    XCTAssertFalse(contents.contains("background-blur"))
    XCTAssertEqual(try diagnostics(), [])
  }

  /// The live engine's own file follows the app-wide resolution.
  func testTheAppConfigFollowsTheTerminalAppearance() throws {
    GhosttyApp.shared.writeThemeConfig(dark: false)
    let contents = try String(contentsOf: GhosttyApp.shared.themeConfigURL, encoding: .utf8)
    XCTAssertEqual(
      contents.contains("background-opacity"), GlassService.shared.terminalAppearance.isGlass)
  }
}
