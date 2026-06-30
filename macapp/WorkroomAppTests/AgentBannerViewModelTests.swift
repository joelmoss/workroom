import XCTest

@testable import Workroom

/// The pure banner presentation (issue #49, T8): which controls show per state and the
/// destructive-fix gating. The SwiftUI view is a dumb renderer over this.
final class AgentBannerViewModelTests: XCTestCase {
  private func failure(_ exit: Int32 = 1, command: String? = "rails server") -> FailedCommand {
    FailedCommand(
      command: command, cwd: "/app", exitCode: exit, shell: "zsh", output: "boom", isRunTab: false,
      isRemote: false)
  }

  func testAwaitingShowsDiagnoseOnly() {
    let vm = AgentBannerViewModel(state: .awaitingDiagnose(failure(127)))
    XCTAssertEqual(vm.style, .awaiting)
    XCTAssertTrue(vm.headline.contains("127"))
    XCTAssertTrue(vm.showsDiagnoseButton)
    XCTAssertFalse(vm.showsInsertFix)
    XCTAssertFalse(vm.showsInvestigate)
    XCTAssertTrue(vm.showsDismiss)
  }

  func testLoading() {
    let vm = AgentBannerViewModel(state: .loading(failure()))
    XCTAssertEqual(vm.style, .loading)
    XCTAssertFalse(vm.showsDiagnoseButton)
    XCTAssertFalse(vm.showsInsertFix)
  }

  func testReadyWithSafeFix() {
    let diag = AgentDiagnosis(
      summary: "port in use", fixCommand: "kill $(lsof -ti:3000)", detail: "3000 busy")
    let vm = AgentBannerViewModel(state: .ready(failure(), diag))
    XCTAssertEqual(vm.style, .ready)
    XCTAssertEqual(vm.headline, "port in use")
    XCTAssertEqual(vm.detail, "3000 busy")
    XCTAssertEqual(vm.fixCommand, "kill $(lsof -ti:3000)")
    XCTAssertFalse(vm.fixIsDestructive)
    XCTAssertTrue(vm.showsInsertFix)
    XCTAssertTrue(vm.showsInvestigate)
  }

  func testReadyWithDestructiveFixIsFlagged() {
    let diag = AgentDiagnosis(
      summary: "stale build", fixCommand: "rm -rf node_modules && npm i", detail: nil)
    let vm = AgentBannerViewModel(state: .ready(failure(), diag))
    XCTAssertTrue(vm.fixIsDestructive)
    XCTAssertTrue(vm.showsInsertFix)
  }

  func testReadyWithNoFixHidesInsert() {
    let diag = AgentDiagnosis(summary: "unclear", fixCommand: nil, detail: nil)
    let vm = AgentBannerViewModel(state: .ready(failure(), diag))
    XCTAssertNil(vm.fixCommand)
    XCTAssertFalse(vm.showsInsertFix)
    XCTAssertTrue(vm.showsInvestigate)
  }

  func testFailureCliNotFoundIsNotRetryable() {
    let vm = AgentBannerViewModel(state: .failure(failure(), .cliNotFound))
    XCTAssertEqual(vm.style, .failure)
    XCTAssertFalse(vm.showsDiagnoseButton, "installing a CLI isn't a retry")
    XCTAssertTrue(vm.headline.lowercased().contains("cli"))
  }

  func testFailureTimeoutIsRetryable() {
    let vm = AgentBannerViewModel(state: .failure(failure(), .timedOut))
    XCTAssertTrue(vm.showsDiagnoseButton)
  }

  func testRemoteCaveatDisablesInvestigate() {
    let vm = AgentBannerViewModel(state: .remoteCaveat(failure()))
    XCTAssertEqual(vm.style, .remote)
    XCTAssertFalse(vm.showsInvestigate, "local agent can't see the remote host (X5)")
    XCTAssertFalse(vm.showsInsertFix)
    XCTAssertTrue(vm.showsDismiss)
  }
}
