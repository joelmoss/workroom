import AppKit
import GhosttyKit
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
    let read = GhosttyRuntimeAdapter.clipboardConfirmation(for: .read, preview: "hunter2")
    let write = GhosttyRuntimeAdapter.clipboardConfirmation(for: .write, preview: "hunter2")

    XCTAssertEqual(paste.allowButton, "Paste")
    XCTAssertEqual(paste.denyButton, "Cancel")
    XCTAssertEqual(read.allowButton, "Allow")
    XCTAssertEqual(write.allowButton, "Allow")
    // Read and write are both "authorize a program's clipboard access" but must not be
    // interchangeable: one hands the clipboard OUT, the other overwrites it.
    XCTAssertNotEqual(read.title, write.title)
    XCTAssertNotEqual(read.message, write.message)
  }

  func testPreviewIsIncludedVerbatimWhenShort() {
    let copy = GhosttyRuntimeAdapter.clipboardConfirmation(for: .read, preview: "hunter2")
    XCTAssertTrue(copy.message.contains("hunter2"))
  }

  func testRequesterNameLeadsTheMessageWhenTheProtocolSuppliesOne() {
    // Naming who asked is most of what makes this prompt answerable. When no name is carried the
    // copy must still read as a sentence, not leave a hole.
    let named = GhosttyRuntimeAdapter.clipboardConfirmation(
      for: .read, preview: "hunter2", requester: "curl")
    let anonymous = GhosttyRuntimeAdapter.clipboardConfirmation(for: .read, preview: "hunter2")
    XCTAssertTrue(named.message.contains("curl"))
    XCTAssertFalse(anonymous.message.contains("curl"))
    XCTAssertTrue(anonymous.message.contains("An application running in this terminal"))
  }

  func testListPromptDoesNotLeakTheClipboardContents() {
    // A LIST request asks what representations exist, not for the data. Echoing the preview into
    // that prompt would show the user's clipboard for a request that never asked for it.
    let copy = GhosttyRuntimeAdapter.clipboardConfirmation(for: .list, preview: "hunter2")
    XCTAssertFalse(copy.message.contains("hunter2"))
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
    for kind in [Kind.paste, .read, .write, .list] {
      let copy = GhosttyRuntimeAdapter.clipboardConfirmation(for: kind, preview: "x")
      XCTAssertFalse(copy.title.isEmpty)
      XCTAssertFalse(copy.allowButton.isEmpty)
      XCTAssertFalse(copy.denyButton.isEmpty)
    }
  }
}

/// The pane's pointer (#466): which `NSCursor` each engine shape shows, and which one the pane shows
/// when its own ⌘-hover hand is up. AppKit applying it needs a window, so a person checks that.
@MainActor
final class MouseShapeCursorTests: XCTestCase {
  func testEachShapeShowsItsCursor() {
    let expected: [(ghostty_action_mouse_shape_e, NSCursor)] = [
      (GHOSTTY_MOUSE_SHAPE_DEFAULT, .arrow),
      (GHOSTTY_MOUSE_SHAPE_TEXT, .iBeam),
      (GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT, .iBeamCursorForVerticalLayout),
      (GHOSTTY_MOUSE_SHAPE_POINTER, .pointingHand),
      (GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU, .contextualMenu),
      (GHOSTTY_MOUSE_SHAPE_CROSSHAIR, .crosshair),
      (GHOSTTY_MOUSE_SHAPE_CELL, .crosshair),
      (GHOSTTY_MOUSE_SHAPE_ALIAS, .dragLink),
      (GHOSTTY_MOUSE_SHAPE_COPY, .dragCopy),
      (GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, .operationNotAllowed),
      (GHOSTTY_MOUSE_SHAPE_NO_DROP, .operationNotAllowed),
      (GHOSTTY_MOUSE_SHAPE_GRAB, .openHand),
      (GHOSTTY_MOUSE_SHAPE_GRABBING, .closedHand),
      (GHOSTTY_MOUSE_SHAPE_ZOOM_IN, .zoomIn),
      (GHOSTTY_MOUSE_SHAPE_ZOOM_OUT, .zoomOut),
    ]
    for (shape, cursor) in expected {
      XCTAssertIdentical(GhosttySurfaceView.cursor(for: shape), cursor, "shape \(shape.rawValue)")
    }
  }

  func testResizeShapesShowAResizeCursor() {
    let resizes = [
      GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
      GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE,
      GHOSTTY_MOUSE_SHAPE_S_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
      GHOSTTY_MOUSE_SHAPE_NW_RESIZE, GHOSTTY_MOUSE_SHAPE_SE_RESIZE, GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
      GHOSTTY_MOUSE_SHAPE_NESW_RESIZE, GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
    ]
    for shape in resizes {
      XCTAssertNotIdentical(
        GhosttySurfaceView.cursor(for: shape), NSCursor.arrow, "shape \(shape.rawValue)")
    }
  }

  func testShapesWithNoAppKitCursorShowTheArrow() {
    for shape in [
      GHOSTTY_MOUSE_SHAPE_HELP, GHOSTTY_MOUSE_SHAPE_PROGRESS, GHOSTTY_MOUSE_SHAPE_WAIT,
      GHOSTTY_MOUSE_SHAPE_MOVE, GHOSTTY_MOUSE_SHAPE_ALL_SCROLL,
      ghostty_action_mouse_shape_e(rawValue: 999),
    ] {
      XCTAssertIdentical(
        GhosttySurfaceView.cursor(for: shape), NSCursor.arrow, "shape \(shape.rawValue)")
    }
  }

  func testAPaneRestsOnTheIBeam() {
    // The engine never sends a starting shape; its own default is the I-beam.
    XCTAssertIdentical(
      GhosttySurfaceView.cursor(for: GhosttySurfaceView.restingMouseShape), NSCursor.iBeam)
  }

  func testTheHoverHandWinsOverTheEngineShape() {
    XCTAssertIdentical(
      GhosttySurfaceView.paneCursor(shape: GHOSTTY_MOUSE_SHAPE_TEXT, showingHand: true),
      NSCursor.pointingHand)
    XCTAssertIdentical(
      GhosttySurfaceView.paneCursor(shape: GHOSTTY_MOUSE_SHAPE_CROSSHAIR, showingHand: false),
      NSCursor.crosshair)
  }
}
