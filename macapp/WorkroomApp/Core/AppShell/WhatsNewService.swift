import Defaults
import Foundation

/// One release's notes, ready for `WhatsNewSheet`.
struct ReleaseNote: Identifiable, Equatable {
  /// Display version — the tag with any leading "v" stripped.
  let version: String
  /// Release name, or the version when the release is unnamed.
  let title: String
  let bodyMarkdown: String
  let date: Date?
  let url: URL?
  var id: String { version }
}

/// Drives the "What's New" feature: the silent first-launch-after-update check. It only *fetches and
/// filters* — presentation is owned window-side (`RootView`), gated to the launch/restore window so
/// multiple windows never stack duplicate dialogs.
@MainActor
final class WhatsNewService: ObservableObject {
  private let fetcher: ReleasesFetching
  /// The running app version. Injectable so the launch/retry branches are deterministic in tests;
  /// defaults to the real bundle version in the app.
  private let currentVersion: String?

  /// Auto-fetch gives up after this many consecutive failures for one version, so a persistently
  /// blocked machine (firewall / privacy tool / outage) stops firing a doomed request every launch.
  static let maxAutoAttempts = 3

  init(fetcher: ReleasesFetching, currentVersion: String? = AppVersion.current) {
    self.fetcher = fetcher
    self.currentVersion = currentVersion
  }

  /// First-launch-after-update check. Silent: returns the notes to show, or nil for "no dialog".
  ///
  /// `lastSeenVersion` advances only once a fetch *resolves* (success or confirmed-empty), or after
  /// `maxAutoAttempts` transient failures — never on a single transient error, so a brief offline
  /// blip on the post-update launch doesn't lose the notes forever.
  func checkOnLaunch() async -> [ReleaseNote]? {
    if UITestFixture.forceWhatsNew { return UITestFixture.whatsNewNotes }

    guard let currentStr = currentVersion, let current = SemanticVersion(currentStr) else {
      return nil  // unparseable running version: skip, never crash
    }
    guard let lastStr = Defaults[.lastSeenVersion], let last = SemanticVersion(lastStr) else {
      // Fresh install / first launch after this feature shipped: record, no backfill.
      Defaults[.lastSeenVersion] = currentStr
      return nil
    }
    guard last < current else { return nil }  // equal or downgrade → nothing to show

    do {
      let releases = try await fetcher.releases()
      let notes = Self.notes(from: releases, after: last, upTo: current)
      Defaults[.lastSeenVersion] = currentStr
      resetAttempts()
      return notes.isEmpty ? nil : notes
    } catch {
      recordFailedAttempt(for: currentStr)
      return nil
    }
  }

  // MARK: - Retry bookkeeping

  private func resetAttempts() {
    Defaults[.whatsNewAttempts] = 0
    Defaults[.whatsNewAttemptVersion] = nil
  }

  private func recordFailedAttempt(for currentStr: String) {
    var attempts = Defaults[.whatsNewAttempts]
    // A new running version restarts the count (the old attempts were for a different version).
    if Defaults[.whatsNewAttemptVersion] != currentStr { attempts = 0 }
    attempts += 1
    Defaults[.whatsNewAttemptVersion] = currentStr
    if attempts >= Self.maxAutoAttempts {
      // Give up auto-fetching this version: advance the marker so we stop retrying every launch.
      Defaults[.lastSeenVersion] = currentStr
      resetAttempts()
    } else {
      Defaults[.whatsNewAttempts] = attempts
    }
  }

  // MARK: - Pure filtering (tested via a fake fetcher)

  /// Releases strictly after `last`, up to and including `current`. Only valid-SemVer tags (this
  /// naturally excludes the `appcast` pseudo-release — no special-case needed) and no drafts; a tag
  /// that won't parse is skipped rather than fatal, so one bad release can't hide its siblings.
  /// Newest first.
  static func notes(
    from releases: [GitHubRelease], after last: SemanticVersion, upTo current: SemanticVersion
  ) -> [ReleaseNote] {
    parsed(releases)
      .filter { last < $0.0 && $0.0 <= current }
      .sorted { $0.0 > $1.0 }
      .map { note(from: $0.1) }
  }

  /// Non-draft releases paired with their parsed version; unparseable tags dropped.
  private static func parsed(_ releases: [GitHubRelease]) -> [(SemanticVersion, GitHubRelease)] {
    releases
      .filter { !$0.draft }
      .compactMap { rel in SemanticVersion(rel.tagName).map { ($0, rel) } }
  }

  private static func note(from rel: GitHubRelease) -> ReleaseNote {
    let version = rel.tagName.hasPrefix("v") ? String(rel.tagName.dropFirst()) : rel.tagName
    let title = (rel.name?.isEmpty == false) ? rel.name! : version
    return ReleaseNote(
      version: version, title: title, bodyMarkdown: rel.body ?? "", date: rel.publishedAt,
      url: rel.htmlURL)
  }
}
