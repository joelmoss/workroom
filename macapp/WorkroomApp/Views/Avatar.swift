import CryptoKit
import Defaults
import SwiftUI

extension VCSCommit {
  /// Every author's display name (falling back to email when a name is blank), comma-joined for a
  /// metadata line — so a commit's full authorship is shown, not just the first author.
  var authorNamesDisplay: String {
    authors
      .map { $0.name.isEmpty ? $0.email : $0.name }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }
}

/// A person shown in the UI — a VCS commit author or a GitHub PR reviewer — reduced to what an
/// avatar needs: a display name (initials + tooltip), a stable seed (deterministic fallback colour),
/// and an optional remote image URL. Authors resolve to a Gravatar (by email, `d=404` so unknown
/// emails fall through); reviewers to `github.com/<login>.png`; teams have no image. When the URL is
/// nil, still loading, or 404s/decodes-empty, the coloured initials chip shows instead.
struct AvatarSubject: Hashable {
  let displayName: String
  /// The stable colour seed — email / login (never the display name, which can collide or be empty).
  let seed: String
  let imageURL: URL?

  /// A commit author. Gravatar keyed by email; seed by email (falls back to name when email empty).
  init(author: VCSAuthor, pixelSize: Int) {
    displayName = author.name.isEmpty ? author.email : author.name
    let key = author.email.isEmpty ? author.name : author.email
    seed = key.lowercased()
    imageURL = Self.gravatar(email: author.email, pixelSize: pixelSize)
  }

  /// A GitHub reviewer. A user → `github.com/<login>.png`; a team → no image (initials on the slug).
  init(reviewer identity: Reviewer.Identity, displayName: String, pixelSize: Int) {
    self.displayName = displayName
    switch identity {
    case .user(let login):
      seed = login.lowercased()
      imageURL = Self.githubAvatar(login: login, pixelSize: pixelSize)
    case .team(let slug):
      seed = "team:" + slug.lowercased()
      imageURL = nil
    }
  }

  /// `https://www.gravatar.com/avatar/<md5(lowercased-trimmed-email)>?s=<px>&d=404`. `d=404` makes
  /// Gravatar 404 (not serve an identicon) when it has no image for the address, so the load fails
  /// and the initials chip shows — the same fallback path as an unknown GitHub login.
  private static func gravatar(email: String, pixelSize: Int) -> URL? {
    let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    let hash = hexString(Insecure.MD5.hash(data: Data(normalized.utf8)))
    return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=\(pixelSize)&d=404")
  }

  private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

  /// Lowercase hex, without Foundation's format machinery.
  ///
  /// This was `.map { String(format: "%02x", $0) }.joined()`, which is 16 full format-string parses
  /// (`+[NSString _stringWithValidatedFormat:]` → `__CFStringAppendFormatCore`) per author to produce
  /// 32 characters. That call was the leaf of the WORKROOM-2B App Hang sample, reached from
  /// `HistoryRow.body` via `AvatarSubject.init` once per author per row per body pass.
  ///
  /// Byte-identical to `%02x` by construction: lowercase, zero-padded, exactly two digits per byte,
  /// no locale involvement — which matters because the digest goes straight into the Gravatar URL, so
  /// any drift would silently break every avatar. `internal`, not `private`, so
  /// `AvatarSubjectTests` can pin it against the exact expression it replaced.
  static func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    var out: [UInt8] = []
    out.reserveCapacity(32)
    for byte in bytes {
      out.append(hexDigits[Int(byte >> 4)])
      out.append(hexDigits[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  private static func githubAvatar(login: String, pixelSize: Int) -> URL? {
    guard
      let encoded = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      !encoded.isEmpty
    else { return nil }
    return URL(string: "https://github.com/\(encoded).png?size=\(pixelSize)")
  }

  /// Initials for the fallback chip: first letters of the first two words, or the first two letters
  /// of a single-word name (e.g. "octocat" → "OC"). "?" when there's nothing to show.
  var initials: String {
    let words = displayName.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let first = words.first, let firstChar = first.first else { return "?" }
    if words.count >= 2, let secondChar = words[1].first {
      return String([firstChar, secondChar]).uppercased()
    }
    return String(first.prefix(2)).uppercased()
  }

  /// Deterministic fill colour for the initials chip. Uses a stable FNV-1a hash of the seed (NOT
  /// `String.hashValue`, which is per-process salted and would recolour every launch) mapped onto
  /// the hue wheel at a fixed saturation/brightness that reads on both light and dark themes.
  func fillColor() -> NSColor {
    var hash: UInt64 = 1_469_598_103_934_665_603  // FNV-1a offset basis
    for byte in seed.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    let hue = Double(hash % 360) / 360.0
    return NSColor(hue: hue, saturation: 0.55, brightness: 0.72, alpha: 1)
  }
}

/// Fetches + decodes avatar images, reading the actual HTTP status — unlike `AsyncImage`, whose
/// `.failure` phase carries only an `Error`, so "no avatar for this address" (Gravatar/GitHub 404,
/// requested with `d=404` on purpose — a miss really is a 404) and "the network dropped" used to land
/// identically. That ambiguity is why the OLD mitigation (`AvatarImageFailures`, a session `Set` of
/// failed URLs) had to clear itself on every app activation — it couldn't tell a genuine miss from a
/// transient one, so it could only bound the damage, not fix it. This loader can, and gets image
/// caching (no flicker on re-realization, needed since the History list is a `LazyVStack` — rows are
/// built as they scroll in) for free.
///
/// Session-lifetime, bounded LRU cache (`capacity`): Gravatar/GitHub avatars are 16–54px, so even a
/// few hundred cached decoded images stay small. A cached `.notFound` is permanent for the session (a
/// real 404 doesn't change mid-session); a `nil` result (network error, non-200/404 status, or an
/// undecodable 200 body) is NEVER cached, so the next realization of the row retries it — the same
/// self-healing property the old mitigation had, without needing an app-activation hook to get it.
@MainActor
final class AvatarImageLoader {
  static let shared = AvatarImageLoader()

  enum LoadResult: Equatable {
    case image(NSImage)
    case notFound
  }

  private let session: URLSession
  private let capacity: Int
  private var cache: [URL: LoadResult] = [:]
  /// Oldest-first insertion order, for LRU eviction — a plain array is fine at this scale (capacity
  /// is a few hundred at most).
  private var cacheOrder: [URL] = []
  /// De-duplicates concurrent requests for the same URL (e.g. two rows sharing an author scrolling
  /// into view together) — the second caller awaits the first's in-flight fetch instead of firing a
  /// second request.
  private var inFlight: [URL: Task<LoadResult?, Never>] = [:]

  init(session: URLSession = .shared, capacity: Int = 256) {
    self.session = session
    self.capacity = capacity
  }

  /// `nil` ⇒ transient — the caller should show initials for now; a later realization retries.
  func load(_ url: URL) async -> LoadResult? {
    if let cached = cache[url] { return cached }
    if let existing = inFlight[url] { return await existing.value }
    let task = Task<LoadResult?, Never> { [weak self] in
      await self?.fetch(url)
    }
    inFlight[url] = task
    let result = await task.value
    inFlight[url] = nil
    return result
  }

  private func fetch(_ url: URL) async -> LoadResult? {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(from: url)
    } catch {
      return nil  // transient: network error, cancellation, etc.
    }
    guard let http = response as? HTTPURLResponse else { return nil }
    if http.statusCode == 404 {
      store(.notFound, for: url)
      return .notFound
    }
    guard http.statusCode == 200, let image = NSImage(data: data) else {
      return nil  // transient: a non-200/404 status, or a 200 body that didn't decode
    }
    let result = LoadResult.image(image)
    store(result, for: url)
    return result
  }

  private func store(_ result: LoadResult, for url: URL) {
    if cache[url] == nil {
      cacheOrder.append(url)
      if cacheOrder.count > capacity {
        cache[cacheOrder.removeFirst()] = nil
      }
    }
    cache[url] = result
  }

  /// Test/QA seam: forget every cached result and in-flight request.
  func clearForTesting() {
    cache.removeAll()
    cacheOrder.removeAll()
    inFlight.removeAll()
  }
}

/// A single circular avatar: the remote image once it loads, the coloured initials chip otherwise
/// (nil URL, still loading, a genuine 404, or a transient failure). Decorative — the adjacent name
/// text carries the accessibility label, so the avatar is hidden from VoiceOver and only exposes a
/// hover tooltip.
struct AvatarView: View {
  let subject: AvatarSubject
  var size: CGFloat = 16
  private let theme = ThemeService.shared
  /// Privacy gate: when off, no avatar image is ever requested (the initials chip shows instead), so
  /// viewing an untrusted repo's history can't beacon the viewer to Gravatar/GitHub. See the key doc.
  @Default(.loadRemoteAvatars) private var loadRemoteAvatars
  /// Injected for tests (a real `URLProtocol` stub); defaults to the shared session-lifetime cache.
  var loader = AvatarImageLoader.shared
  @State private var result: AvatarImageLoader.LoadResult?

  /// `.task(id:)` needs ONE Hashable key covering everything that should restart the fetch — the URL
  /// itself, and the privacy gate (so flipping it on mid-session retries immediately rather than
  /// waiting for some unrelated re-identity).
  private var taskKey: String {
    "\(subject.imageURL?.absoluteString ?? "")\u{1F}\(loadRemoteAvatars)"
  }

  var body: some View {
    Group {
      if case .image(let image) = result {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        initials
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(theme.tokens.border, lineWidth: 0.5))
    .help(subject.displayName)
    .accessibilityHidden(true)
    .task(id: taskKey) {
      guard loadRemoteAvatars, let url = subject.imageURL else {
        result = nil
        return
      }
      result = await loader.load(url)
    }
  }

  private var initials: some View {
    let fill = subject.fillColor()
    return Circle()
      .fill(Color(nsColor: fill))
      .overlay(
        Text(subject.initials)
          .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
          .foregroundStyle(Color(nsColor: ThemeTokens.contrastingForeground(for: fill)))
          .minimumScaleFactor(0.5)
          .padding(1)
      )
  }
}

/// Overlapping circular avatars for a set of people — a commit's authors (jj changes can carry
/// several) or any multi-person context. One subject renders as a lone avatar; more overlap left
/// over right, each with a background-coloured ring so the overlap reads as a stack. Every subject
/// is shown (no cap) — a commit's full author set is always visible.
struct AvatarStack: View {
  let subjects: [AvatarSubject]
  var size: CGFloat = 16
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: -size * 0.35) {
      ForEach(Array(subjects.enumerated()), id: \.offset) { _, subject in
        AvatarView(subject: subject, size: size)
          .overlay(Circle().strokeBorder(theme.tokens.panel, lineWidth: 1.5))
      }
    }
    .accessibilityHidden(true)
  }
}
