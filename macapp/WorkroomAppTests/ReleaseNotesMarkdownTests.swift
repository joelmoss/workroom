import XCTest

@testable import Workroom

/// The block classifier behind `ReleaseNotesMarkdown` — it splits release-note markdown into
/// headings / bullets / paragraphs so block layout survives (SwiftUI's `AttributedString(markdown:)`
/// alone flattens it). Inline markup and the plain-text fallback are exercised at render time.
@MainActor
final class ReleaseNotesMarkdownTests: XCTestCase {
  func testHeadingLevels() {
    XCTAssertEqual(ReleaseNotesMarkdown.blocks(from: "# Title"), [.heading("Title", level: 1)])
    XCTAssertEqual(ReleaseNotesMarkdown.blocks(from: "## Sub"), [.heading("Sub", level: 2)])
    // Levels deeper than 3 cap at 3 for styling.
    XCTAssertEqual(ReleaseNotesMarkdown.blocks(from: "##### Deep"), [.heading("Deep", level: 3)])
  }

  func testBareHashWithoutSpaceIsParagraph() {
    XCTAssertEqual(ReleaseNotesMarkdown.blocks(from: "#tag"), [.paragraph("#tag")])
  }

  func testBulletMarkers() {
    XCTAssertEqual(ReleaseNotesMarkdown.blocks(from: "- one"), [.bullet("one")])
    XCTAssertEqual(ReleaseNotesMarkdown.blocks(from: "* two"), [.bullet("two")])
    XCTAssertEqual(ReleaseNotesMarkdown.blocks(from: "+ three"), [.bullet("three")])
  }

  func testParagraph() {
    XCTAssertEqual(
      ReleaseNotesMarkdown.blocks(from: "Just some prose."), [.paragraph("Just some prose.")])
  }

  func testBlankLinesCollapseAndTrim() {
    let blocks = ReleaseNotesMarkdown.blocks(from: "\n\n# Title\n\n\n- a\n\n")
    XCTAssertEqual(blocks, [.heading("Title", level: 1), .spacer, .bullet("a")])
  }

  func testMixedDocument() {
    let md = "## Highlights\n- First\n- Second\n\nA closing paragraph."
    XCTAssertEqual(
      ReleaseNotesMarkdown.blocks(from: md),
      [
        .heading("Highlights", level: 2),
        .bullet("First"),
        .bullet("Second"),
        .spacer,
        .paragraph("A closing paragraph."),
      ])
  }

  func testEmptyBodyProducesNoBlocks() {
    XCTAssertEqual(ReleaseNotesMarkdown.blocks(from: ""), [])
    XCTAssertEqual(ReleaseNotesMarkdown.blocks(from: "\n\n"), [])
  }

  func testCRLFNormalised() {
    XCTAssertEqual(
      ReleaseNotesMarkdown.blocks(from: "# A\r\n- b"), [.heading("A", level: 1), .bullet("b")])
  }
}
