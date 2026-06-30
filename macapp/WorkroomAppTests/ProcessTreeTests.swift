import XCTest

@testable import Workroom

/// The pure descendant traversal behind `ProcessTree.killTree` (issue #49, X2). The real `pgrep`
/// lookup and the SIGKILL need live processes; the traversal — dedup, cycle-safety, ordering — is
/// exercised here with an injected child map.
final class ProcessTreeTests: XCTestCase {
  private func lookup(_ map: [pid_t: [pid_t]]) -> (pid_t) -> [pid_t] {
    { map[$0] ?? [] }
  }

  func testNoChildren() {
    XCTAssertEqual(ProcessTree.descendants(of: 100, children: lookup([:])), [])
  }

  func testLinearChain() {
    let map: [pid_t: [pid_t]] = [100: [101], 101: [102], 102: [103]]
    XCTAssertEqual(ProcessTree.descendants(of: 100, children: lookup(map)), [101, 102, 103])
  }

  func testBranching() {
    let map: [pid_t: [pid_t]] = [1: [2, 3], 2: [4], 3: [5, 6]]
    XCTAssertEqual(
      Set(ProcessTree.descendants(of: 1, children: lookup(map))), Set([2, 3, 4, 5, 6]))
  }

  func testCycleIsSafe() {
    // A pathological lookup that reports a cycle must not loop forever or revisit.
    let map: [pid_t: [pid_t]] = [1: [2], 2: [3], 3: [1, 2]]
    let result = ProcessTree.descendants(of: 1, children: lookup(map))
    XCTAssertEqual(Set(result), Set([2, 3]))
    XCTAssertEqual(result.count, 2, "no pid visited twice")
  }

  func testIgnoresSelfAndInvalidPids() {
    let map: [pid_t: [pid_t]] = [10: [10, 0, 1, 11], 11: []]
    // self (10), pid 0 and pid 1 are filtered; only 11 remains.
    XCTAssertEqual(ProcessTree.descendants(of: 10, children: lookup(map)), [11])
  }
}
