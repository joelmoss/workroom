import Foundation
import Observation
import TerminalModel
import XCTest

/// `TargetPanes`: every write announces itself before it lands, which is what the app's sessions
/// turn into `paneWillChange`, and whether the target holds any tab changes only when that flips.
@MainActor
final class TargetPanesTests: XCTestCase {
  /// A record of what the panes held each time `willChange` fired.
  private final class Probe {
    var seen: [[String]] = []
  }

  private func makePanes() -> (TargetPanes<String>, Probe) {
    let probe = Probe()
    var panes: TargetPanes<String>?
    panes = TargetPanes {
      guard let panes else { return }
      probe.seen.append(panes.state.order)
    }
    return (panes!, probe)
  }

  func testEveryWriteAnnouncesItselfBeforeItLands() {
    let (panes, probe) = makePanes()

    panes.updateState { $0.order.append("a") }
    XCTAssertEqual(probe.seen.last, [], "updateState announces before editing")
    panes.updateState { $0.order.append("b") }
    XCTAssertEqual(probe.seen.last, ["a"])
    panes.empty()
    XCTAssertEqual(probe.seen.last, ["a", "b"], "empty announces before emptying")
    XCTAssertEqual(probe.seen.count, 3, "one announcement per write")
  }

  func testItHoldsTheTabsItsOrderNames() {
    let (panes, _) = makePanes()
    panes.updateState { $0.order = ["b", "a"] }
    XCTAssertTrue(panes.holds("a"))
    XCTAssertFalse(panes.holds("gone"))
  }

  func testEmptyingKeepsTheCounter() {
    let (panes, _) = makePanes()
    panes.updateState {
      $0.order = ["a"]
      $0.focused = "a"
      _ = $0.numberNextTerminal()
    }
    panes.empty()
    XCTAssertEqual(panes.state.order, [])
    XCTAssertNil(panes.state.focused)
    XCTAssertEqual(panes.state.counter, 1, "the next terminal keeps numbering on")
  }

  /// A reader that asks only whether the target has tabs (another window's menu enablement) hears
  /// the first tab arrive and the last one go, and nothing in between.
  func testHasTabsChangesOnlyWhenItFlips() {
    let (panes, _) = makePanes()
    let changes = ChangeCount()

    changes.watch { _ = panes.hasTabs }
    panes.updateState { $0.order.append("a") }
    XCTAssertTrue(panes.hasTabs)
    XCTAssertEqual(changes.value, 1, "the first tab flips it")

    changes.watch { _ = panes.hasTabs }
    panes.updateState { $0.order.append("b") }
    panes.updateState { $0.focused = "b" }
    XCTAssertEqual(changes.value, 1, "a second tab and a focus change leave it alone")

    panes.updateState { $0.order = [] }
    XCTAssertFalse(panes.hasTabs)
    XCTAssertEqual(changes.value, 2, "the last tab leaving flips it back")
  }
}
