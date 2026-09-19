import XCTest

@testable import Workroom

final class GitHubRepositoryTests: XCTestCase {
  // MARK: - Validation (the single choke point)

  /// `owner` and `name` are interpolated into a GraphQL string and `host` goes to `gh` as an
  /// argument, so nothing malformed may exist as a value.
  func testRejectsMalformedParts() {
    let bad: [(String, String, String)] = [
      ("github.com", "o\"){x", "r"),  // a quote breaks the query
      ("github.com", "o", "r\"){x"),
      ("github.com", "o wner", "r"),  // whitespace
      ("github.com", "o", "r\nx"),
      ("github.com", "-o", "r"),  // GitHub does not allow a leading hyphen on an owner
      ("github.com", "", "r"),
      ("github.com", "o", ""),
      ("github.com", ".", "r"),
      ("github.com", "o", ".."),
      ("github.com", "öwner", "r"),  // not a GitHub name
      ("github.com", "o/x", "r"),
      ("github.com", "o", String(repeating: "a", count: 101)),
      ("", "o", "r"),
      ("-github.com", "o", "r"),
      (".github.com", "o", "r"),
      ("github.com/evil", "o", "r"),
      ("git hub.com", "o", "r"),
      ("github.com:", "o", "r"),
      ("github.com:abc", "o", "r"),
      ("github.com:0", "o", "r"),
      ("github.com:99999", "o", "r"),
      ("a:1:2", "o", "r"),
    ]
    for (host, owner, name) in bad {
      XCTAssertNil(
        GitHubRepository(host: host, owner: owner, name: name), "\(host) / \(owner) / \(name)")
    }
  }

  /// The check must not reject a name GitHub really allows, or that repository silently shows no
  /// PR/CI (an unresolved identity is `absent`).
  func testAcceptsLegalUnusualNames() throws {
    let legal: [(String, String, String)] = [
      ("github.com", "o", "r"),
      ("github.com", "octocat", ".github"),
      ("github.com", "a-b", "my_repo.js"),
      ("github.com", "o", "-leading-hyphen"),  // never a bare argument: `flag` is host/owner/name
      ("github.com", "user_shortcode", "r"),  // Enterprise Managed Users
      ("github.com", String(repeating: "a", count: 39), "r"),
      ("github.com", "o", String(repeating: "r", count: 100)),
      ("ghe.example.com", "o", "r"),
      ("ghe.example.com:8443", "o", "r"),
      ("acme.ghe.com", "o", "r"),
    ]
    for (host, owner, name) in legal {
      let repo = try XCTUnwrap(
        GitHubRepository(host: host, owner: owner, name: name), "\(host) / \(owner) / \(name)")
      XCTAssertEqual(repo.flag, "\(host)/\(owner)/\(name)")
    }
  }

  func testHostIsLowercased() throws {
    let repo = try XCTUnwrap(GitHubRepository(host: "GitHub.COM", owner: "o", name: "r"))
    XCTAssertEqual(repo.host, "github.com")
    XCTAssertEqual(repo, GitHubRepository(host: "github.com", owner: "o", name: "r"))
  }

  // MARK: - URL parsing (`gh repo view --json url`)

  func testParsesTheURLGhPrints() throws {
    let expected = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "octo", name: "repo"))
    for url in [
      "https://github.com/octo/repo",
      "https://github.com/octo/repo\n",  // gh's trailing newline
      "  https://github.com/octo/repo  ",
      "https://github.com/octo/repo/",
      "https://github.com/octo/repo.git",
      "https://GitHub.com/octo/repo",
    ] {
      XCTAssertEqual(GitHubRepository(url: url), expected, url)
    }
  }

  func testParsesAnEnterpriseHostAndPort() throws {
    XCTAssertEqual(
      GitHubRepository(url: "https://ghe.example.com/o/r"),
      GitHubRepository(host: "ghe.example.com", owner: "o", name: "r"))
    XCTAssertEqual(
      GitHubRepository(url: "https://ghe.example.com:8443/o/r")?.flag, "ghe.example.com:8443/o/r")
  }

  /// Anything that is not the plain `https://host/owner/name` form is nil rather than a guess.
  func testRejectsWhatIsNotARepositoryURL() {
    for url in [
      "",
      "\n",
      "git@github.com:octo/repo.git",  // ssh-style: not what `--json url` prints
      "ssh://git@github.com/octo/repo",
      "file:///octo/repo",
      "https://github.com",
      "https://github.com/octo",
      "https://github.com/octo/repo/pulls",  // extra path segments
      "https://github.com//repo",
      "https://user@github.com/octo/repo",  // credentials in the URL
      "https://github.com/octo/re po",
      "https://github.com/octo/repo\"){x",
      "octo/repo",
    ] {
      XCTAssertNil(GitHubRepository(url: url), url)
    }
  }
}
