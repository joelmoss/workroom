import AppKit
import DesignSystem
import SwiftUI
import XCTest

@testable import Workroom

/// What the chrome (sidebar, inspector, activity bar, footer, status bar) draws on (#730):
/// today's backing with Glass off; under glass the flat panel wash over the window base, or
/// nothing for the frame (activity bar, footer) and a card's band. Never a blur material and never
/// Liquid Glass: the window's own blur is the only frosting.
@MainActor
final class ChromeBackingTests: XCTestCase {
  private let roles: [ChromeRole] = [.card, .floatingCard, .bar]
  private let glass = GlassAppearance.glass(opacity: 0.9)

  private func chrome(_ role: ChromeRole, glass: GlassAppearance) -> some View {
    Color.clear.frame(width: 40, height: 40)
      .background(ChromeBackground(role: role))
      .environment(\.glassAppearance, glass)
      .themeTokensRoot()
  }

  // MARK: What it draws under glass

  /// What `role` draws under glass over black, against `expected` drawn over black.
  private func assertGlassDraws(
    _ role: ChromeRole, _ expected: some View, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let drawn = try renderedCentre(chrome(role, glass: glass).background(Color.black))
    let want = try renderedCentre(
      Color.clear.frame(width: 40, height: 40).background(expected).background(Color.black))
    XCTAssertTrue(
      nearColor(drawn, want), "\(role) drew \(drawn), expected \(want)", file: file, line: line)
  }

  /// A card is the flat panel wash over the window base.
  func testUnderGlassACardIsThePanelWash() throws {
    try assertGlassDraws(.card, ThemeService.shared.tokens.panelWash)
  }

  /// A floating card lays the window base again under the wash, so what it covers does not show
  /// through.
  func testUnderGlassAFloatingCardLaysTheBaseUnderTheWash() throws {
    let tokens = ThemeService.shared.tokens
    try assertGlassDraws(
      .floatingCard, Rectangle().fill(tokens.panelWash).background(tokens.bg.opacity(0.9)))
  }

  /// The docked sidebar, the activity bar and the window footer draw nothing under glass: they are
  /// the bare window base, the same colour as the title bar and gutters.
  func testUnderGlassABarDrawsNothing() throws {
    try assertGlassDraws(.bar, Color.clear)
  }

  // MARK: What a real window gets

  private func effectViews(_ role: ChromeRole, glass: GlassAppearance) -> [NSView] {
    let (window, hosting) = hostInWindow(
      chrome(role, glass: glass), size: NSSize(width: 40, height: 40))
    defer { window.close() }
    // Mounts the hosted tree now: its update runs in layout, so there is nothing to wait for.
    hosting.layoutSubtreeIfNeeded()
    var found: [NSView] = []
    func walk(_ view: NSView) {
      if view is NSVisualEffectView { found.append(view) }
      if #available(macOS 26.0, *), view is NSGlassEffectView { found.append(view) }
      view.subviews.forEach(walk)
    }
    walk(hosting)
    return found
  }

  /// Under glass no chrome adds a blur material or Liquid Glass.
  func testGlassChromeAddsNoMaterialOrLiquidGlass() {
    for role in roles {
      XCTAssertEqual(effectViews(role, glass: glass), [], "\(role)")
    }
  }

  func testOpaqueChromeKeepsTodaysVibrancy() {
    for role in roles {
      let views = effectViews(role, glass: .opaque)
      if #available(macOS 26.0, *) {
        XCTAssertFalse(views.contains { $0 is NSGlassEffectView }, "\(role)")
      }
      // Today's card is the `.sidebar` vibrancy; the flat bar has none.
      XCTAssertEqual(views.count, role == .bar ? 0 : 1, "\(role)")
    }
  }
}
