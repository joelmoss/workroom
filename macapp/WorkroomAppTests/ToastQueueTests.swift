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
      id: UUID(), targetID: "wr|/a|foo", tabID: UUID(), source: "a / foo",
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
}
