import XCTest

@testable import Workroom

/// Value: protects=a hosted unit test's terminal never attaching to this build's real daemon, and
/// nothing else being refused; fails_when=the guard misses a local attach, or refuses outside a
/// hosted run or a remote pane's; seam=`HostedRunSessionGuard.refuses`; no_claim=the surface's
/// spawn (AppStoreCreateWorkroomTests' backgrounded run).
final class HostedRunSessionGuardTests: XCTestCase {
  private let hosted = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
  private let local = PaneSessionAttachment.Launch(
    command: "workroomd attach",
    environment: [("WORKROOM_SESSION_SOCKET", "/tmp/workroom-501-x/workroomd")])

  func testALocalAttachInAHostedRunIsRefusedAndReported() {
    let original = HostedRunSessionGuard.reportViolation
    defer { HostedRunSessionGuard.reportViolation = original }
    let reported = LockedMessages()
    HostedRunSessionGuard.reportViolation = { reported.append($0) }

    XCTAssertTrue(HostedRunSessionGuard.refuses(local, workingDirectory: "/w", environment: hosted))
    XCTAssertEqual(reported.count, 1, "a refusal fails the running test")
  }

  func testOutsideAHostedRunNothingIsRefused() {
    XCTAssertFalse(HostedRunSessionGuard.refuses(local, workingDirectory: "/w", environment: [:]))
  }

  func testARemotePanesAttachIsNotRefused() {
    let remote = PaneSessionAttachment.Launch(command: "ssh host workroomd attach", environment: [])
    XCTAssertFalse(
      HostedRunSessionGuard.refuses(remote, workingDirectory: "/w", environment: hosted))
  }
}

private final class LockedMessages: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []
  var count: Int { lock.withLock { messages.count } }
  func append(_ message: String) { lock.withLock { messages.append(message) } }
}
