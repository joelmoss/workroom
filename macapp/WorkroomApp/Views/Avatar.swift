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
    let hash = Insecure.MD5.hash(data: Data(normalized.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=\(pixelSize)&d=404")
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

/// A single circular avatar: the remote image once it loads, the coloured initials chip otherwise
/// (nil URL, in-flight, or a 404/empty decode). Decorative — the adjacent name text carries the
/// accessibility label, so the avatar is hidden from VoiceOver and only exposes a hover tooltip.
struct AvatarView: View {
  let subject: AvatarSubject
  var size: CGFloat = 16
  private let theme = ThemeService.shared
  /// Privacy gate: when off, no avatar image is ever requested (the initials chip shows instead), so
  /// viewing an untrusted repo's history can't beacon the viewer to Gravatar/GitHub. See the key doc.
  @Default(.loadRemoteAvatars) private var loadRemoteAvatars

  var body: some View {
    Group {
      if loadRemoteAvatars, let url = subject.imageURL {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.15))) {
          phase in
          if case .success(let image) = phase {
            image.resizable().scaledToFill()
          } else {
            initials
          }
        }
      } else {
        initials
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(theme.tokens.border, lineWidth: 0.5))
    .help(subject.displayName)
    .accessibilityHidden(true)
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
