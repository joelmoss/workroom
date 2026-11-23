import AppKit
import Defaults
import DesignSystem
import SwiftUI
import XCTest

@testable import Workroom

/// The measurement taken before touching anything: `ThemePickerRow` reads the theme environment
/// (`\.themeTokens`) for its own chrome (border/hover/accent colours), and the root injecting it
/// reads the `@Observable` `ThemeService`, so an arrow-key press (`applyFamily` → `tokens`
/// replaced) re-injects the tokens and invalidates every row currently materialized by the
/// picker's `LazyVStack`. The open question was never *whether*
/// that happens (it does, by construction) but whether it is perceptible now that the 2026-08-06
/// preview cache already removed the disk I/O side of the same keypress. Hosted at the picker's
/// real popover size (`ThemePicker.contentSize`) so the materialized-row count matches production,
/// not an arbitrarily tall test window.
@MainActor
final class ThemePickerInvalidationTests: XCTestCase {
  private var savedLight: String!
  private var savedDark: String!
  private var savedAppearance: AppearanceMode!
  private var savedFavouriteFamilies: Set<String>!
  private var savedFavouriteThemes: Set<String>!

  override func setUp() async throws {
    try await super.setUp()
    savedLight = Defaults[.lightTheme]
    savedDark = Defaults[.darkTheme]
    savedAppearance = Defaults[.appearance]
    savedFavouriteFamilies = Defaults[.favouriteFamilies]
    savedFavouriteThemes = Defaults[.favouriteThemes]
    Defaults[.favouriteFamilies] = []
    Defaults[.favouriteThemes] = []
  }

  override func tearDown() async throws {
    Defaults[.lightTheme] = savedLight
    Defaults[.darkTheme] = savedDark
    Defaults[.appearance] = savedAppearance
    Defaults[.favouriteFamilies] = savedFavouriteFamilies
    Defaults[.favouriteThemes] = savedFavouriteThemes
    try await super.tearDown()
  }

  private func host(tab: ThemePickerTab = .family) -> (NSWindow, NSView) {
    // Rooted as every production host is: the picker opens in a popover of an injected tree.
    let hosting = NSHostingView(rootView: ThemePicker(tab: tab).themeTokensRoot())
    hosting.frame = NSRect(
      origin: .zero,
      size: NSSize(width: ThemePicker.contentSize.width, height: ThemePicker.contentSize.height))
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    // Released at the end of the test, not only closed: a closed window's picker stays alive and
    // keeps rebuilding its rows as the favourites change, which a later test's count would include.
    addTeardownBlock { @MainActor in window.contentView = nil }
    return (window, hosting)
  }

  /// No live terminal is registered with `ThemeService.shared` in this bare harness, so
  /// `applyFamily`'s per-window `TerminalPanes.applyThemeToAll` sweep is a no-op — this isolates
  /// the cost this TODO entry is about (the picker's own re-render) from the per-surface reconfigure
  /// a real window's terminals would also pay. The app-global engine reload is NOT excluded: it
  /// moved into `applyActiveTheme` itself (WORKROOM-3R) and now runs once per apply regardless, which
  /// is the same single reload a real picker keystroke pays.
  func testArrowKeyReapplyRendersUnderTimeCeiling() throws {
    let workroom = ThemeCatalog.defaultFamily
    Defaults[.lightTheme] = workroom.light
    Defaults[.darkTheme] = workroom.dark
    let (window, view) = host()
    defer { window.close() }
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(
      ThemePickerRow.bodyPasses, 0, "the fixture must actually render family rows")

    let otherFamily = try XCTUnwrap(
      ThemeCatalog.families.first { $0.name != "Workroom" },
      "fixture needs a second family to switch to")

    // The fastest of several switches, back and forth, not one: the time is wall-clock, so a
    // machine busy with other work stretches any single switch past the ceiling (#311). A real
    // regression is in every switch, so the fastest still shows it.
    var samples: [(elapsed: TimeInterval, passes: Int)] = []
    for family in [otherFamily, workroom, otherFamily, workroom, otherFamily] {
      ThemePickerRow.bodyPasses = 0
      let started = Date()
      ThemeService.shared.applyFamily(family)
      // Waited for far past the ceiling, so a switch a busy machine slows still gets its rows
      // re-rendered and is merely slow, while one that never re-renders them fails.
      settle(view, seconds: 5, until: { ThemePickerRow.bodyPasses > 0 })
      samples.append((Date().timeIntervalSince(started), ThemePickerRow.bodyPasses))
      XCTAssertGreaterThan(
        ThemePickerRow.bodyPasses, 0,
        "switching to \(family.name) did not re-render the rows that read tokens within 5s")
    }
    let fastest = try XCTUnwrap(samples.min { $0.elapsed < $1.elapsed })
    let all = samples.map { String(format: "%.3f", $0.elapsed) }.joined(separator: ", ")
    // Measured (2026-08-13, this fixture): ~8 rows rebuilt (the visible rows in a 300×420 popover),
    // ~0.07s elapsed — comfortably clear of "perceptible", let alone the multi-second WORKROOM-2B
    // App Hang threshold this test family exists to catch. 0.3s leaves real margin over that
    // measurement (some of which is `settle()`'s own 0.02s poll granularity, not row-render work)
    // while still catching a row body that got expensive: 50ms more per row fails it (0.44s at
    // best). It does not catch the preview cache going missing, whose file reads cost a few
    // milliseconds here (measured 2026-10-03: 0.030s at best with the cache off). The cache's own
    // tests are in ThemeServiceTests.
    XCTAssertLessThan(
      fastest.elapsed, 0.3,
      "re-rendering the picker's visible rows after one arrow-key apply took at best "
        + "\(String(format: "%.3f", fastest.elapsed))s (\(fastest.passes) row passes; all: \(all)) "
        + "— perceptible as a keypress stall")
  }

  /// Starring a row rebuilds that row alone. The picker reads the favourites, so a star re-renders
  /// it, and every row it has materialised is handed its inputs again: only the starred one's change,
  /// so only that one's body runs. On the Family tab, with a family's star…
  func testStarringAFamilyRebuildsOnlyItsRow() throws {
    try assertStarringRebuildsOneRow(tab: .family, .family(ThemeCatalog.defaultFamily.name))
  }

  /// …and on the Dark tab, with a theme's.
  func testStarringAThemeRebuildsOnlyItsRow() throws {
    try assertStarringRebuildsOneRow(tab: .dark, .theme(ThemeCatalog.defaultFamily.dark))
  }

  private func assertStarringRebuildsOneRow(tab: ThemePickerTab, _ favourite: ThemeFavourite)
    throws
  {
    let workroom = ThemeCatalog.defaultFamily
    Defaults[.lightTheme] = workroom.light
    Defaults[.darkTheme] = workroom.dark
    let (window, view) = host(tab: tab)
    defer { window.close() }
    view.layoutSubtreeIfNeeded()
    // Until the rows stop rebuilding: the list settles on the current choice and fades in first.
    var passes = -1
    var quiet = 0
    let deadline = Date().addingTimeInterval(5)
    while quiet < 3, Date() < deadline {
      settle(view, seconds: 0.2)
      quiet = ThemePickerRow.bodyPasses == passes ? quiet + 1 : 0
      passes = ThemePickerRow.bodyPasses
    }
    let materialised = ThemePickerRow.bodyPasses
    XCTAssertGreaterThan(materialised, 2, "the fixture must render several rows")

    ThemePickerRow.bodyPasses = 0
    ThemeFavourites.toggle(favourite)
    settle(view, seconds: 0.5)
    XCTAssertEqual(
      ThemePickerRow.bodyPasses, 1,
      "starring \(favourite.name) rebuilt \(ThemePickerRow.bodyPasses) row bodies, of "
        + "\(materialised) materialised")
  }
}
