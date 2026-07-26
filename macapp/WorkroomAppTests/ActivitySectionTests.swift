import Defaults
import XCTest

@testable import Workroom

/// `ActivitySection` drives the right activity bar (the vertical icon rail) and, via `subSections`,
/// which stacked panels each pane shows. Three things must hold: `allCases` is the bar order (a silent
/// reorder would move the icons), the `subSections` mapping is exact (it decides what the Changes vs
/// Files pane renders and how the per-workroom collapse/weight vectors are sliced), and a stored raw
/// string matching no case falls back to `.changes` (a rename or corrupt `Defaults` value must not
/// crash or blank the inspector). The fallback is provided by `Defaults` + `PreferRawRepresentable`,
/// and is asserted here against a private probe key rather than the shipped one — see `probe`.
final class ActivitySectionTests: XCTestCase {

  /// A private probe key of the same shape as `Defaults.Keys.activeInspectorSection`, because what the
  /// serialization tests below actually assert is a property of the **type** (`PreferRawRepresentable`
  /// storing the bare raw string, and an unknown one falling back to the key's default) — which a key
  /// nobody else reads proves identically.
  ///
  /// Deliberately not the shipped key: the parallel test workers share one UserDefaults domain, and
  /// writing `inspector.activeSection` from a second class raced `SharedPrefDefaultsTests` (a `.files`
  /// write from here landing between that seam's write and its read — about one failure in five 6-class
  /// parallel iterations). That class is now the suite's only writer of the real key, and it covers the
  /// shipped default. See its class doc.
  private let probe = Defaults.Key<ActivitySection>("test.activeSectionProbe", default: .changes)
  private let probeKey = "test.activeSectionProbe"

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: probeKey)
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
    UserDefaults.standard.removeObject(forKey: probeKey)
    XCTAssertEqual(Defaults[probe], .changes)
  }

  /// Stored as the **bare raw string** (`PreferRawRepresentable`), not a JSON-encoded value — that's
  /// what makes a launch argument / hand-written pref readable, and what the fallback below keys on.
  func testRoundTripsAValidValueAsItsRawString() {
    Defaults[probe] = .files
    XCTAssertEqual(Defaults[probe], .files)
    XCTAssertEqual(UserDefaults.standard.string(forKey: probeKey), "files")
  }

  /// A corrupt/renamed raw string deserialises to `nil`, and `Defaults` falls back to `.changes`.
  func testCorruptStoredValueFallsBackToChanges() {
    UserDefaults.standard.set("bogus", forKey: probeKey)
    XCTAssertEqual(Defaults[probe], .changes)
  }
}
