import XCTest

@testable import WorkroomGit

/// Tests for the shared replacement-line pairing rule (deletion *k* ↔ addition *k*, shorter side
/// padded with `nil`) used by both intra-line emphasis and the side-by-side diff layout.
final class DiffRunPairingTests: XCTestCase {

  private func del(_ t: String, old: Int) -> UnifiedDiff.Line {
    UnifiedDiff.Line(kind: .deletion, text: t, oldLine: old, newLine: nil)
  }

  private func add(_ t: String, new: Int) -> UnifiedDiff.Line {
    UnifiedDiff.Line(kind: .addition, text: t, oldLine: nil, newLine: new)
  }

  func testEvenRunPairsBothSides() {
    let pairs = DiffRunPairing.align(
      deletions: [del("a", old: 1), del("b", old: 2)],
      additions: [add("x", new: 1), add("y", new: 2)])
    XCTAssertEqual(pairs.count, 2)
    XCTAssertEqual(pairs[0].deletion?.text, "a")
    XCTAssertEqual(pairs[0].addition?.text, "x")
    XCTAssertEqual(pairs[1].deletion?.text, "b")
    XCTAssertEqual(pairs[1].addition?.text, "y")
  }

  func testMoreDeletionsPadsRightWithNil() {
    let pairs = DiffRunPairing.align(
      deletions: [del("a", old: 1), del("b", old: 2), del("c", old: 3)],
      additions: [add("x", new: 1)])
    XCTAssertEqual(pairs.count, 3)
    XCTAssertEqual(pairs[0].addition?.text, "x")
    XCTAssertNil(pairs[1].addition)
    XCTAssertNil(pairs[2].addition)
    XCTAssertEqual(pairs[2].deletion?.text, "c")
  }

  func testMoreAdditionsPadsLeftWithNil() {
    let pairs = DiffRunPairing.align(
      deletions: [del("a", old: 1)],
      additions: [add("x", new: 1), add("y", new: 2), add("z", new: 3)])
    XCTAssertEqual(pairs.count, 3)
    XCTAssertEqual(pairs[0].deletion?.text, "a")
    XCTAssertNil(pairs[1].deletion)
    XCTAssertNil(pairs[2].deletion)
    XCTAssertEqual(pairs[2].addition?.text, "z")
  }

  func testPureAdditionHasNilDeletions() {
    let pairs = DiffRunPairing.align(
      deletions: [], additions: [add("x", new: 1), add("y", new: 2)])
    XCTAssertEqual(pairs.count, 2)
    XCTAssertTrue(pairs.allSatisfy { $0.deletion == nil })
    XCTAssertEqual(pairs.map { $0.addition?.text }, ["x", "y"])
  }

  func testPureDeletionHasNilAdditions() {
    let pairs = DiffRunPairing.align(
      deletions: [del("a", old: 1), del("b", old: 2)], additions: [])
    XCTAssertEqual(pairs.count, 2)
    XCTAssertTrue(pairs.allSatisfy { $0.addition == nil })
    XCTAssertEqual(pairs.map { $0.deletion?.text }, ["a", "b"])
  }

  func testEmptyInputsYieldEmpty() {
    XCTAssertTrue(DiffRunPairing.align(deletions: [], additions: []).isEmpty)
  }
}
