import XCTest

@testable import Workroom

/// IT2 verification: the libghostty runtime actually comes up inside the app bundle (ghostty_init
/// + ghostty_app_new succeed and the bundled GHOSTTY_RESOURCES_DIR resolves). Runs in the
/// Workroom.app test host, so Bundle.main.resourceURL is the app's Resources (where ghostty/ lives).
@MainActor
final class GhosttyAppTests: XCTestCase {
  func testEngineInitializes() {
    XCTAssertTrue(
      GhosttyApp.shared.isReady,
      "libghostty failed to initialize — check bundled ghostty resources and the pinned C API")
  }
}

/// T2: the pure notification mapper that replaces the deleted OSCParserTests coverage.
final class TerminalActivityMapperTests: XCTestCase {
  func testEmptyTitleIsKeptEmpty() {
    // No placeholder: a titleless notification stays titleless (the UI leads with the body).
    guard
      case .osc(let title, let body) = GhosttyRuntimeAdapter.terminalActivity(title: "", body: nil)
    else { return XCTFail("expected .osc") }
    XCTAssertEqual(title, "")
    XCTAssertNil(body)
  }

  func testTitleAndBodyPassThrough() {
    guard
      case .osc(let title, let body) = GhosttyRuntimeAdapter.terminalActivity(
        title: "Build done", body: "3 targets")
    else { return XCTFail("expected .osc") }
    XCTAssertEqual(title, "Build done")
    XCTAssertEqual(body, "3 targets")
  }

  func testEmptyBodyNormalizesToNil() {
    guard
      case .osc(_, let body) = GhosttyRuntimeAdapter.terminalActivity(title: "Hi", body: "")
    else { return XCTFail("expected .osc") }
    XCTAssertNil(body)
  }
}

/// The pure clipboard-confirmation copy mapper. The alert itself needs a live surface + window, so
/// what's pinned here is the part that can silently regress: that each request kind gets its own
/// prompt, and that a huge clipboard can't produce an unusable alert.
final class ClipboardConfirmationCopyTests: XCTestCase {
  typealias Kind = GhosttyRuntimeAdapter.ClipboardConfirmationKind

  func testEachRequestKindHasItsOwnPrompt() {
    let paste = GhosttyRuntimeAdapter.clipboardConfirmation(for: .paste, preview: "rm -rf /")
    let read = GhosttyRuntimeAdapter.clipboardConfirmation(for: .osc52Read, preview: "hunter2")
    let write = GhosttyRuntimeAdapter.clipboardConfirmation(for: .osc52Write, preview: "hunter2")

    XCTAssertEqual(paste.allowButton, "Paste")
    XCTAssertEqual(paste.denyButton, "Cancel")
    XCTAssertEqual(read.allowButton, "Allow")
    XCTAssertEqual(write.allowButton, "Allow")
    // Read and write are both "authorize OSC 52" but must not be interchangeable: one hands the
    // clipboard OUT, the other overwrites it.
    XCTAssertNotEqual(read.title, write.title)
    XCTAssertNotEqual(read.message, write.message)
  }

  func testPreviewIsIncludedVerbatimWhenShort() {
    let copy = GhosttyRuntimeAdapter.clipboardConfirmation(for: .osc52Read, preview: "hunter2")
    XCTAssertTrue(copy.message.contains("hunter2"))
  }

  func testLongPreviewIsTruncated() {
    let limit = GhosttyRuntimeAdapter.clipboardPreviewLimit
    let shown = GhosttyRuntimeAdapter.truncatedClipboardPreview(String(repeating: "a", count: 5000))
    XCTAssertEqual(shown.count, limit + 1, "expected \(limit) characters plus the ellipsis")
    XCTAssertTrue(shown.hasSuffix("…"))
  }

  func testPreviewAtTheLimitIsNotMarkedTruncated() {
    let exact = String(repeating: "a", count: GhosttyRuntimeAdapter.clipboardPreviewLimit)
    XCTAssertEqual(GhosttyRuntimeAdapter.truncatedClipboardPreview(exact), exact)
  }

  func testTruncationCountsGraphemeClusters() {
    // A flag emoji is several scalars; prefix(_:) on Characters must not split one.
    let limit = GhosttyRuntimeAdapter.clipboardPreviewLimit
    let shown = GhosttyRuntimeAdapter.truncatedClipboardPreview(
      String(repeating: "🇬🇧", count: limit + 10))
    XCTAssertEqual(shown.count, limit + 1)
    XCTAssertEqual(String(shown.dropLast()), String(repeating: "🇬🇧", count: limit))
  }

  func testEveryKindProducesBothButtons() {
    // Exhaustive over the enum: a new kind added without copy would ship an alert with no way out.
    for kind in [Kind.paste, .osc52Read, .osc52Write] {
      let copy = GhosttyRuntimeAdapter.clipboardConfirmation(for: kind, preview: "x")
      XCTAssertFalse(copy.title.isEmpty)
      XCTAssertFalse(copy.allowButton.isEmpty)
      XCTAssertFalse(copy.denyButton.isEmpty)
    }
  }
}
