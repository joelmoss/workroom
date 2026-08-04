import AppKit
import XCTest

@testable import Workroom

/// The quick switcher's most-recently-used order (issue #132) — `RecencyList`'s rules, and the
/// `SwitcherRecency` ordering built on them.
///
/// The ordering rule is the whole feature: ⌥Tab's promise is "flip to where I just was", so a bug here
/// is indistinguishable from the shortcut being broken. All of it is a pure value type, so every rule
/// is asserted headlessly (no window, no terminal surface).
@MainActor
final class SwitcherRecencyTests: XCTestCase {

  // MARK: RecencyList

  func testTouchMovesToFrontAndInsertsNew() {
    var list = RecencyList<String>()
    list.touch("a")
    list.touch("b")
    XCTAssertEqual(list.ids, ["b", "a"], "most recent first")

    list.touch("a")
    XCTAssertEqual(list.ids, ["a", "b"], "re-touching promotes rather than duplicating")

    list.touch("a")
    XCTAssertEqual(list.ids, ["a", "b"], "touching the head is a no-op")
  }

  func testForgetAndRetain() {
    var list = RecencyList<String>()
    for id in ["a", "b", "c"] { list.touch(id) }
    XCTAssertEqual(list.ids, ["c", "b", "a"])

    list.forget("b")
    XCTAssertEqual(list.ids, ["c", "a"])

    list.retain(["a"])
    XCTAssertEqual(list.ids, ["a"], "retain drops everything not live")

    list.retain([])
    XCTAssertTrue(list.ids.isEmpty)
  }

  func testTouchIsCapped() {
    var list = RecencyList<Int>()
    for i in 0...(RecencyList<Int>.maxEntries + 10) { list.touch(i) }
    XCTAssertEqual(
      list.ids.count, RecencyList<Int>.maxEntries, "a long session can't grow unbounded")
    XCTAssertEqual(list.ids.first, RecencyList<Int>.maxEntries + 10, "the newest survives")
  }

  /// The rail order: known ids by recency, never-touched ids after them **in their given order** — so a
  /// workroom you haven't visited this session still appears, at the end, rather than vanishing.
  func testOrderedPutsTouchedFirstAndKeepsUntouchedOrder() {
    var list = RecencyList<String>()
    list.touch("c")
    list.touch("a")

    XCTAssertEqual(
      list.ordered(["a", "b", "c", "d"], id: { $0 }), ["a", "c", "b", "d"],
      "a then c by recency; b then d keep their incoming order")
  }

  func testOrderedIsIdentityWhenNothingTouched() {
    let list = RecencyList<String>()
    XCTAssertEqual(list.ordered(["b", "a", "c"], id: { $0 }), ["b", "a", "c"])
  }

  func testOrderedEmitsEveryItemExactlyOnce() {
    var list = RecencyList<String>()
    list.touch("z")  // an id that isn't in the items at all
    list.touch("b")
    let out = list.ordered(["a", "b", "c"], id: { $0 })
    XCTAssertEqual(out.sorted(), ["a", "b", "c"], "total and duplicate-free")
    XCTAssertEqual(out.first, "b", "…and still recency-led")
  }

  // MARK: Window identity

  /// `WindowToken` must never repeat, which is the whole reason it exists: `AppStore.windowNumber` is
  /// reclaimed by the next new window, and `ObjectIdentifier` is an address a fresh store can reuse.
  func testWindowTokensAreUnique() {
    let tokens = (0..<50).map { _ in WindowToken() }
    XCTAssertEqual(Set(tokens).count, 50)

    let a = AppStore()
    let b = AppStore()
    XCTAssertNotEqual(a.windowToken, b.windowToken, "each store gets its own")
    XCTAssertEqual(a.windowToken, a.windowToken, "and it is stable for that store")
  }

  /// The same workroom open in two windows is two switchable places, because `TerminalSessions` is
  /// per-window and each may be showing a different tab.
  func testSameWorkroomInTwoWindowsIsTwoSlots() {
    let a = AppStore()
    let b = AppStore()
    let sid = SidebarID.workroom(project: "/p", name: "w")

    let recency = SwitcherRecency()
    recency.recordWorkroom(store: a, sid: sid)
    recency.recordWorkroom(store: b, sid: sid)

    XCTAssertEqual(
      recency.workrooms.ids.count, 2, "keyed by (window, workroom), not workroom alone")
    XCTAssertEqual(
      recency.workrooms.ids.first, WorkroomSlotID(window: b.windowToken, sid: sid),
      "the most recently recorded window leads")
  }

  func testRecordWorkroomIgnoresNoSelection() {
    let recency = SwitcherRecency()
    recency.recordWorkroom(store: AppStore(), sid: nil)
    XCTAssertTrue(recency.workrooms.ids.isEmpty)
  }

  // MARK: Suppression around a commit's own window raise

  func testRecordingIsSuppressedWhileACommitIsInFlight() {
    // `QuickSwitcher.commit` raises the destination window before writing the selection, and that raise
    // fires `WindowRegistry`'s recency hook for the selection the window is about to LEAVE. Unsuppressed,
    // that put a workroom the user never visited at MRU[1] and broke the ⌥Tab⌥Tab ping-pong.
    let store = AppStore()
    let leaving = SidebarID.workroom(project: "/p", name: "leaving")
    let arriving = SidebarID.workroom(project: "/p", name: "arriving")
    let recency = SwitcherRecency()

    recency.suppressingRecord {
      recency.recordWorkroom(store: store, sid: leaving)  // what the raise would record
      recency.recordPane(UUID())
    }
    XCTAssertTrue(recency.workrooms.ids.isEmpty, "the raise's phantom use is not recorded")
    XCTAssertTrue(recency.panes.ids.isEmpty)

    recency.recordWorkroom(store: store, sid: arriving)
    XCTAssertEqual(
      recency.workrooms.ids, [WorkroomSlotID(window: store.windowToken, sid: arriving)],
      "and recording resumes after the commit")
  }

  func testOrderingDoesNotPruneWhatItWasNotShown() {
    // `workroomOrder` is handed an ALREADY-FILTERED list (windows with a sheet up are excluded), so
    // pruning against it permanently forgot the MRU rank of any window that merely had a dialog open.
    let visible = AppStore()
    let busy = AppStore()
    let sid = SidebarID.workroom(project: "/p", name: "w")
    let recency = SwitcherRecency()
    recency.recordWorkroom(store: busy, sid: sid)
    recency.recordWorkroom(store: visible, sid: sid)
    XCTAssertEqual(recency.workrooms.ids.count, 2)

    _ = recency.workroomOrder([
      WorkroomSlot(
        store: visible, sid: sid,
        target: TerminalTarget(
          id: TerminalTarget.workroomID(project: "/p", name: "w"), title: "w", path: "/p/w",
          isMissing: false))
    ])
    XCTAssertEqual(
      recency.workrooms.ids.count, 2,
      "the excluded window keeps its rank — it comes back when its sheet closes")
  }

  // MARK: Pane recency

  func testPaneRecordingAndPruning() {
    let recency = SwitcherRecency()
    let one = UUID()
    let two = UUID()

    recency.recordPane(one)
    recency.recordPane(two)
    XCTAssertEqual(recency.panes.ids, [two, one])

    recency.recordPane(nil)
    XCTAssertEqual(recency.panes.ids, [two, one], "a nil focus change records nothing")

    recency.forgetPanes([two])
    XCTAssertEqual(recency.panes.ids, [one], "a closed pane leaves the order")
  }
}
