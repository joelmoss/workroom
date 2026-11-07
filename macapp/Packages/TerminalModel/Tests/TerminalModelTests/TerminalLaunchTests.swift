import TerminalModel
import XCTest

/// Which terminal tabs a saved layout keeps, and which are run tabs (#522).
final class TerminalLaunchTests: XCTestCase {
  func testALoginShellIsSavedAndIsNoRunTab() {
    let launch = TerminalLaunch(isRunSession: false, runsCommand: false)
    XCTAssertEqual(launch, .shell)
    XCTAssertTrue(launch.isSaved)
    XCTAssertFalse(launch.isRunSession)
  }

  func testACommandInThePanesOwnProcessIsNotSaved() {
    let launch = TerminalLaunch(isRunSession: false, runsCommand: true)
    XCTAssertEqual(launch, .command)
    XCTAssertFalse(launch.isSaved, "its process dies with the app")
    XCTAssertFalse(launch.isRunSession)
  }

  func testARunSessionIsSavedAsARunTabWhateverItsCommand() {
    for runsCommand in [true, false] {
      let launch = TerminalLaunch(isRunSession: true, runsCommand: runsCommand)
      XCTAssertEqual(launch, .runSession)
      XCTAssertTrue(launch.isSaved, "its session outlives the app")
      XCTAssertTrue(launch.isRunSession)
    }
  }
}
