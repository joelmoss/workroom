import AppKit
import Defaults
import SwiftUI
import XCTest

@testable import Workroom

/// The measurement TODOS.md asked for before touching anything: `FamilyRow` reads
/// `ThemeService.shared.tokens` for its own chrome (border/hover/accent colours), and
/// `ThemeService` is `@Observable`, so every row that touched `tokens` during its last body pass
/// is a real dependency — an arrow-key press (`applyFamily` → `tokens` replaced) invalidates every
/// row currently materialized by the picker's `LazyVStack`. The open question was never *whether*
/// that happens (it does, by construction) but whether it is perceptible now that the 2026-08-06
/// preview cache already removed the disk I/O side of the same keypress. Hosted at the picker's
/// real popover size (`ThemePicker.contentSize`) so the materialized-row count matches production,
/// not an arbitrarily tall test window.
@MainActor
final class ThemePickerInvalidationTests: XCTestCase {
  private var savedFamily: String!
  private var savedAppearance: ThemePreference!

  override func setUp() {
    savedFamily = Defaults[.themeFamily]
    savedAppearance = Defaults[.theme]
  }

  override func tearDown() {
    Defaults[.themeFamily] = savedFamily
    Defaults[.theme] = savedAppearance
  }

  private func host() -> (NSWindow, NSView) {
    let hosting = NSHostingView(rootView: ThemePicker())
    hosting.frame = NSRect(
      origin: .zero,
      size: NSSize(width: ThemePicker.contentSize.width, height: ThemePicker.contentSize.height))
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    return (window, hosting)
  }

  /// No live terminal is registered with `ThemeService.shared` in this bare harness, so
  /// `applyFamily`'s `TerminalSessions.applyThemeToAll` loop is a no-op — this isolates exactly the
  /// cost this TODO entry is about (the picker's own re-render), not the engine reload path a real
  /// window's terminals would also pay (that path is unrelated, already-shipped behaviour).
  func testArrowKeyReapplyRendersUnderTimeCeiling() throws {
    Defaults[.themeFamily] = "Workroom"
    let (window, view) = host()
    defer { window.close() }
    view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(
      FamilyRow.bodyPasses, 0, "the fixture must actually render family rows")

    let otherFamily = try XCTUnwrap(
      ThemeService.families.first { $0.name != "Workroom" }?.name,
      "fixture needs a second family to switch to")

    FamilyRow.bodyPasses = 0
    let started = Date()
    ThemeService.shared.applyFamily(otherFamily)
    settle(view, until: { FamilyRow.bodyPasses > 0 })
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertGreaterThan(
      FamilyRow.bodyPasses, 0,
      "applyFamily must actually re-render the rows that read tokens — a gate of zero here would "
        + "mean the settle() ceiling was hit, not that the storm disappeared")
    // Measured (2026-08-13, this fixture): ~8 rows rebuilt (the visible rows in a 300×420 popover),
    // ~0.07s elapsed — comfortably clear of "perceptible", let alone the multi-second WORKROOM-2B
    // App Hang threshold this test family exists to catch. 0.3s leaves real margin over that
    // measurement (some of which is `settle()`'s own 0.02s poll granularity, not row-render work)
    // while still catching a real regression — e.g. the preview cache disappearing would put file
    // I/O back on this path and balloon it by orders of magnitude.
    XCTAssertLessThan(
      elapsed, 0.3,
      "re-rendering the picker's visible rows after one arrow-key apply took "
        + "\(String(format: "%.3f", elapsed))s (\(FamilyRow.bodyPasses) row passes) — perceptible "
        + "as a keypress stall")
  }
}
