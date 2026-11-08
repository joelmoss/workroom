import XCTest

@testable import Workroom

/// The unit-test bundle's principal class (`NSPrincipalClass`, `project.yml`): XCTest makes one as
/// the bundle loads, before any test runs. It turns a `HostedRunSessionGuard` refusal into a failure
/// of the test that was running, named in the message, rather than a crash of the whole test host.
@objc(HostedRunGuardObserver)
final class HostedRunGuardObserver: NSObject, XCTestObservation, @unchecked Sendable {
  private let lock = NSLock()
  /// The test that started last. Not cleared when it finishes: a refusal from a hop it left behind
  /// is still its own, and is better on it than on none.
  private var current: XCTestCase?

  override init() {
    super.init()
    XCTestObservationCenter.shared.addTestObserver(self)
    HostedRunSessionGuard.reportViolation = { [weak self] in self?.fail($0) }
  }

  func testCaseWillStart(_ testCase: XCTestCase) {
    lock.withLock { current = testCase }
  }

  private func fail(_ message: String) {
    guard let test = lock.withLock({ current }) else {
      preconditionFailure(message)
    }
    test.record(
      XCTIssue(type: .assertionFailure, compactDescription: "\(test.name): \(message)"))
  }
}
