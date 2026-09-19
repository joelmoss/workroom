import Foundation

/// A GitHub repository named explicitly (`host/owner/name`), so a `gh` probe needs no working
/// directory to find its repo — the precondition for asking about a repository that has no local
/// checkout (a remote workroom, issue #207).
///
/// **Every value is validated, and there is no other way to make one.** `owner` and `name` are
/// interpolated into a GraphQL string (`WorkroomStatusResolver.checkRollupQuery`) and `host` goes
/// to `gh` as an argument. That was safe while `gh` itself produced those strings; an identity that
/// can now be supplied from elsewhere (a registration, a test) must not be able to break the query
/// or read as a flag.
struct GitHubRepository: Hashable, Sendable {
  let host: String
  let owner: String
  let name: String

  private init(validated host: String, owner: String, name: String) {
    self.host = host
    self.owner = owner
    self.name = name
  }

  /// nil unless all three parts are well-formed. The single choke point every construction path
  /// (`init?(url:)`, a supplied identity) goes through.
  init?(host: String, owner: String, name: String) {
    guard Self.isValidHost(host), Self.isValidSegment(owner, allowLeadingHyphen: false),
      Self.isValidSegment(name, allowLeadingHyphen: true)
    else { return nil }
    self.init(validated: host.lowercased(), owner: owner, name: name)
  }

  /// Parses the `https://host/owner/name` form `gh repo view --json url` prints. Anything else —
  /// ssh-style remotes, extra path segments, an empty owner — is nil rather than a guess.
  init?(url string: String) {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http",
      var host = url.host, url.user == nil
    else { return nil }
    if let port = url.port { host += ":\(port)" }
    let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard segments.count == 2 else { return nil }
    var name = segments[1]
    if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
    self.init(host: host, owner: segments[0], name: name)
  }

  /// The `--repo` value: `[HOST/]OWNER/REPO`.
  var flag: String { "\(host)/\(owner)/\(name)" }

  /// GitHub owner and repository names: letters, digits, `.`, `_`, `-`. Never empty, never `.`/`..`.
  /// Neither is ever a bare argument — `flag` is always `host/owner/name` — so a leading `-` cannot
  /// read as an option; it is refused for an OWNER only because GitHub does not allow one there.
  /// (The host IS its own argument for `--hostname`, so `isValidHost` refuses it there.)
  private static func isValidSegment(_ s: String, allowLeadingHyphen: Bool) -> Bool {
    guard !s.isEmpty, s.count <= 100, s != ".", s != "..",
      allowLeadingHyphen || s.first != "-"
    else { return false }
    return s.unicodeScalars.allSatisfy { Self.segmentScalars.contains($0) }
  }

  /// DNS characters plus an optional `:port`; no leading `-` or `.`.
  private static func isValidHost(_ s: String) -> Bool {
    let parts = s.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 2, let hostname = parts.first, !hostname.isEmpty, hostname.count <= 253,
      hostname.first != "-", hostname.first != ".",
      hostname.unicodeScalars.allSatisfy({ Self.hostScalars.contains($0) })
    else { return false }
    if parts.count == 2 {
      guard let port = Int(parts[1]), (1...65535).contains(port), parts[1].allSatisfy(\.isNumber)
      else { return false }
    }
    return true
  }

  private static let segmentScalars = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
  private static let hostScalars = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
}

/// What a repository lookup decided. Mirrors `CIResolution`/`PRResolution`: `keepPrior` (a transient
/// blip) must reach every probe that depends on the lookup, or a flaky `gh repo view` blanks a good
/// PR panel, checks list and CI badge.
enum GitHubRepositoryResolution: Equatable, Sendable {
  case found(GitHubRepository)
  case absent  // gh missing/unauth, no remote, or not a GitHub repo
  case keepPrior
}
