import XCTest

@testable import Workroom

/// Pure logic behind the inline terminal agent's capture (issue #49): exit-code resolution from the
/// `command_finished` payload (incl. the `-1` "shell didn't report" sentinel and the child-exit
/// fallback) and the tidy/cap of rendered text. The `ghostty_surface_*` reads themselves need a live
/// surface and are covered by the spike / XCUITest, not here.
final class TerminalCaptureTests: XCTestCase {

  // MARK: resolveExitCode

  func testExitCodeUsesCommandFinishedWhenReported() {
    XCTAssertEqual(TerminalCapture.resolveExitCode(commandFinished: 0), 0)
    XCTAssertEqual(TerminalCapture.resolveExitCode(commandFinished: 1), 1)
    XCTAssertEqual(TerminalCapture.resolveExitCode(commandFinished: 127), 127)
    XCTAssertEqual(TerminalCapture.resolveExitCode(commandFinished: 255), 255)
  }

  func testExitCodeReportedWinsOverChildFallback() {
    // A real per-command code is authoritative even when a child-exit code is also present.
    XCTAssertEqual(TerminalCapture.resolveExitCode(commandFinished: 2, childExited: 99), 2)
  }

  func testExitCodeFallsBackToChildWhenShellOmitsStatus() {
    // -1 = the shell emitted OSC 133;D without a status (zsh payload-free D / some fish paths).
    XCTAssertEqual(TerminalCapture.resolveExitCode(commandFinished: -1, childExited: 143), 143)
  }

  func testExitCodeNilWhenUnknown() {
    XCTAssertNil(TerminalCapture.resolveExitCode(commandFinished: -1))
    XCTAssertNil(TerminalCapture.resolveExitCode(commandFinished: -1, childExited: nil))
  }

  // MARK: tidy

  func testTidyStripsTrailingBlankLines() {
    let raw = "❯ ls /nope\nls: /nope: No such file or directory\n   \n\n  \n"
    XCTAssertEqual(TerminalCapture.tidy(raw), "❯ ls /nope\nls: /nope: No such file or directory")
  }

  func testTidyKeepsInteriorBlankLines() {
    let raw = "first\n\nsecond\n"
    XCTAssertEqual(TerminalCapture.tidy(raw), "first\n\nsecond")
  }

  func testTidyReturnsNilForEmptyOrAllBlank() {
    XCTAssertNil(TerminalCapture.tidy(""))
    XCTAssertNil(TerminalCapture.tidy("   \n\t\n   \n"))
  }

  func testTidyLeavesUndersizedTextUnchanged() {
    let raw = "short error output"
    XCTAssertEqual(TerminalCapture.tidy(raw, maxBytes: 1024), "short error output")
  }

  func testTidyCapsKeepingTail() {
    // The error is the LAST line; capping must keep the end, not the head.
    let filler = String(repeating: "x", count: 5000)
    let raw = filler + "\nFATAL: port 3000 already in use"
    let out = TerminalCapture.tidy(raw, maxBytes: 64)
    XCTAssertNotNil(out)
    XCTAssertTrue(out!.hasSuffix("FATAL: port 3000 already in use"), "tail must be preserved")
    XCTAssertLessThanOrEqual(out!.utf8.count, 64)
  }

  func testTidyByteCapCutsOnCharacterBoundary() {
    // A run of 2-byte characters with an odd cap that can't land on a boundary: the cap must stay a
    // true bound (no U+FFFD inflation past it) and never split a character.
    let raw = String(repeating: "é", count: 2000)  // 2 bytes each
    let out = TerminalCapture.tidy(raw, maxBytes: 101)
    XCTAssertNotNil(out)
    XCTAssertLessThanOrEqual(out!.utf8.count, 101)
    XCTAssertEqual(out!.utf8.count, 100)  // 50 whole "é"; the 51st (→102) doesn't fit
    XCTAssertFalse(out!.contains("\u{FFFD}"), "must not split a character into a replacement char")
    XCTAssertTrue(out!.allSatisfy { $0 == "é" })
  }
}
