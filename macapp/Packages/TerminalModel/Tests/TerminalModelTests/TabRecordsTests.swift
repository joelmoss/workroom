import Foundation
import Observation
import TerminalModel
import XCTest

/// `TabRecords`: the app's tabs by id, each observed on its own, each held by one window at a time.
@MainActor
final class TabRecordsTests: XCTestCase {
  private struct Tab: Identifiable, Equatable {
    let id: String
    var title = ""
  }

  private enum Window { case one, two }

  func testSetReplacesTheRecordWithItsID() {
    let records = TabRecords<Tab, Window>()
    records.set(Tab(id: "a", title: "old"), by: .one)
    records.set(Tab(id: "a", title: "new"), by: .one)
    XCTAssertEqual(records["a"]?.title, "new")
    XCTAssertEqual(records.removeAll(heldBy: .one), ["a"])
  }

  func testRecordsFollowALayoutsNormalizedOrderAndSkipMissingOnes() {
    let records = TabRecords<Tab, Window>()
    records.set(Tab(id: "a"), by: .one)
    records.set(Tab(id: "b"), by: .one)
    let state = PaneState(order: ["b", "gone", "a"])
    XCTAssertEqual(records.records(state.normalizedOrder).map(\.id), ["b", "a"])
  }

  /// The point of a record per tab: a view reading one window's tab does not re-render when a tab
  /// in another window changes, as a reader of one shared dictionary would.
  func testAReaderOfOneTabIsNotToldOfAnothersChange() {
    let records = TabRecords<Tab, Window>()
    records.set(Tab(id: "a"), by: .one)
    records.set(Tab(id: "b"), by: .two)
    let told = ChangeCount()
    told.watch { _ = records["b"] }

    records.set(Tab(id: "a", title: "working"), by: .one)
    records.set(Tab(id: "c"), by: .one)
    XCTAssertEqual(told.value, 0, "another tab's change, or a new tab, told b's reader")

    records.set(Tab(id: "b", title: "working"), by: .two)
    XCTAssertEqual(told.value, 1, "its own tab's change must reach it")
  }

  func testAReaderHearsItsTabGo() {
    let records = TabRecords<Tab, Window>()
    records.set(Tab(id: "a"), by: .one)
    let told = ChangeCount()
    told.watch { _ = records["a"] }

    XCTAssertEqual(records.remove("a")?.id, "a")
    XCTAssertEqual(told.value, 1)
    XCTAssertNil(records["a"])
    XCTAssertNil(records.holder(of: "a"))
  }

  /// One layout at a time: another window can neither overwrite nor claim a tab one window holds,
  /// and takes it only once that window has let it go.
  func testATabIsHeldByOneHolderAtATime() {
    let records = TabRecords<Tab, Window>()
    records.set(Tab(id: "a", title: "one's"), by: .one)

    XCTAssertFalse(records.set(Tab(id: "a", title: "two's"), by: .two))
    XCTAssertEqual(records["a"]?.title, "one's", "a refused write stores nothing")
    XCTAssertFalse(records.claim(["a"], by: .two))
    XCTAssertEqual(records.holder(of: "a"), .one)

    records.release(["a"], by: .one)
    XCTAssertNil(records.holder(of: "a"), "in transit")
    XCTAssertEqual(records["a"]?.title, "one's", "a released tab keeps its record")
    XCTAssertFalse(records.set(Tab(id: "a", title: "one's again"), by: .one))
    XCTAssertNil(records.holder(of: "a"), "only a claim takes a tab in transit")
    XCTAssertEqual(records["a"]?.title, "one's")
    XCTAssertTrue(records.claim(["a"], by: .two))
    XCTAssertEqual(records.holder(of: "a"), .two)
  }

  func testAClaimOfATabWithNoRecordIsRefusedWhole() {
    let records = TabRecords<Tab, Window>()
    records.set(Tab(id: "a"), by: .one)
    records.release(["a"], by: .one)

    XCTAssertFalse(records.claim(["a", "gone"], by: .two))
    XCTAssertNil(records.holder(of: "a"), "nothing is claimed when any of them can't be")
  }

  func testReleaseLeavesAnotherHoldersTabs() {
    let records = TabRecords<Tab, Window>()
    records.set(Tab(id: "a"), by: .one)
    records.set(Tab(id: "b"), by: .two)

    records.release(["a", "b"], by: .one)
    XCTAssertNil(records.holder(of: "a"))
    XCTAssertEqual(records.holder(of: "b"), .two)
  }

  func testRemoveAllDropsOnlyThatHoldersTabs() {
    let records = TabRecords<Tab, Window>()
    records.set(Tab(id: "a"), by: .one)
    records.set(Tab(id: "b"), by: .two)

    XCTAssertEqual(records.removeAll(heldBy: .one), ["a"])
    XCTAssertNil(records["a"])
    XCTAssertNotNil(records["b"])
  }
}
