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
    saved = UserDefaults.app.object(forKey: key)
  }

  override func tearDown() {
    if let saved {
      UserDefaults.app.set(saved, forKey: key)
    } else {
      UserDefaults.app.removeObject(forKey: key)
    }
    super.tearDown()
  }

  func testAllCasesOrderMatchesSidebarOrder() {
    XCTAssertEqual(
      SettingsPane.allCases,
      [.general, .notifications, .appearance, .terminal, .agent, .remoteHosts, .about])
  }

  func testEveryCaseHasNonEmptyLabelAndSystemImage() {
    for pane in SettingsPane.allCases {
      XCTAssertFalse(pane.label.isEmpty, "\(pane) has an empty label")
      XCTAssertFalse(pane.systemImage.isEmpty, "\(pane) has an empty systemImage")
    }
  }

  func testDefaultsToGeneralWhenUnset() {
    UserDefaults.app.removeObject(forKey: key)
    XCTAssertEqual(Defaults[.settingsSelectedPane], .general)
  }

  /// Value: protects=the Settings header's back and forward buttons walk the panes visited, as
  /// System Settings' do; fails_when=back forgets a pane, forward survives a new choice, or choosing
  /// the open pane adds a step; why_new=new history; seam=none; no_claim=the buttons' rendering
  func testBackAndForwardWalkThePanesVisited() {
    var history = SettingsHistory()
    XCTAssertFalse(history.canGoBack)
    history.leave(.general, for: .general)
    XCTAssertFalse(history.canGoBack, "choosing the open pane added a step")
    history.leave(.general, for: .terminal)
    history.leave(.terminal, for: .about)
    XCTAssertEqual(history.goBack(from: .about), .terminal)
    XCTAssertEqual(history.goBack(from: .terminal), .general)
    XCTAssertNil(history.goBack(from: .general))
    XCTAssertEqual(history.goForward(from: .general), .terminal)
    history.leave(.terminal, for: .agent)
    XCTAssertFalse(history.canGoForward, "a new choice kept the old forward steps")
    XCTAssertEqual(history.goBack(from: .agent), .terminal)
  }

  /// A `PreferRawRepresentable` enum persists as its bare raw string, so a corrupt/renamed value is
  /// simulated by writing a plain string straight to the suite — it can't be injected through the
  /// typed `Key`. Deserialising it yields `nil`, and `Defaults` falls back to the key's default.
  func testCorruptStoredValueFallsBackToGeneral() {
    UserDefaults.app.set("bogus", forKey: key)
    XCTAssertEqual(Defaults[.settingsSelectedPane], .general)
  }
}
