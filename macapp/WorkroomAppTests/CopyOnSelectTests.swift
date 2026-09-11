import Defaults
import XCTest

@testable import Workroom

/// `Defaults[.copyOnSelect]` must default to ON — the key is absent until the user first toggles it
/// — and otherwise honour the stored value. The `Key`'s `default: true` is what guarantees this;
/// the old hand-rolled `object(forKey:) as? Bool ?? true` (and the latent bug where a bare
/// `bool(forKey:)` would have defaulted to `false`) is gone by construction.
final class CopyOnSelectTests: XCTestCase {

  /// The raw UserDefaults key behind `Defaults.Keys.copyOnSelect` — used only to save/restore the
  /// real stored value so the test never leaks into the user's defaults.
  private let key = "copyOnSelect"
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

  func testEnabledByDefaultWhenUnset() {
    UserDefaults.app.removeObject(forKey: key)
    XCTAssertTrue(Defaults[.copyOnSelect])
  }

  func testRespectsStoredValue() {
    Defaults[.copyOnSelect] = false
    XCTAssertFalse(Defaults[.copyOnSelect])

    Defaults[.copyOnSelect] = true
    XCTAssertTrue(Defaults[.copyOnSelect])
  }
}
