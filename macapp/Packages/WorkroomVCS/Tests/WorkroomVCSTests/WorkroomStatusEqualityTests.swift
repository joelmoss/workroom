import Foundation
import WorkroomVCS
import XCTest

/// `WorkroomStatus` compares its five clocks by presence and every other field by value (#503): a
/// probe that changed nothing on screen must compare equal, so the store keeps its clocks without
/// redrawing every status view.
final class WorkroomStatusEqualityTests: XCTestCase {
  private let clocks: [(String, WritableKeyPath<WorkroomStatus, Date?>)] = [
    ("lastChecked", \.lastChecked), ("localReadAt", \.localReadAt),
    ("ciCheckedAt", \.ciCheckedAt), ("prCheckedAt", \.prCheckedAt),
    ("checksCheckedAt", \.checksCheckedAt),
  ]

  /// Value: protects=a re-probe that only moved a clock compares equal; fails_when=a clock loses
  /// `@PresenceEquatable`, or its `==` compares times; no_claim=that the store skips the notify (the
  /// app's store test covers that)
  func testAClockAtAnotherTimeIsTheSameStatus() {
    for (name, clock) in clocks {
      var earlier = WorkroomStatus(dirty: true)
      var later = earlier
      earlier[keyPath: clock] = Date(timeIntervalSince1970: 1)
      later[keyPath: clock] = Date(timeIntervalSince1970: 2)
      XCTAssertEqual(earlier, later, name)
    }
  }

  /// Value: protects=a clock appearing still redraws (the Changes panel leaves "Checking…", the PR
  /// panel trusts `checks`); fails_when=the wrapper ignores clocks altogether; no_claim=none beyond
  /// protects
  func testAClockSetOrUnsetIsADifferentStatus() {
    for (name, clock) in clocks {
      var checked = WorkroomStatus(dirty: true)
      checked[keyPath: clock] = Date(timeIntervalSince1970: 1)
      XCTAssertNotEqual(WorkroomStatus(dirty: true), checked, name)
    }
  }

  /// Value: protects=everything but the clocks still compares by value; fails_when=equality stops
  /// seeing a visible field; no_claim=fields added later (synthesized `==` covers them)
  func testAVisibleFieldStillComparesByValue() {
    let status = WorkroomStatus(
      dirty: true, changedFiles: [ChangedFile(path: "a.swift", change: .modified)],
      lastChecked: Date(timeIntervalSince1970: 1))
    var clean = status
    clean.dirty = false
    var otherFile = status
    otherFile.changedFiles = [ChangedFile(path: "b.swift", change: .modified)]
    XCTAssertNotEqual(status, clean)
    XCTAssertNotEqual(status, otherFile)
  }
}
