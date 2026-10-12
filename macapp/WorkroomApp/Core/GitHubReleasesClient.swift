import Foundation

/// One GitHub release from `GET /repos/{owner}/{repo}/releases`. Only the fields the "What's New"
/// dialog needs; explicit `CodingKeys` map the API's snake_case (avoids the `html_url` → `htmlUrl`
/// vs `htmlURL` mismatch that `.convertFromSnakeCase` would introduce).
struct GitHubRelease: Decodable, Equatable {
  let tagName: String
  let name: String?
  let body: String?
  let draft: Bool
  let prerelease: Bool
  let publishedAt: Date?
  let htmlURL: URL?

  private enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case name
    case body
    case draft
    case prerelease
    case publishedAt = "published_at"
    case htmlURL = "html_url"
  }
}

/// Seam (mirrors the app's `CommandRunning` pattern) so `WhatsNewService`'s filtering / offline-retry
/// logic is unit-testable with a fake instead of live network. The real implementation is
/// `GitHubReleasesClient`.
protocol ReleasesFetching: Sendable {
  func releases() async throws -> [GitHubRelease]
}

/// Fetches public releases from the GitHub REST API (unauthenticated). One request per launch when a
/// version bump is detected — well under the 60 req/hr unauthenticated limit. GitHub returns 403 for
/// requests without a `User-Agent`, so one is always sent. The app is non-sandboxed
/// (`project.yml` `ENABLE_APP_SANDBOX: NO`), so no network entitlement is required and default ATS
/// permits the HTTPS call.
struct GitHubReleasesClient: ReleasesFetching {
  static let owner = "joelmoss"
  static let repo = "workroom"

  /// Explicit (NOT silent) cap: 100 is GitHub's max page size and far exceeds any realistic skipped
  /// span. We never paginate further — a span of >100 releases back would be truncated, which is an
  /// accepted limit, not a bug.
  static let perPage = 100

  private let session: URLSession
  init(session: URLSession = .shared) { self.session = session }

  func releases() async throws -> [GitHubRelease] {
    var comps = URLComponents(
      string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases")!
    comps.queryItems = [URLQueryItem(name: "per_page", value: String(Self.perPage))]

    var req = URLRequest(url: comps.url!)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    req.setValue(
      "Workroom-macOS (github.com/\(Self.owner)/\(Self.repo))", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 15

    let (data, response) = try await session.data(for: req)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try Self.decoder.decode([GitHubRelease].self, from: data)
  }

  /// Shared decoder — GitHub timestamps are ISO 8601 (`2024-06-17T12:34:56Z`).
  static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
}
