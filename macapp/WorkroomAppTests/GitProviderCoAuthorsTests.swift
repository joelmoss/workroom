import XCTest

@testable import Workroom

/// `GitProvider.coAuthors` parses GitHub-style `Co-authored-by:` trailers — git's author field holds
/// only one person, so co-authored commits need the trailer to show everyone (the rails repro:
/// commit 52306a97 has author Rosa Gutierrez + a Co-Authored-By trailer).
final class GitProviderCoAuthorsTests: XCTestCase {

  func testParsesRailsStyleTrailer() {
    let message = """
      Fix something

      Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
      """
    let co = GitProvider.coAuthors(inMessage: message, primaryEmail: "rosa@37signals.com")
    XCTAssertEqual(
      co, [VCSAuthor(name: "Claude Opus 4.8 (1M context)", email: "noreply@anthropic.com")])
  }

  func testKeyIsCaseInsensitive() {
    for key in ["Co-authored-by:", "Co-Authored-By:", "CO-AUTHORED-BY:", "co-authored-by:"] {
      let co = GitProvider.coAuthors(inMessage: "T\n\n\(key) A <a@x.com>", primaryEmail: "p@x.com")
      XCTAssertEqual(co, [VCSAuthor(name: "A", email: "a@x.com")], "failed for key \(key)")
    }
  }

  func testMultipleCoAuthorsInOrder() {
    let message = """
      T

      Co-authored-by: First <first@x.com>
      Co-authored-by: Second <second@x.com>
      """
    let co = GitProvider.coAuthors(inMessage: message, primaryEmail: "p@x.com")
    XCTAssertEqual(
      co,
      [
        VCSAuthor(name: "First", email: "first@x.com"),
        VCSAuthor(name: "Second", email: "second@x.com"),
      ])
  }

  func testDedupesAgainstPrimaryAndEachOther() {
    let message = """
      T

      Co-authored-by: Primary Dup <PRIMARY@x.com>
      Co-authored-by: Real <real@x.com>
      Co-authored-by: Real Again <REAL@x.com>
      """
    let co = GitProvider.coAuthors(inMessage: message, primaryEmail: "primary@x.com")
    XCTAssertEqual(co, [VCSAuthor(name: "Real", email: "real@x.com")])
  }

  func testSkipsTrailerWithoutEmail() {
    let co = GitProvider.coAuthors(
      inMessage: "T\n\nCo-authored-by: No Email Here", primaryEmail: "p@x.com")
    XCTAssertTrue(co.isEmpty)
  }

  func testNameFallsBackToEmailWhenBlank() {
    let co = GitProvider.coAuthors(
      inMessage: "T\n\nCo-authored-by: <lonely@x.com>", primaryEmail: "p@x.com")
    XCTAssertEqual(co, [VCSAuthor(name: "lonely@x.com", email: "lonely@x.com")])
  }

  func testNoTrailerYieldsEmpty() {
    XCTAssertTrue(
      GitProvider.coAuthors(inMessage: "Just a subject\n\nA body.", primaryEmail: "p@x.com").isEmpty
    )
  }
}
