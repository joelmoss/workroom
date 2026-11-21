import AppKit
import Defaults
import XCTest

@testable import Workroom

/// The Glass resolver (#725, #727): the one place that decides whether a window draws frosted, and
/// at what opacity. Every rule the spec names, from the three inputs alone.
final class GlassResolverTests: XCTestCase {
  private func resolve(
    _ opacity: Double, reduceTransparency: Bool = false, fullScreen: Bool = false
  ) -> GlassAppearance {
    GlassResolver.resolve(
      opacity: opacity, reduceTransparency: reduceTransparency, fullScreen: fullScreen)
  }

  /// 100% is opaque: the top of the slider is Glass off.
  func testOneHundredPercentIsOpaque() {
    XCTAssertEqual(resolve(1), .opaque)
  }

  func testBelowOneHundredPercentIsGlassAtThatOpacity() {
    XCTAssertEqual(resolve(0.85), .glass(opacity: 0.85))
    XCTAssertEqual(resolve(0.99), .glass(opacity: 0.99))
  }

  /// 70% is the floor: anything lower draws at 70%.
  func testTheFloorIsSeventyPercent() {
    XCTAssertEqual(resolve(0.7), .glass(opacity: 0.7))
    XCTAssertEqual(resolve(0.5), .glass(opacity: 0.7))
    XCTAssertEqual(resolve(0), .glass(opacity: 0.7))
  }

  /// Over 100% is still opaque, and a value a float step short of 100% is 100%, not glass.
  func testAboveOrJustShortOfOneHundredPercentIsOpaque() {
    XCTAssertEqual(resolve(1.2), .opaque)
    XCTAssertEqual(resolve(0.7 + 6 * 0.05), .opaque)
    XCTAssertEqual(resolve(0.999_999), .opaque)
  }

  func testReduceTransparencyIsOpaque() {
    XCTAssertEqual(resolve(0.85, reduceTransparency: true), .opaque)
  }

  func testNativeFullScreenIsOpaque() {
    XCTAssertEqual(resolve(0.85, fullScreen: true), .opaque)
  }

  /// Glass is off until the slider moves.
  func testTheSettingDefaultsToOneHundredPercent() {
    XCTAssertEqual(Defaults.Keys.glassOpacity.defaultValue, 1)
    XCTAssertEqual(resolve(Defaults.Keys.glassOpacity.defaultValue), .opaque)
  }

  /// What a surface multiplies its fill's alpha by: nothing when opaque, the opacity under glass.
  func testTheResolvedOpacity() {
    XCTAssertEqual(GlassAppearance.opaque.opacity, 1)
    XCTAssertEqual(GlassAppearance.glass(opacity: 0.8).opacity, 0.8)
    XCTAssertFalse(GlassAppearance.opaque.isGlass)
    XCTAssertTrue(GlassAppearance.glass(opacity: 0.8).isGlass)
  }
}

/// The service keeps the resolver's app-wide inputs live: a Reduce transparency change or a settings
/// change re-resolves without a relaunch, and the terminals hear about it only when Glass turns.
@MainActor
final class GlassServiceTests: XCTestCase {
  private var savedOpacity: Double!

  override func setUp() async throws {
    try await super.setUp()
    savedOpacity = Defaults[.glassOpacity]
  }

  override func tearDown() async throws {
    Defaults[.glassOpacity] = savedOpacity
    try await super.tearDown()
  }

  func testReduceTransparencyReResolvesLive() {
    Defaults[.glassOpacity] = 0.85
    var reduce = false
    let center = NotificationCenter()
    let service = GlassService(readReduceTransparency: { reduce }, accessibilityCenter: center)
    XCTAssertEqual(service.appearance(fullScreen: false), .glass(opacity: 0.85))

    reduce = true
    center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    XCTAssertEqual(service.appearance(fullScreen: false), .opaque)
    XCTAssertFalse(service.refresh(), "the notification already turned the terminals")

    reduce = false
    center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    XCTAssertEqual(service.appearance(fullScreen: false), .glass(opacity: 0.85))
  }

  func testMovingTheSettingReResolvesLive() async {
    Defaults[.glassOpacity] = 1
    let service = GlassService(readReduceTransparency: { false }, accessibilityCenter: .init())
    XCTAssertEqual(service.terminalAppearance, .opaque)
    Defaults[.glassOpacity] = 0.8
    // The settings observation hops to the main actor; give it up to 3 s to land.
    try? await waitFor { service.terminalAppearance != .opaque }
    XCTAssertEqual(
      service.terminalAppearance, .glass(opacity: 0.8),
      "the terminals resolved glass within 3 s of the setting moving below 100%")
    XCTAssertEqual(service.opacity, 0.8, "the live value")
  }

  /// Only Glass turning on or off (the setting crossing 100%) turns the terminals, which rewrites
  /// their config; an opacity change within glass, or a refresh that changes nothing, does not.
  func testOnlyCrossingOneHundredPercentTurnsTheTerminals() {
    Defaults[.glassOpacity] = 0.9
    let service = GlassService(readReduceTransparency: { false }, accessibilityCenter: .init())

    XCTAssertFalse(service.refresh(), "a refresh with nothing changed turns nothing")
    for opacity in [0.85, 0.7, 0.75, 0.95, 0.99] {
      Defaults[.glassOpacity] = opacity
      XCTAssertFalse(service.refresh(), "\(opacity) within glass turns nothing")
      XCTAssertEqual(service.appearance(fullScreen: false), .glass(opacity: opacity))
    }
    Defaults[.glassOpacity] = 1
    XCTAssertTrue(service.refresh(), "100% turns Glass off")
    XCTAssertFalse(service.refresh())
    Defaults[.glassOpacity] = 0.8
    XCTAssertTrue(service.refresh(), "below 100% turns it on")
  }

  /// The service holds the setting as it applies, so a slider position a float step or a fraction
  /// of a percent off a value is that value, and below the floor is the floor.
  func testTheStoredOpacityIsQuantized() {
    Defaults[.glassOpacity] = 0.851
    let service = GlassService(readReduceTransparency: { false }, accessibilityCenter: .init())
    XCTAssertEqual(service.opacity, 0.85)
    Defaults[.glassOpacity] = 0.7 + 6 * 0.05
    service.refresh()
    XCTAssertEqual(service.opacity, 1)
    Defaults[.glassOpacity] = 0.2
    service.refresh()
    XCTAssertEqual(service.opacity, 0.7)
  }
}
