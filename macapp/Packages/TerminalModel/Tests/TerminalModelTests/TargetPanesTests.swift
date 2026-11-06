import Foundation
import TerminalModel
import XCTest

/// `TargetPanes`: every write announces itself before it lands, which is what the app's sessions
/// turn into `objectWillChange`, and the records follow the arrangement's order.
@MainActor
final class TargetPanesTests: XCTestCase {
  private struct Tab: Identifiable, Equatable {
    let id: String
    var title = ""
  }

  /// A record of what the panes held each time `willChange` fired.
  private final class Probe {
    var seen: [(tabs: [String], order: [String])] = []
  }

  private func makePanes() -> (TargetPanes<Tab>, Probe) {
    let probe = Probe()
    var panes: TargetPanes<Tab>?
    panes = TargetPanes {
      guard let panes else { return }
      probe.seen.append((panes.tabs.keys.sorted(), panes.state.order))
    }
    return (panes!, probe)
  }

  func testEveryWriteAnnouncesItselfBeforeItLands() {
    let (panes, probe) = makePanes()

    panes.setTab(Tab(id: "a"))
    XCTAssertEqual(probe.seen.last?.tabs, [], "setTab announces before storing")
    panes.updateState { $0.order.append("a") }
    XCTAssertEqual(probe.seen.last?.order, [], "updateState announces before editing")
    panes.setTabs(["a": Tab(id: "a"), "b": Tab(id: "b")])
    XCTAssertEqual(probe.seen.last?.tabs, ["a"])
    panes.removeTab("b")
    XCTAssertEqual(probe.seen.last?.tabs, ["a", "b"])
    panes.empty()
    XCTAssertEqual(probe.seen.last?.tabs, ["a"])
    XCTAssertEqual(probe.seen.last?.order, ["a"])
    XCTAssertEqual(probe.seen.count, 5, "one announcement per write")
  }

  func testSetTabReplacesTheRecordWithItsID() {
    let (panes, _) = makePanes()
    panes.setTab(Tab(id: "a", title: "old"))
    panes.setTab(Tab(id: "a", title: "new"))
    XCTAssertEqual(panes.tabs.count, 1)
    XCTAssertEqual(panes.tabs["a"]?.title, "new")
  }

  func testOrderedTabsFollowTheNormalizedOrderAndSkipMissingRecords() {
    let (panes, _) = makePanes()
    panes.setTabs(["a": Tab(id: "a"), "b": Tab(id: "b")])
    panes.updateState { $0.order = ["b", "gone", "a"] }
    XCTAssertEqual(panes.orderedTabs.map(\.id), ["b", "a"])
  }

  func testEmptyingKeepsTheCounter() {
    let (panes, _) = makePanes()
    panes.setTab(Tab(id: "a"))
    panes.updateState {
      $0.order = ["a"]
      $0.focused = "a"
      _ = $0.numberNextTerminal()
    }
    panes.empty()
    XCTAssertTrue(panes.tabs.isEmpty)
    XCTAssertEqual(panes.state.order, [])
    XCTAssertNil(panes.state.focused)
    XCTAssertEqual(panes.state.counter, 1, "the next terminal keeps numbering on")
  }
}
