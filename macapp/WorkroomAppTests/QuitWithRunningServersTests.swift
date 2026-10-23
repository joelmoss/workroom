import XCTest

@testable import Workroom

/// What quitting does to running dev servers (#522, ADR 0058): the decision the quit dialog, the
/// SIGTERM handler and an update's relaunch share.
final class QuitWithRunningServersTests: XCTestCase {
  private func action(
    _ setting: QuitWithRunningServers, live: Bool = true, update: Bool = false, canAsk: Bool = true
  ) -> QuitWithRunningServers.Action {
    QuitWithRunningServers.action(
      setting: setting, hasLiveRuns: live, isUpdateRelaunch: update, canAsk: canAsk)
  }

  /// The first quit with a run going asks; once answered, the answer is what quitting does.
  func testTheSettingDecidesAQuitWithARunGoing() {
    XCTAssertEqual(action(.ask), .ask)
    XCTAssertEqual(action(.keepRunning), .keep)
    XCTAssertEqual(action(.stop), .stop)
  }

  /// Nothing to ask about, and nothing to stop, with no run going.
  func testNoRunGoingKeepsAndNeverAsks() {
    for setting in QuitWithRunningServers.allCases {
      XCTAssertEqual(action(setting, live: false), .keep, "\(setting)")
    }
  }

  /// An update's relaunch keeps runs even when the user chose Stop: its moment is not theirs (Q12).
  func testAnUpdateRelaunchAlwaysKeepsRuns() {
    for setting in QuitWithRunningServers.allCases {
      XCTAssertEqual(action(setting, update: true), .keep, "\(setting)")
    }
  }

  /// A SIGTERM quit has nobody to ask: it follows the setting, and keeps runs while it is Ask.
  func testAQuitNobodyCanBeAskedAboutFollowsTheSettingOrKeeps() {
    XCTAssertEqual(action(.ask, canAsk: false), .keep)
    XCTAssertEqual(action(.stop, canAsk: false), .stop)
    XCTAssertEqual(action(.keepRunning, canAsk: false), .keep)
  }
}
