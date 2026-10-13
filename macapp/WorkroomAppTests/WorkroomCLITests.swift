import XCTest

@testable import Workroom

final class WorkroomCLITests: XCTestCase {
  /// Config-only `delete-project` runs no teardown, so it must not pay for a shell probe. The
  /// `await` placement itself is only reachable through the bundled binary; the gating decision is
  /// factored out so the part that can be got wrong is the part under test.
  func testOnlyCascadingDeleteProjectModesRunScripts() {
    XCTAssertFalse(
      WorkroomCLI.deleteProjectRunsScripts(withWorkrooms: false, fromDisk: false),
      "config-only removal touches nothing on disk")
    XCTAssertTrue(WorkroomCLI.deleteProjectRunsScripts(withWorkrooms: true, fromDisk: false))
    XCTAssertTrue(WorkroomCLI.deleteProjectRunsScripts(withWorkrooms: false, fromDisk: true))
  }
}
