import Defaults
import XCTest

@testable import Workroom

/// `UITestFixture.applyFixtureDefaults` owns the pref-driven UI state every XCUITest depends on: the
/// inspector (Changes rows, the Markdown preview opened from one, the section headers) and the diff
/// viewer's layout. It exists because the tests can't set those `Defaults` keys themselves: a launch
/// argument lands in the argument domain as a **string**, `Defaults` reads a `Bool` key with `as? Bool`
/// (which fails on a string and returns the key default, `false`), and the argument domain then shadows
/// both the persisted value and every later write — so `-showNotificationsInspector 1` pins the pane
/// shut for the whole run instead of forcing it open.
///
/// Nothing in the app notices if this seam regresses — the failure surfaces only as XCUITests that
/// can't find the panel they were about to assert on, one build later. That is not theoretical: the
/// diff-mode half was missing, and a Dev domain left on side-by-side quietly turned five diff UI tests
/// red (they assert on `diff.line`, which only the unified renderer emits). So it's covered here.
final class UITestFixtureDefaultsTests: XCTestCase {

  private let fixtureKey = "WorkroomUITestFixture"
  private let sectionArgKey = "WorkroomUITestInspectorSection"
  private let diffModeArgKey = "WorkroomUITestDiffViewMode"
  private let visibleKey = "showNotificationsInspector"
  private let activeSectionKey = "inspector.activeSection"
  private let diffModeKey = "diffViewMode"

  /// Every raw key this test writes, saved/restored so it never leaks into the real Dev defaults
  /// (the unit tests run in the app's own UserDefaults domain — cf. `ActivitySectionTests`).
  private var keys: [String] {
    [fixtureKey, sectionArgKey, diffModeArgKey, visibleKey, activeSectionKey, diffModeKey]
  }
  private var saved: [String: Any?] = [:]

  override func setUp() {
    super.setUp()
    for key in keys {
      saved[key] = UserDefaults.standard.object(forKey: key)
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

  // MARK: inspector

  /// Fixture mode with no section argument: the pane opens on Changes — the state most XCUITests
  /// assume, whatever the developer's machine last persisted.
  func testFixtureModeOpensTheInspectorOnChanges() {
    UserDefaults.standard.set(true, forKey: fixtureKey)
    Defaults[.showInspector] = false
    Defaults[.activeInspectorSection] = .history

    UITestFixture.applyFixtureDefaults()

    XCTAssertTrue(Defaults[.showInspector], "fixture mode should open the inspector pane")
    XCTAssertEqual(Defaults[.activeInspectorSection], .changes, "default section is Changes")
  }

  /// `-WorkroomUITestInspectorSection <raw>` picks the pane. The flag is read with
  /// `UserDefaults.string(forKey:)`, which is exactly what makes a launch argument usable here.
  func testSectionArgumentSelectsThePane() {
    UserDefaults.standard.set(true, forKey: fixtureKey)
    UserDefaults.standard.set("history", forKey: sectionArgKey)

    UITestFixture.applyFixtureDefaults()

    XCTAssertTrue(Defaults[.showInspector])
    XCTAssertEqual(Defaults[.activeInspectorSection], .history)
  }

  /// An unrecognised section falls back to Changes rather than leaving the pane on whatever was
  /// persisted — a typo'd flag must still produce a deterministic launch.
  func testUnknownSectionArgumentFallsBackToChanges() {
    UserDefaults.standard.set(true, forKey: fixtureKey)
    UserDefaults.standard.set("bogus", forKey: sectionArgKey)
    Defaults[.activeInspectorSection] = .files

    UITestFixture.applyFixtureDefaults()

    XCTAssertEqual(UITestFixture.inspectorSection, .changes)
    XCTAssertEqual(Defaults[.activeInspectorSection], .changes)
  }

  // MARK: diff view mode

  /// Fixture mode with no diff-mode argument pins **unified** — the shipped default — over a persisted
  /// side-by-side choice. This is the assertion that would have caught the red `diff.line` tests: they
  /// say nothing about the layout, so the fixture must not let the developer's Settings pick it.
  func testFixtureModeForcesUnifiedOverAPersistedSideBySide() {
    UserDefaults.standard.set(true, forKey: fixtureKey)
    Defaults[.diffViewMode] = .sideBySide

    UITestFixture.applyFixtureDefaults()

    XCTAssertEqual(Defaults[.diffViewMode], .unified)
  }

  /// `-WorkroomUITestDiffViewMode sideBySide` opts a test into the two-column layout.
  func testDiffModeArgumentSelectsSideBySide() {
    UserDefaults.standard.set(true, forKey: fixtureKey)
    UserDefaults.standard.set("sideBySide", forKey: diffModeArgKey)

    UITestFixture.applyFixtureDefaults()

    XCTAssertEqual(UITestFixture.diffViewMode, .sideBySide)
    XCTAssertEqual(Defaults[.diffViewMode], .sideBySide)
  }

  /// A typo'd layout falls back to unified rather than to whatever was persisted.
  func testUnknownDiffModeArgumentFallsBackToUnified() {
    UserDefaults.standard.set(true, forKey: fixtureKey)
    UserDefaults.standard.set("bogus", forKey: diffModeArgKey)
    Defaults[.diffViewMode] = .sideBySide

    UITestFixture.applyFixtureDefaults()

    XCTAssertEqual(Defaults[.diffViewMode], .unified)
  }

  // MARK: production

  /// Inert outside fixture mode: a real user's persisted state must survive untouched — the inspector
  /// they closed, the section they left, and the diff layout they picked in Settings.
  func testDoesNothingWhenNotInFixtureMode() {
    Defaults[.showInspector] = false
    Defaults[.activeInspectorSection] = .history
    Defaults[.diffViewMode] = .sideBySide

    UITestFixture.applyFixtureDefaults()

    XCTAssertFalse(Defaults[.showInspector], "a normal launch keeps the user's closed pane")
    XCTAssertEqual(Defaults[.activeInspectorSection], .history, "and their active section")
    XCTAssertEqual(Defaults[.diffViewMode], .sideBySide, "and their diff layout")
  }
}
