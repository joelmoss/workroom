import Defaults
import XCTest

@testable import Workroom

/// `ActivitySection` drives the right activity bar (the vertical icon rail) and, via `subSections`,
/// which stacked panels each pane shows. Three things must hold: `allCases` is the bar order (a silent
/// reorder would move the icons), the `subSections` mapping is exact (it decides what the Changes vs
/// Files pane renders and how the per-workroom collapse/weight vectors are sliced), and a stored raw
/// string matching no case falls back to `.changes` (a rename or corrupt `Defaults` value must not
/// crash or blank the inspector). The fallback is provided by `Defaults` + `PreferRawRepresentable`.
final class ActivitySectionTests: XCTestCase {

  /// The raw UserDefaults key behind `Defaults.Keys.activeInspectorSection` — saved/restored so the
  /// test never leaks into real defaults, and used to inject a corrupt value.
  private let key = "inspector.activeSection"
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

  func testAllCasesOrderMatchesBarOrder() {
    XCTAssertEqual(ActivitySection.allCases, [.changes, .history, .files])
  }

  func testEveryCaseHasNonEmptyLabelSystemImageAndShortcut() {
    for section in ActivitySection.allCases {
      XCTAssertFalse(section.label.isEmpty, "\(section) has an empty label")
      XCTAssertFalse(section.systemImage.isEmpty, "\(section) has an empty systemImage")
      XCTAssertFalse(section.shortcutHint.isEmpty, "\(section) has an empty shortcut hint")
    }
  }

  /// The pane composition: Changes stacks Changes + Pull Request; Files is solo. Every listed
  /// sub-section must be non-empty (a pane with no sub-sections would render blank).
  func testSubSectionsMapping() {
    XCTAssertEqual(ActivitySection.changes.subSections, [.changes, .pullRequest])
    XCTAssertEqual(ActivitySection.files.subSections, [.files])
    XCTAssertEqual(ActivitySection.history.subSections, [.history])
    for section in ActivitySection.allCases {
      XCTAssertFalse(section.subSections.isEmpty, "\(section) pane has no sub-sections")
    }
  }

  /// The collapse/weight vectors are stored in `InspectorSectionKind.allCases` order; a pane
  /// slices/writes them back by `storeIndex`, so the indices must be stable.
  func testStoreIndexMatchesCanonicalOrder() {
    XCTAssertEqual(InspectorSectionKind.changes.storeIndex, 0)
    XCTAssertEqual(InspectorSectionKind.files.storeIndex, 1)
    XCTAssertEqual(InspectorSectionKind.pullRequest.storeIndex, 2)
    XCTAssertEqual(InspectorSectionKind.history.storeIndex, 3)
  }

  func testDefaultsToChangesWhenUnset() {
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertEqual(Defaults[.activeInspectorSection], .changes)
  }

  func testRoundTripsAValidValue() {
    Defaults[.activeInspectorSection] = .files
    XCTAssertEqual(Defaults[.activeInspectorSection], .files)
  }

  /// A corrupt/renamed raw string deserialises to `nil`, and `Defaults` falls back to `.changes`.
  func testCorruptStoredValueFallsBackToChanges() {
    UserDefaults.standard.set("bogus", forKey: key)
    XCTAssertEqual(Defaults[.activeInspectorSection], .changes)
  }
}
