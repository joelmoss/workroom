import Observation
import XCTest

@testable import Workroom

/// `RootWindow` builds its `AppStore` while SwiftUI evaluates the window's content, under
/// observation tracking. Building a store must not write anything that evaluation observed, or the
/// next window's store invalidates the last evaluation, which builds another store, forever: the app
/// hangs at launch with `WorkroomApp.body` and `RootWindow.body` re-running nonstop (found merging
/// #656, whose registration on `ProjectStore.sessionRestoreObservers` was observed).
@MainActor
final class WindowStoreObservationTests: XCTestCase {
  func testBuildingAWindowStoreDoesNotInvalidateTheEvaluationThatBuiltTheLastOne() {
    let projects = ProjectStore()
    let section = TerminalsSection()
    let registry = WindowRegistry()
    let changed = LockedFlag()
    var first: AppStore?
    withObservationTracking {
      first = AppStore(
        projectStore: projects, terminalsSection: section, notifications: registry.notifications)
    } onChange: {
      changed.set()
    }
    let second = AppStore(
      projectStore: projects, terminalsSection: section, notifications: registry.notifications)
    XCTAssertFalse(changed.value, "building a window store invalidated the last evaluation")
    withExtendedLifetime((first, second)) {}
  }
}

/// `onChange` may run off the main actor.
private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  var value: Bool { lock.withLock { flag } }
  func set() { lock.withLock { flag = true } }
}
