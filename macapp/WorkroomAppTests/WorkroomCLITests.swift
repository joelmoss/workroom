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

  /// Value: protects=`workroom` runs in a pane with no CLI installed, and is this app's own build;
  /// fails_when=the app's CLI folder is not first or replaces the inherited PATH; seam=none;
  /// no_claim=the shell keeping it (serve.rs forwards the attach environment)
  func testAPanePutsTheAppsOwnCLIFirstOnItsPath() {
    XCTAssertEqual(
      WorkroomCLI.panePath(
        cliDirectory: "/Apps/Workroom.app/Contents/Resources", inheritedPath: "/usr/bin:/bin"),
      "/Apps/Workroom.app/Contents/Resources:/usr/bin:/bin")
    XCTAssertNil(WorkroomCLI.panePath(cliDirectory: nil, inheritedPath: "/usr/bin"))
  }
}
