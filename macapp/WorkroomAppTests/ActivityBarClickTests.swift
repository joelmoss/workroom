import Defaults
import Observation
import XCTest

@testable import Workroom

/// A click on the already-active activity-bar icon toggles the inspector through
/// `Defaults[.showInspector]` alone, which a `@Default` view reads only asynchronously. The click
/// must still change something Observation tracks, or the pane opens or closes only at the next
/// unrelated event.
@MainActor
final class ActivityBarClickTests: XCTestCase {
  func testClickingTheActiveIconInvalidatesObservers() {
    let store = AppStore()
    store.isolatesInspectorSectionForTesting = true
    store.activeInspectorSection = .changes
    let shown = Defaults[.showInspector]
    defer { Defaults[.showInspector] = shown }
    Defaults[.showInspector] = true

    var invalidated = false
    withObservationTracking {
      _ = store.inspectorToggles
    } onChange: {
      invalidated = true
    }
    store.apply(.iconClick(.changes))

    XCTAssertFalse(Defaults[.showInspector], "clicking the active icon closes the inspector")
    XCTAssertEqual(store.activeInspectorSection, .changes)
    XCTAssertTrue(invalidated, "the click must invalidate the views that read showInspector")
  }
}
