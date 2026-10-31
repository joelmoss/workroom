import AppKit
import XCTest

@testable import Workroom

/// The creation pane's log, driven through its real `NSTextView`, without a window.
@MainActor
final class LogTextControllerTests: XCTestCase {
  private func makeLog(lines: Int) -> (LogTextController, [String]) {
    let log = LogTextController(padding: 10)
    log.scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
    let text = (0..<lines).map { "line \($0)" }
    log.show(text[...])
    return (log, text)
  }

  /// Value: protects=the reported bug, a whole log selects and copies at once, blank lines included,
  /// and a selection survives new lines; fails_when=lines sit in separate views, a blank line is
  /// lost, or an append replaces the text; no_claim=the mouse drag and ⌘A's routing to the text view
  func testSelectAllTakesEveryLineAndSurvivesNewLines() throws {
    let log = LogTextController(padding: 10)
    log.scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
    let lines = ["first", "", "third"]
    log.show(lines[...])

    log.textView.selectAll(nil)
    let selected = log.textView.selectedRange()
    XCTAssertEqual((log.textView.string as NSString).substring(with: selected), "first\n\nthird")

    log.show((lines + ["fourth"])[...])

    XCTAssertEqual(log.textView.selectedRange(), selected)
    XCTAssertEqual(log.textView.string, "first\n\nthird\nfourth")
  }

  /// Value: protects=D10, a log at its end follows new lines, and one scrolled up stays put until
  /// Jump to latest; fails_when=a reader is dragged down by new output, or the log stops following;
  /// no_claim=the Jump to latest button's drawing
  func testFollowsNewLinesOnlyWhileAtItsEnd() {
    var (log, lines) = makeLog(lines: 100)
    let clip = log.scrollView.contentView
    let atEnd = {
      CreationPanePresentation.isAtBottom(
        offset: clip.bounds.origin.y, visible: clip.bounds.height,
        content: log.textView.frame.height)
    }
    XCTAssertTrue(atEnd(), "opens at the latest output")

    lines.append("next")
    log.show(lines[...])
    XCTAssertTrue(atEnd(), "follows a new line")

    clip.scroll(to: NSPoint(x: 0, y: 20))
    XCTAssertFalse(log.following)
    lines.append("another")
    log.show(lines[...])
    XCTAssertEqual(clip.bounds.origin.y, 20, "stays put")

    log.scrollToEnd()
    XCTAssertTrue(log.following)
    XCTAssertTrue(atEnd())
  }
}
