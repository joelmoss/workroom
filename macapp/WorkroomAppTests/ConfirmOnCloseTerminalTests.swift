import Defaults
import XCTest

@testable import Workroom

/// `Defaults[.confirmOnCloseTerminal]` must default to ON (issue #27 asks for a setting that's
/// enabled by default) — the key is absent until the user first toggles it — and otherwise honour
/// the stored value. The `Key`'s `default: true` is what guarantees the default.
final class ConfirmOnCloseTerminalTests: XCTestCase {

  /// The raw UserDefaults key behind `Defaults.Keys.confirmOnCloseTerminal` — used only to
  /// save/restore the real stored value so the test never leaks into the user's defaults.
  private let key = "confirmOnCloseTerminal"
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

  func testEnabledByDefaultWhenUnset() {
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertTrue(Defaults[.confirmOnCloseTerminal])
  }

  func testRespectsStoredValue() {
    Defaults[.confirmOnCloseTerminal] = false
    XCTAssertFalse(Defaults[.confirmOnCloseTerminal])

    Defaults[.confirmOnCloseTerminal] = true
    XCTAssertTrue(Defaults[.confirmOnCloseTerminal])
  }

  /// The setting has to actually reach the close path. Every close-behaviour class now injects
  /// `AppStore.confirmOnCloseOverrideForTesting`, so nothing else exercises the `Defaults` side —
  /// drop it (`?? false`) and the entire unit suite stays green while the shipped checkbox does
  /// nothing. This is the one test that notices.
  ///
  /// Driven through the pure static rather than an `AppStore` on purpose: this class is the sole
  /// writer of the shared key (saved and restored above), which is what keeps the parallel test
  /// workers off each other — see `AppStore.confirmOnCloseOverrideForTesting`.
  func testTheCloseConfirmFallsBackToTheStoredSetting() {
    Defaults[.confirmOnCloseTerminal] = true
    XCTAssertTrue(AppStore.resolveConfirmOnClose(override: nil), "on → the close must prompt")

    Defaults[.confirmOnCloseTerminal] = false
    XCTAssertFalse(AppStore.resolveConfirmOnClose(override: nil), "off → it must not")
  }

  /// …and the override still wins over the setting in both directions, which is what the
  /// close-behaviour tests depend on.
  func testTheTestOverrideWinsOverTheStoredSetting() {
    Defaults[.confirmOnCloseTerminal] = true
    XCTAssertFalse(AppStore.resolveConfirmOnClose(override: false))

    Defaults[.confirmOnCloseTerminal] = false
    XCTAssertTrue(AppStore.resolveConfirmOnClose(override: true))
  }
}
