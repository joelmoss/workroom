import Defaults
import XCTest

@testable import Workroom

/// `UITestFixture.applyInspectorDefaults` owns the inspector state every XCUITest that opens
/// something *inside* the inspector depends on (Changes rows, the Markdown preview opened from one,
/// the section headers). It exists because the tests can't set those `Defaults` keys themselves: a
/// launch argument lands in the argument domain as a **string**, `Defaults` reads a `Bool` key with
/// `as? Bool` (which fails on a string and returns the key default, `false`), and the argument domain
/// then shadows both the persisted value and every later write — so `-showNotificationsInspector 1`
/// pins the pane shut for the whole run instead of forcing it open.
///
/// Nothing in the app notices if this seam regresses — the failure surfaces only as XCUITests that
/// can't find the panel they were about to assert on, one build later. So it's covered here.
final class UITestFixtureInspectorTests: XCTestCase {

  private let fixtureKey = "WorkroomUITestFixture"
  private let sectionArgKey = "WorkroomUITestInspectorSection"
  private let visibleKey = "showNotificationsInspector"
  private let activeSectionKey = "inspector.activeSection"

  /// The four raw keys this test writes, saved/restored so it never leaks into the real Dev defaults
  /// (the unit tests run in the app's own UserDefaults domain — cf. `ActivitySectionTests`).
  private var saved: [String: Any?] = [:]

  override func setUp() {
    super.setUp()
    for key in [fixtureKey, sectionArgKey, visibleKey, activeSectionKey] {
      saved[key] = UserDefaults.standard.object(forKey: key)
    }
    for key in [fixtureKey, sectionArgKey, visibleKey, activeSectionKey] {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  override func tearDown() {
    for (key, value) in saved {
      if let value {
        UserDefaults.standard.set(value, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    saved = [:]
    super.tearDown()
  }

  /// Fixture mode with no section argument: the pane opens on Changes — the state most XCUITests
  /// assume, whatever the developer's machine last persisted.
  func testFixtureModeOpensTheInspectorOnChanges() {
    UserDefaults.standard.set(true, forKey: fixtureKey)
    Defaults[.showInspector] = false
    Defaults[.activeInspectorSection] = .history

    UITestFixture.applyInspectorDefaults()

    XCTAssertTrue(Defaults[.showInspector], "fixture mode should open the inspector pane")
    XCTAssertEqual(Defaults[.activeInspectorSection], .changes, "default section is Changes")
  }

  /// `-WorkroomUITestInspectorSection <raw>` picks the pane. The flag is read with
  /// `UserDefaults.string(forKey:)`, which is exactly what makes a launch argument usable here.
  func testSectionArgumentSelectsThePane() {
    UserDefaults.standard.set(true, forKey: fixtureKey)
    UserDefaults.standard.set("history", forKey: sectionArgKey)

    UITestFixture.applyInspectorDefaults()

    XCTAssertTrue(Defaults[.showInspector])
    XCTAssertEqual(Defaults[.activeInspectorSection], .history)
  }

  /// An unrecognised section falls back to Changes rather than leaving the pane on whatever was
  /// persisted — a typo'd flag must still produce a deterministic launch.
  func testUnknownSectionArgumentFallsBackToChanges() {
    UserDefaults.standard.set(true, forKey: fixtureKey)
    UserDefaults.standard.set("bogus", forKey: sectionArgKey)
    Defaults[.activeInspectorSection] = .files

    UITestFixture.applyInspectorDefaults()

    XCTAssertEqual(UITestFixture.inspectorSection, .changes)
    XCTAssertEqual(Defaults[.activeInspectorSection], .changes)
  }

  /// Inert outside fixture mode: a real user's persisted inspector state must survive untouched.
  func testDoesNothingWhenNotInFixtureMode() {
    Defaults[.showInspector] = false
    Defaults[.activeInspectorSection] = .history

    UITestFixture.applyInspectorDefaults()

    XCTAssertFalse(Defaults[.showInspector], "a normal launch keeps the user's closed pane")
    XCTAssertEqual(Defaults[.activeInspectorSection], .history, "and their active section")
  }
}
