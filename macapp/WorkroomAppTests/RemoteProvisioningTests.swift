import XCTest

@testable import Workroom

final class RemoteProvisioningTests: XCTestCase {
  /// The clone token reaches git as configuration in its environment, an `Authorization` header
  /// for github.com only, and nowhere a process list, a remote URL or a file would show it.
  func testTheCloneTokenReachesGitOnlyAsAGitHubHeaderInItsEnvironment() throws {
    let environment = RemoteProvisioning.cloneEnvironment(token: "ghs_secret")

    XCTAssertEqual(environment["GIT_CONFIG_COUNT"], "1")
    XCTAssertEqual(environment["GIT_CONFIG_KEY_0"], "http.https://github.com/.extraHeader")
    let value = try XCTUnwrap(environment["GIT_CONFIG_VALUE_0"])
    XCTAssertTrue(value.hasPrefix("Authorization: Basic "))
    let credentials = try XCTUnwrap(
      Data(base64Encoded: String(value.dropFirst("Authorization: Basic ".count))))
    XCTAssertEqual(String(decoding: credentials, as: UTF8.self), "x-access-token:ghs_secret")
    XCTAssertFalse(environment.values.contains { $0.contains("ghs_secret") })
  }

  /// One operation at a time on a base, and different bases at once.
  func testOperationsOnOneBaseTakeTurnsAndOnDifferentBasesOverlap() async throws {
    final class Probe: @unchecked Sendable {
      private let lock = NSLock()
      private var running: [UUID: Int] = [:]
      private(set) var most: [UUID: Int] = [:]
      var together = 0
      private var now = 0
      func enter(_ base: UUID) {
        lock.withLock {
          running[base, default: 0] += 1
          most[base] = max(most[base] ?? 0, running[base]!)
          now += 1
          together = max(together, now)
        }
      }
      func leave(_ base: UUID) {
        lock.withLock {
          running[base]! -= 1
          now -= 1
        }
      }
      var peaks: [UUID: Int] { lock.withLock { most } }
      var overlap: Int { lock.withLock { together } }
    }
    let probe = Probe()
    let (first, second) = (UUID(), UUID())
    let locks = BaseLocks()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for base in [first, first, first, second, second, second] {
        group.addTask {
          try await locks.exclusively(on: base) {
            probe.enter(base)
            try await Task.sleep(for: .milliseconds(50))
            probe.leave(base)
          }
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(probe.peaks[first], 1, "two operations on one base overlapped")
    XCTAssertEqual(probe.peaks[second], 1, "two operations on one base overlapped")
    XCTAssertEqual(probe.overlap, 2, "different bases did not run at once")
  }
}
