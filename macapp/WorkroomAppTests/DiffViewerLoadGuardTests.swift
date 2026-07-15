import XCTest

@testable import Workroom

/// Regression tests for `DiffViewer.shouldLoad` — the load-once-per-file guard behind the diff pane's
/// `.task(id: fetchKey)`. It exists because a spurious body re-render (SwiftUI re-firing the task on
/// the same view instance after `applyHighlight` populates highlight lines, with `fetchKey`
/// UNCHANGED) used to re-enter `load()`, reset `state = .loading`, re-render, re-highlight… a ~150ms
/// feedback loop that left the pane stuck on its loader forever (issue #59). The guard must treat a
/// same-key re-fire as a no-op while still reloading on a real file switch.
final class DiffViewerLoadGuardTests: XCTestCase {

  func testFirstEverLoadRuns() {
    // No prior load (loadedKey nil) → the initial load must run.
    XCTAssertTrue(DiffViewer.shouldLoad(loadedKey: nil, fetchKey: "commit:abc\u{1F}user.rb"))
  }

  func testSameKeyReFireIsSkipped() {
    // The regression: the task re-fires with the SAME fetchKey after a highlight-driven re-render.
    // This MUST be a no-op — otherwise load() re-enters and the loader spins forever.
    let key = "commit:abc\u{1F}user.rb"
    XCTAssertFalse(
      DiffViewer.shouldLoad(loadedKey: key, fetchKey: key),
      "a re-fire with an unchanged fetchKey must not reload")
  }

  func testChangedFileReloads() {
    // A genuine file/revision switch changes fetchKey → reload.
    XCTAssertTrue(
      DiffViewer.shouldLoad(
        loadedKey: "commit:abc\u{1F}user.rb", fetchKey: "commit:abc\u{1F}post.rb"),
      "a different file must reload")
    XCTAssertTrue(
      DiffViewer.shouldLoad(
        loadedKey: "commit:abc\u{1F}user.rb", fetchKey: "commit:def\u{1F}user.rb"),
      "the same file at a different revision must reload")
  }
}
