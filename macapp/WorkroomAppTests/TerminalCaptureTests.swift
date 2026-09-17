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

  func testTidyBoundsHugeInputBeforeGraphemeWork() {
    // A whole scrollback (SCREEN reads scrollback + viewport) used to be split/walked as Characters
    // on the main thread — WORKROOM-3S. The byte bound must not change the answer: the tail is
    // identical to what an unbounded walk returns, with no replacement chars from a mid-scalar cut.
    let huge = String(repeating: "héllo wörld ", count: 20_000)  // ~280KB, multi-byte throughout
    let raw = huge + "\nFATAL: boom"
    let out = TerminalCapture.tidy(raw, maxBytes: 4096)
    XCTAssertNotNil(out)
    XCTAssertTrue(out!.hasSuffix("\nFATAL: boom"))
    XCTAssertLessThanOrEqual(out!.utf8.count, 4096)
    XCTAssertFalse(out!.contains("\u{FFFD}"))
    XCTAssertTrue(raw.hasSuffix(out!), "the bound must keep a true tail of the input")
  }

  func testTidyBoundStartsOnAScalarBoundary() {
    // 3-byte scalars with a budget whose cut lands MID-scalar (30000 - 4000 = 26000, 26000 % 3 = 2):
    // the byte slice must skip the stray continuation bytes rather than decode them as U+FFFD.
    let raw = String(repeating: "\u{20AC}", count: 10_000)  // € — 3 bytes each
    let out = TerminalCapture.tidy(raw, maxBytes: 1000)
    XCTAssertNotNil(out)
    XCTAssertFalse(out!.contains("\u{FFFD}"))
    XCTAssertTrue(out!.allSatisfy { $0 == "\u{20AC}" })
  }

  func testTidyKeepsContentBehindAHugeTrailingBlankRun() {
    // A screen read includes every empty cell below the cursor, so the blank tail can be far bigger
    // than the byte budget. Cutting to a byte tail BEFORE dropping those lines returned nil here —
    // the command's own error was thrown away and the diagnosis silently skipped.
    let raw = "FATAL: real error\n" + String(repeating: "   \n", count: 100_000)
    XCTAssertEqual(TerminalCapture.tidy(raw, maxBytes: 16_384), "FATAL: real error")
  }

  func testTidyReturnsNilForAllBlankInputOfAnySize() {
    XCTAssertNil(TerminalCapture.tidy(String(repeating: " \n", count: 100_000), maxBytes: 16_384))
  }

  func testTidyReturnsNilForANonPositiveCap() {
    // maxBytes <= 0 leaves room for nothing; the byte budget must not trap on the negative case.
    XCTAssertNil(TerminalCapture.tidy("boom", maxBytes: 0))
    XCTAssertNil(TerminalCapture.tidy("boom", maxBytes: -1))
  }

  func testTidyBoundDropsUpToThreeContinuationBytesFromA4ByteScalar() {
    // "😀" is 4 bytes/scalar, so `budget` (always a multiple of 4) lands aligned against a bare
    // repeat — only a short ASCII TAIL (after the run, since the cut is from the END) misaligns it,
    // dropping 1, 2, or 3 stray continuation bytes depending on the tail length. Not exercised by
    // the 2- and 3-byte-scalar cases above, which never combine a multi-byte run with a trailing
    // single-byte suffix.
    for tail in ["!", "!!", "!!!"] {
      let raw = String(repeating: "😀", count: 10_000) + tail
      let out = TerminalCapture.tidy(raw, maxBytes: 1000)
      XCTAssertNotNil(out, "tail=\(tail)")
      XCTAssertFalse(out!.contains("\u{FFFD}"), "tail=\(tail)")
      XCTAssertTrue(out!.hasSuffix(tail), "tail=\(tail)")
      XCTAssertEqual(out!.utf8.count, 996 + tail.count, "tail=\(tail)")
      XCTAssertTrue(
        out!.dropLast(tail.count).allSatisfy { $0 == "😀" },
        "tail=\(tail) — everything before the tail must be whole emoji")
    }
  }

  func testTidyStripsAUnicodeWhitespaceOnlyLineBoundedsAsciiCheckMisses() {
    // `bounded`'s own blank check is ASCII-only (space/tab) by design (see its doc comment) — a
    // trailing line of a Unicode whitespace character (NBSP, U+00A0) does not match it and survives
    // that pass unstripped. `tidy`'s own trim uses the full Unicode `.whitespaces` set, so the
    // two-tier design still produces the right answer — this pins that the outer pass is load-
    // bearing, not redundant with the byte-level fast path.
    let raw = "FATAL: real error\n\u{00A0}\u{00A0}\u{00A0}\n"
    XCTAssertEqual(TerminalCapture.tidy(raw, maxBytes: 16_384), "FATAL: real error")
  }

  func testTidyDoesNotCrashWhenMaxBytesMultipliedByFourWouldOverflow() {
    // `bounded`'s budget is `maxBytes * 4`; a plain multiply traps on overflow for a maxBytes near
    // Int.max. `multipliedReportingOverflow` must saturate instead of crashing — a defensive line
    // that only an input this extreme actually exercises.
    XCTAssertEqual(TerminalCapture.tidy("short output", maxBytes: Int.max), "short output")
  }
}
