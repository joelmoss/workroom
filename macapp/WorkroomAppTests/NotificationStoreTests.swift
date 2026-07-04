import AppKit
import XCTest

@testable import Workroom

/// `NotificationCenterStore` computed counts, dismissal, and eviction (issue #10). There is no
/// read state — dismissing deletes — so "seen" notifications never linger. `@MainActor` because the
/// store is main-actor isolated; a fixed clock keeps ordering stable. (Bell coalescing was removed
/// with the libghostty migration — the bell is no longer a recorded activity; see C1.)
@MainActor
final class NotificationStoreTests: XCTestCase {
  private let target = "wr|/p|foo"
  private let otherTarget = "root|/p"

  private func makeStore(cap: Int = 500) -> NotificationCenterStore {
    NotificationCenterStore(cap: cap, now: { Date(timeIntervalSince1970: 0) })
  }

  private func osc(_ title: String) -> TerminalActivity { .osc(title: title, body: nil) }

  func testFocusedEventIsDropped() {
    let s = makeStore()
    let tab = UUID()
    XCTAssertNil(s.record(targetID: target, tabID: tab, activity: osc("x"), focused: true))
    XCTAssertTrue(s.items.isEmpty)
    XCTAssertEqual(s.total, 0)
  }

  func testOSCItemsStayDistinct() {
    let s = makeStore()
    let tab = UUID()
    s.record(targetID: target, tabID: tab, activity: osc("one"), focused: false)
    s.record(targetID: target, tabID: tab, activity: osc("two"), focused: false)
    XCTAssertEqual(s.items.count, 2)
    XCTAssertEqual(s.count(tab: tab), 2)
  }

  func testCountsRollUpTabToTargetToTotal() {
    let s = makeStore()
    let tabA = UUID()
    let tabB = UUID()
    s.record(targetID: target, tabID: tabA, activity: osc("a"), focused: false)
    s.record(targetID: target, tabID: tabB, activity: osc("b"), focused: false)
    s.record(targetID: otherTarget, tabID: UUID(), activity: osc("c"), focused: false)
    XCTAssertEqual(s.count(tab: tabA), 1)
    XCTAssertEqual(s.count(target: target), 2)
    XCTAssertEqual(s.total, 3)
  }

  func testDismissByTabDeletesItsItemsAndLeavesOthers() {
    let s = makeStore()
    let tabA = UUID()
    let tabB = UUID()
    s.record(targetID: target, tabID: tabA, activity: osc("a"), focused: false)
    s.record(targetID: target, tabID: tabB, activity: osc("b"), focused: false)
    s.dismiss(tab: tabA)
    // Dismissed ⇒ gone (not flagged): the item is removed, the other survives.
    XCTAssertEqual(s.items.count, 1)
    XCTAssertEqual(s.count(tab: tabA), 0)
    XCTAssertEqual(s.count(tab: tabB), 1)
    XCTAssertEqual(s.total, 1)
  }

  func testDismissByNotifIDDeletesJustThatItem() {
    let s = makeStore()
    let tab = UUID()
    let one = s.record(targetID: target, tabID: tab, activity: osc("one"), focused: false)
    s.record(targetID: target, tabID: tab, activity: osc("two"), focused: false)
    s.dismiss(notifID: one!.id)
    XCTAssertEqual(s.items.map(\.title), ["two"])
  }

  func testClearRemovesEverything() {
    let s = makeStore()
    s.record(targetID: target, tabID: UUID(), activity: osc("x"), focused: false)
    s.clear()
    XCTAssertTrue(s.items.isEmpty)
    XCTAssertEqual(s.total, 0)
  }

  func testRemoveForTargetReturnsTabsAndDropsItems() {
    let s = makeStore()
    let tabA = UUID()
    let tabB = UUID()
    s.record(targetID: target, tabID: tabA, activity: osc("a"), focused: false)
    s.record(targetID: otherTarget, tabID: tabB, activity: osc("b"), focused: false)
    let dropped = s.removeForTarget(target)
    XCTAssertEqual(dropped, [tabA])
    XCTAssertEqual(s.count(target: target), 0)
    XCTAssertEqual(s.total, 1)
  }

  func testHistoryTrimsToCapDroppingOldest() {
    let s = makeStore(cap: 3)
    for i in 0..<5 {
      s.record(targetID: target, tabID: UUID(), activity: osc("\(i)"), focused: false)
    }
    XCTAssertEqual(s.items.count, 3)
    XCTAssertEqual(s.items.first?.title, "2")  // "0" and "1" evicted
  }

  /// The left-sidebar strip (issue #118) shows `items.first` (the oldest) with a `+N` badge where
  /// `N == items.count - 1`; dismissing the oldest reveals the next oldest. These are pure
  /// derivations over the chronologically-appended `items`, so exercise them directly here.
  func testOldestFirstAndExtraCountDriveTheSidebarStrip() {
    let s = makeStore()
    let first = s.record(targetID: target, tabID: UUID(), activity: osc("oldest"), focused: false)
    s.record(targetID: target, tabID: UUID(), activity: osc("middle"), focused: false)
    s.record(targetID: target, tabID: UUID(), activity: osc("newest"), focused: false)

    // Oldest is displayed; the badge counts the rest.
    XCTAssertEqual(s.items.first?.title, "oldest")
    XCTAssertEqual(s.items.count - 1, 2)

    // Dismissing the oldest reveals the next oldest and drops the extra count.
    s.dismiss(notifID: first!.id)
    XCTAssertEqual(s.items.first?.title, "middle")
    XCTAssertEqual(s.items.count - 1, 1)

    // The `+N` popover shows the others (chronological subset the strip passes as `dropFirst()`).
    XCTAssertEqual(Array(s.items.dropFirst()).map(\.title), ["newest"])

    // Down to one: no extra, strip shows just the oldest.
    s.dismiss(notifID: s.items.first!.id)
    XCTAssertEqual(s.items.count - 1, 0)
    XCTAssertEqual(s.items.first?.title, "newest")
  }

  // onTotalChange — the Dock-badge seam: fires with the new aggregate total on every history change
  // (issue #32), so the badge tracks the count from the model rather than a (suspendable) view.

  func testOnTotalChangeFiresWithNewTotalOnRecordAndDismiss() {
    let s = makeStore()
    var totals: [Int] = []
    s.onTotalChange = { totals.append($0) }
    let tab = UUID()
    let one = s.record(targetID: target, tabID: tab, activity: osc("one"), focused: false)
    s.record(targetID: target, tabID: tab, activity: osc("two"), focused: false)
    s.dismiss(notifID: one!.id)
    s.clear()
    XCTAssertEqual(totals, [1, 2, 1, 0])  // append, append, dismiss-one, clear-to-empty
  }

  func testOnTotalChangeDoesNotFireForADroppedFocusedEvent() {
    let s = makeStore()
    var fired = false
    s.onTotalChange = { _ in fired = true }
    // Focused ⇒ not recorded ⇒ items unchanged ⇒ no badge update.
    s.record(targetID: target, tabID: UUID(), activity: osc("x"), focused: true)
    XCTAssertFalse(fired)
  }

  // DockBadge.label — nil clears the badge; the count caps at "99+" to match the in-app pill.

  func testDockBadgeLabel() {
    XCTAssertNil(DockBadge.label(for: 0))
    XCTAssertNil(DockBadge.label(for: -1))
    XCTAssertEqual(DockBadge.label(for: 1), "1")
    XCTAssertEqual(DockBadge.label(for: 99), "99")
    XCTAssertEqual(DockBadge.label(for: 100), "99+")
  }

  // DockBadge.apply — a non-zero count installs a custom tile contentView (we draw the badge there
  // because `badgeLabel` is suppressed in this app — issue #32); zero restores the plain icon.
  func testDockBadgeApplySetsAndClearsContentView() {
    DockBadge.apply(3)
    XCTAssertNotNil(NSApp.dockTile.contentView)
    DockBadge.apply(0)
    XCTAssertNil(NSApp.dockTile.contentView)
  }
}
