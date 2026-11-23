import AppKit
import Defaults
import DesignSystem
import SwiftUI
import XCTest

@testable import Workroom

/// What Settings ▸ Themes draws, measured in its pixels: the stage's windows end under their
/// terminal, and only a tile the keyboard has tabbed to draws a focus ring. Rendered in process at a
/// Settings-window size, with the appearance Dark and Workroom the dark theme, and the elements found
/// through the accessibility tree.
@MainActor
final class ThemesSettingsPaneLayoutTests: XCTestCase {
  private var savedLight: String!
  private var savedDark: String!
  private var savedAppearance: AppearanceMode!
  private var savedFilter: Bool!

  override func setUp() async throws {
    try await super.setUp()
    savedLight = Defaults[.lightTheme]
    savedDark = Defaults[.darkTheme]
    savedAppearance = Defaults[.appearance]
    savedFilter = Defaults[.themeFavouritesOnly]
    let workroom = ThemeCatalog.defaultFamily
    Defaults[.lightTheme] = workroom.light
    Defaults[.darkTheme] = workroom.dark
    Defaults[.appearance] = .dark
    Defaults[.themeFavouritesOnly] = false
  }

  override func tearDown() async throws {
    Defaults[.lightTheme] = savedLight
    Defaults[.darkTheme] = savedDark
    Defaults[.appearance] = savedAppearance
    Defaults[.themeFavouritesOnly] = savedFilter
    try await super.tearDown()
  }

  /// The stage's dark window ends just under its last line of terminal: no more than the
  /// terminal's own padding and a line's descent below it. A fixed-height window left about 40pt.
  func testAStageWindowEndsUnderItsTerminal() throws {
    try withPane { hosting, rep in
      let window = try XCTUnwrap(frame(of: "settings.themes.stage.dark", in: hosting))
      // The terminal column, clear of the sidebar and the rounded corners; from just inside the
      // window's frame and ring, upwards.
      let columns = stride(from: window.minX + window.width * 0.4, to: window.maxX - 12, by: 2)
      let background = pixel(rep, CGPoint(x: window.midX, y: window.maxY - 6), in: hosting)
      var lastInk: CGFloat?
      var y = window.maxY - 6
      while y > window.minY, lastInk == nil {
        if columns.contains(where: {
          differs(pixel(rep, CGPoint(x: $0, y: y), in: hosting), from: background)
        }) {
          lastInk = y
        }
        y -= 1
      }
      let ink = try XCTUnwrap(lastInk, "no terminal text in the stage window")
      XCTAssertLessThan(
        window.maxY - ink, 16, "the stage window leaves \(window.maxY - ink)pt under its terminal")
    }
  }

  /// With the grid focused, as it is to take the arrow keys, a tile that isn't the current choice
  /// draws no ring outside its edge: the ring is for a tile the keyboard has tabbed to.
  func testATileTheKeyboardIsNotOnDrawsNoFocusRing() throws {
    try withPane { hosting, rep in
      let tiles = identifiers(under: hosting).filter {
        $0.hasPrefix("settings.themes.dark-") && $0 != "settings.themes.dark-Workroom"
          && !$0.hasSuffix("-star") && !$0.hasSuffix("-yours")
      }
      let id = try XCTUnwrap(tiles.first, "the Dark grid lists no other tile")
      let tile = try XCTUnwrap(frame(of: id, in: hosting))
      // The ring is a 3pt band just outside the tile; the gap between tiles is wider than that.
      let ring = pixel(rep, CGPoint(x: tile.minX - 1.5, y: tile.midY), in: hosting)
      let gap = pixel(rep, CGPoint(x: tile.minX - 7, y: tile.midY), in: hosting)
      XCTAssertFalse(differs(ring, from: gap), "\(id) draws a focus ring the keyboard isn't on")
    }
  }

  // MARK: Harness

  private func withPane(_ body: (NSHostingView<AnyView>, NSBitmapImageRep) throws -> Void) throws {
    // SwiftUI builds its accessibility nodes only for an assistive client; this attribute, which
    // VoiceOver sets on an app, asks for them in process (`CreationPaneAccessibilityTests`).
    Self.setEnhancedUserInterface(true)
    defer { Self.setEnhancedUserInterface(false) }
    let hosting = NSHostingView(rootView: AnyView(ThemesSettingsPane().themeTokensRoot()))
    hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    // Long enough for the grid to settle, take focus, and fade in.
    settle(hosting, seconds: 1.2)
    let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try body(hosting, rep)
  }

  private static func setEnhancedUserInterface(_ on: Bool) {
    AXUIElementSetAttributeValue(
      AXUIElementCreateApplication(getpid()), "AXEnhancedUserInterface" as CFString,
      on as CFBoolean)
  }

  /// The frame of the element called `identifier`, in `hosting`'s coordinates.
  private func frame(of identifier: String, in hosting: NSView) -> NSRect? {
    guard let node = Self.first(identifier, under: hosting),
      let screen = node.accessibilityFrame?(), let window = hosting.window
    else { return nil }
    return hosting.convert(window.convertFromScreen(screen), from: nil)
  }

  private func identifiers(under node: AnyObject) -> [String] {
    var found: [String] = []
    if let id = node.accessibilityIdentifier?(), !id.isEmpty { found.append(id) }
    for child in node.accessibilityChildren?() ?? [] {
      found += identifiers(under: child as AnyObject)
    }
    return found
  }

  private static func first(_ identifier: String, under node: AnyObject) -> AnyObject? {
    if node.accessibilityIdentifier?() == identifier { return node }
    for child in node.accessibilityChildren?() ?? [] {
      if let hit = first(identifier, under: child as AnyObject) { return hit }
    }
    return nil
  }

  /// The colour at `point` in `hosting`'s coordinates.
  private func pixel(_ rep: NSBitmapImageRep, _ point: CGPoint, in hosting: NSView) -> NSColor {
    let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
    let y = hosting.isFlipped ? point.y : hosting.bounds.height - point.y
    let color = rep.colorAt(x: Int(point.x * scale), y: Int(y * scale)) ?? .clear
    return color.usingColorSpace(.sRGB) ?? color
  }

  private func differs(_ a: NSColor, from b: NSColor) -> Bool {
    abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
      + abs(a.blueComponent - b.blueComponent) > 0.15
  }
}
