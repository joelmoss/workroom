import Defaults
import XCTest

@testable import Workroom

/// `SettingsPane` drives the Settings-window sidebar. Two things must hold: `allCases` is the sidebar
/// order (a silent reorder would move the panes), and a stored raw string that matches no case falls
/// back to `.general` (a rename or corrupt `Defaults` value must not crash or blank the window). The
/// fallback is provided by `Defaults` + `PreferRawRepresentable` — this pins it.
final class SettingsPaneTests: XCTestCase {

  /// The raw UserDefaults key behind `Defaults.Keys.settingsSelectedPane` — used to save/restore the
  /// real stored value so the test never leaks into the user's defaults, and to inject a corrupt one.
  private let key = "settings.selectedPane"
  private var saved: Any?

  override func setUp() {
    super.setUp()
    saved = UserDefaults.standard.object(forKey: key)
  }

  override func tearDown() {
    if let saved {
      UserDefaults.standard.set(saved, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
    super.tearDown()
  }

  func testAllCasesOrderMatchesSidebarOrder() {
    XCTAssertEqual(SettingsPane.allCases, [.general, .appearance, .terminal, .agent])
  }

  func testEveryCaseHasNonEmptyLabelAndSystemImage() {
    for pane in SettingsPane.allCases {
      XCTAssertFalse(pane.label.isEmpty, "\(pane) has an empty label")
      XCTAssertFalse(pane.systemImage.isEmpty, "\(pane) has an empty systemImage")
    }
  }

  func testDefaultsToGeneralWhenUnset() {
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertEqual(Defaults[.settingsSelectedPane], .general)
  }

  func testRoundTripsAValidValue() {
    Defaults[.settingsSelectedPane] = .agent
    XCTAssertEqual(Defaults[.settingsSelectedPane], .agent)
  }

  /// A `PreferRawRepresentable` enum persists as its bare raw string, so a corrupt/renamed value is
  /// simulated by writing a plain string straight to the suite — it can't be injected through the
  /// typed `Key`. Deserialising it yields `nil`, and `Defaults` falls back to the key's default.
  func testCorruptStoredValueFallsBackToGeneral() {
    UserDefaults.standard.set("bogus", forKey: key)
    XCTAssertEqual(Defaults[.settingsSelectedPane], .general)
  }
}
