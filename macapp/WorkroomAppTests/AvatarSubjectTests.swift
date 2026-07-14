import XCTest

@testable import Workroom

/// `AvatarSubject` is pure value logic — URL construction, email normalisation, initials, and the
/// stable (non-salted) fallback colour. All unit-testable without a view.
final class AvatarSubjectTests: XCTestCase {

  // MARK: Commit authors → Gravatar

  func testAuthorGravatarURLShape() {
    let s = AvatarSubject(
      author: VCSAuthor(name: "Joel Moss", email: "joel@example.com"), pixelSize: 42)
    XCTAssertEqual(s.displayName, "Joel Moss")
    let url = try? XCTUnwrap(s.imageURL?.absoluteString)
    // md5 hex (32 chars) + the size + the `d=404` fall-through flag.
    let pattern = #"^https://www\.gravatar\.com/avatar/[0-9a-f]{32}\?s=42&d=404$"#
    XCTAssertNotNil(
      url?.range(of: pattern, options: .regularExpression), "unexpected URL: \(url ?? "nil")")
  }

  func testGravatarNormalisesCaseAndWhitespace() {
    let a = AvatarSubject(author: VCSAuthor(name: "A", email: "  Joel@Example.COM "), pixelSize: 42)
    let b = AvatarSubject(author: VCSAuthor(name: "B", email: "joel@example.com"), pixelSize: 42)
    XCTAssertEqual(a.imageURL, b.imageURL, "email hash must ignore case + surrounding whitespace")
  }

  func testAuthorWithoutEmailHasNoImageAndUsesName() {
    let s = AvatarSubject(author: VCSAuthor(name: "Nameless", email: ""), pixelSize: 42)
    XCTAssertNil(s.imageURL)
    XCTAssertEqual(s.displayName, "Nameless")
    XCTAssertEqual(s.seed, "nameless")
  }

  func testAuthorWithoutNameFallsBackToEmailForDisplay() {
    let s = AvatarSubject(author: VCSAuthor(name: "", email: "ghost@example.com"), pixelSize: 42)
    XCTAssertEqual(s.displayName, "ghost@example.com")
  }

  // MARK: GitHub reviewers

  func testReviewerUserAvatarURL() {
    let s = AvatarSubject(reviewer: .user(login: "octocat"), displayName: "octocat", pixelSize: 32)
    XCTAssertEqual(s.imageURL?.absoluteString, "https://github.com/octocat.png?size=32")
    XCTAssertEqual(s.seed, "octocat")
  }

  func testReviewerTeamHasNoImage() {
    let s = AvatarSubject(reviewer: .team(slug: "platform"), displayName: "platform", pixelSize: 32)
    XCTAssertNil(s.imageURL)
    XCTAssertEqual(s.seed, "team:platform")
  }

  // MARK: Initials

  func testInitials() {
    func initials(_ name: String) -> String {
      AvatarSubject(author: VCSAuthor(name: name, email: "x@y.z"), pixelSize: 42).initials
    }
    XCTAssertEqual(initials("Joel Moss"), "JM")
    XCTAssertEqual(initials("octocat"), "OC")  // single word → first two letters
    XCTAssertEqual(initials("a"), "A")
    XCTAssertEqual(initials("  Grace   Hopper "), "GH")
  }

  func testInitialsEmptyName() {
    // Empty name + empty email → displayName is empty → "?".
    let s = AvatarSubject(author: VCSAuthor(name: "", email: ""), pixelSize: 42)
    XCTAssertEqual(s.initials, "?")
  }

  // MARK: All authors shown

  private func commit(authors: [VCSAuthor]) -> VCSCommit {
    VCSCommit(
      commitID: "c", shortID: "c", changeID: nil, summary: "s", body: "", authors: authors,
      timestamp: Date(timeIntervalSince1970: 0), refs: [], parentIDs: [], isWorkingCopy: false)
  }

  func testAuthorNamesDisplayJoinsAllAuthors() {
    let c = commit(authors: [
      VCSAuthor(name: "Grace Hopper", email: "grace@example.com"),
      VCSAuthor(name: "Ada Lovelace", email: "ada@example.com"),
    ])
    XCTAssertEqual(c.authorNamesDisplay, "Grace Hopper, Ada Lovelace")
  }

  func testAuthorNamesDisplayFallsBackToEmailAndDropsBlanks() {
    let c = commit(authors: [
      VCSAuthor(name: "", email: "ghost@example.com"),  // → email
      VCSAuthor(name: "", email: ""),  // → dropped
      VCSAuthor(name: "Real Name", email: "real@example.com"),
    ])
    XCTAssertEqual(c.authorNamesDisplay, "ghost@example.com, Real Name")
  }

  func testAuthorNamesDisplayEmptyWhenNoAuthors() {
    XCTAssertEqual(commit(authors: []).authorNamesDisplay, "")
  }

  // MARK: Deterministic colour (stable across launches — FNV, not salted `hashValue`)

  func testFillColorIsDeterministicForSameSeed() {
    let a = AvatarSubject(author: VCSAuthor(name: "One", email: "joel@example.com"), pixelSize: 42)
    let b = AvatarSubject(author: VCSAuthor(name: "Two", email: "JOEL@example.com"), pixelSize: 42)
    XCTAssertEqual(a.fillColor().hueComponent, b.fillColor().hueComponent, accuracy: 0.0001)
  }

  func testFillColorMatchesStableFNVHash() {
    // Independent reimplementation of the FNV-1a → hue contract: proves the colour is derived from a
    // stable hash of the seed, not Swift's per-process-salted `String.hashValue`.
    func expectedHue(_ seed: String) -> Double {
      var hash: UInt64 = 1_469_598_103_934_665_603
      for byte in seed.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
      }
      return Double(hash % 360) / 360.0
    }
    let s = AvatarSubject(author: VCSAuthor(name: "x", email: "joel@example.com"), pixelSize: 42)
    XCTAssertEqual(s.fillColor().hueComponent, expectedHue("joel@example.com"), accuracy: 0.0001)
  }
}
