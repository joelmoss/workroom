import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// The regression net for **WORKROOM-2T** — the ≥2000 ms App Hang whose sampled stack landed inside
/// SwiftUI's accessibility focus-responder walk (`ResponderNode.visitFocusResponders`), reached from
/// `DiffViewer.unifiedBody`/`sideBySideBody` rendering every line of a near-2000-line diff eagerly. The
/// fix replaced the eager `ScrollView { VStack {...} }` with `List`, which is `NSTableView`-backed and
/// virtualizes both rendering and accessibility together for offscreen rows — see the doc comments on
/// `unifiedBody`/`sideBySideBody` for the full mechanism.
///
/// This suite asserts the property that would have caught the regression: a near-cap diff must realize
/// far fewer rows than its line count, and doing so must cost main-thread milliseconds, not seconds
/// (mirrors `HistoryRowInvalidationTests`'s `testLargePageDoesNotBuildEveryRow`/
/// `testLargePageRendersUnderTimeCeiling` — a body-pass count proves the mechanism changed, only wall
/// clock proves the thread stayed free).
///
/// Harness: the offscreen-`NSWindow` hosting pattern from `PaneRenderingTests`/`HistoryRowInvalidationTests`.
/// The huge diff itself comes from `UITestFixture.hugeDiff()` via the `huge.css` magic path — reached
/// by forcing `UITestFixture.isActive` on for the duration of this suite (a plain unit-test process
/// doesn't set the `-WorkroomUITestFixture` launch argument the way `WorkroomAppUITests` does, so the
/// flag is set directly on `UserDefaults.standard` and reset in `tearDown`).
@MainActor
final class DiffViewerLazyRenderingTests: XCTestCase {

  private static let hunkCount = 20
  private static let linesPerHunk = 100
  private static var lineCount: Int { hunkCount * linesPerHunk }

  override func setUp() {
    super.setUp()
    UserDefaults.standard.set(true, forKey: UITestFixture.defaultsKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: UITestFixture.defaultsKey)
    super.tearDown()
  }

  private func hugeDescriptor() -> DiffDescriptor {
    DiffDescriptor(path: "huge.css", change: .modified, source: .gitWorktree, isPreview: false)
  }

  /// Host the real `DiffViewer` offscreen. Width ≥ `DiffViewer.sideBySideMinWidth` isn't required here
  /// (unified is the default layout without a `viewModeOverride`); height is a realistic tab content
  /// area, not the whole screen, so "how many rows does it build" is a meaningful question.
  private func host(_ descriptor: DiffDescriptor) -> (NSWindow, NSView) {
    let root = DiffViewer(
      descriptor: descriptor, directory: "/diff-lazy-rendering", projectRoot: nil
    )
    .frame(width: 700, height: 500)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    // A programmatic NSWindow defaults `isReleasedWhenClosed` to true, which would over-release on top
    // of ARC — same reasoning as `PaneRenderingTests.host`/`HistoryRowInvalidationTests.host`.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    return (window, hosting)
  }

  // Both settle() calls below deliberately use the shared helper's default (no early-exit
  // condition): these are scale/amplification checks (List must realize far fewer rows than
  // `lineCount`, and must do so within a time ceiling) — an early exit as soon as ANY row renders
  // would stop the observation window before a real "list went eager again" regression has a
  // chance to fully manifest, masking exactly the WORKROOM-2T defect this suite exists to catch.

  func testHugeDiffDoesNotBuildEveryLine() throws {
    DiffViewer.lineRowBodyPasses = 0
    let (window, view) = host(hugeDescriptor())
    defer { window.close() }
    settle(view)

    // Anti-vacuity guard: "far fewer than all of them" is only meaningful if lines rendered at all —
    // a pane stuck on its loader would otherwise pass this test having drawn nothing.
    XCTAssertGreaterThan(
      DiffViewer.lineRowBodyPasses, 0, "the fixture must actually render diff lines")
    // Deliberately not an exact number: how far past the viewport `List` realizes is its own business
    // and can shift between OS releases. "Far fewer than all of them" is the property that matters —
    // the eager `VStack` this replaced would have built exactly `lineCount`.
    XCTAssertLessThan(
      DiffViewer.lineRowBodyPasses, Self.lineCount,
      "a 700×500 pane shows a small fraction of \(Self.lineCount) lines, so building all of them means "
        + "the list is eager again — the WORKROOM-2T regression this test exists to catch")
  }

  func testHugeDiffRendersUnderTimeCeiling() throws {
    DiffViewer.lineRowBodyPasses = 0
    let started = Date()
    let (window, view) = host(hugeDescriptor())
    defer { window.close() }
    settle(view)
    let elapsed = Date().timeIntervalSince(started)

    // A count proves the mechanism changed; only wall clock proves the main thread stayed free. The
    // ceiling is generous — comfortably under the 2s app-hang watchdog and far above what a lazy list
    // costs — so a loaded CI machine can't flake it while a genuine regression (2000 accessibility
    // elements materializing eagerly, WORKROOM-2T's actual shape) still fails it.
    XCTAssertLessThan(
      elapsed, 1.0,
      "loading + first layout of a \(Self.lineCount)-line diff took "
        + "\(String(format: "%.3f", elapsed))s on the main thread")
  }

  /// Multi-hunk shape check: `unifiedBody` nests `ForEach(hunk.lines)` inside `ForEach(hunks)` inside
  /// one `List` — this pins that the nesting doesn't silently defeat virtualization (a single giant
  /// hunk could theoretically behave differently from many separate ones, which is the real diff's
  /// actual shape). `UITestFixture.hugeDiff()` always builds `hunkCount` separate hunks.
  func testHugeDiffKeepsMultipleHunks() {
    guard
      case .diff(let diff) = UITestFixture.hugeDiff(
        hunkCount: Self.hunkCount, linesPerHunk: Self.linesPerHunk)
    else {
      return XCTFail("hugeDiff() must produce a parsed diff")
    }
    XCTAssertEqual(diff.hunks.count, Self.hunkCount)
    XCTAssertEqual(
      diff.hunks.map(\.lines.count), Array(repeating: Self.linesPerHunk, count: Self.hunkCount))
  }
}
