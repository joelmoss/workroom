import XCTest

@testable import Workroom

/// The foreground toast queue (issue #31): a real `AppStore` exercising the queue mutations
/// (`enqueueToast`/`dismissToast`). Pure of `NSApp`, so it runs headless like
/// `AppStoreNavigationTests`. The SwiftUI presentation (5s timer, hover-pause, flash) is verified
/// manually, consistent with the routing tests' "decision 3.1" note.
@MainActor
final class ToastQueueTests: XCTestCase {

  private func note(_ title: String) -> WorkroomNotification {
    WorkroomNotification(
      id: UUID(), targetID: .workroom(project: "/a", name: "foo"), tabID: UUID(), source: "a / foo",
      title: title, body: nil, date: Date(timeIntervalSince1970: 0), count: 1)
  }

  func testEnqueueAppendsInOrder() {
    let store = AppStore()
    let a = note("a")
    let b = note("b")
    store.enqueueToast(a)
    store.enqueueToast(b)
    XCTAssertEqual(store.toasts.map(\.id), [a.id, b.id])
  }

  func testEnqueueCapsAndDropsOldest() {
    let store = AppStore()
    let notes = (0..<6).map { note("n\($0)") }
    for n in notes { store.enqueueToast(n) }
    // Capped at 4 (maxToasts); the two oldest were pushed out, newest kept in order.
    XCTAssertEqual(store.toasts.count, 4)
    XCTAssertEqual(store.toasts.map(\.id), notes[2...].map(\.id))
  }

  func testDismissRemovesOnlyThatToast() {
    let store = AppStore()
    let a = note("a")
    let b = note("b")
    store.enqueueToast(a)
    store.enqueueToast(b)
    store.dismissToast(a.id)
    XCTAssertEqual(store.toasts.map(\.id), [b.id])
    // Dismissing an unknown id is a no-op.
    store.dismissToast(UUID())
    XCTAssertEqual(store.toasts.map(\.id), [b.id])
  }

  /// Value: protects=a view reading a window's toasts through its pane host re-rendering as toasts
  /// come and go, now that the queue is its PaneNotifier's; fails_when=the read through the host
  /// registers no Observation (the queue unobserved, or behind an ignored property); why_new=the
  /// queue moved out of AppStore; seam=none; no_claim=SwiftUI's own re-render
  /// (`AdapterGateInvalidationTests.testAToastArrivingReRunsTheStack`).
  func testReadingToastsThroughTheHostObservesTheQueue() {
    let store = AppStore()
    let host: any PaneHost = store
    let a = note("a")
    let arrived = observeChange { _ = host.toasts }
    store.enqueueToast(a)
    XCTAssertTrue(arrived.happened, "a toast arriving")

    let went = observeChange { _ = host.toasts }
    store.dismissToast(a.id)
    XCTAssertTrue(went.happened, "a toast going")
  }
}
