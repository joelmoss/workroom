import Defaults
import Foundation

/// A release channel the user can subscribe to for Sparkle auto-updates (issue #91). Mirrors the Go
/// CLI's `internal/channel` package; the canonical classification + floor rules live there and in
/// `Scripts/channel-helper.sh` — keep all three in lockstep.
///
/// Floor / nested model: a channel receives its own builds plus every channel below it, newest
/// wins. Stable users never see prereleases.
///
///   stable  → GA only
///   pre     → betas / release candidates + stable
///   nightly → per-day builds from main + everything below
///
/// The app never classifies tags itself — Sparkle matches each appcast item's `<sparkle:channel>`
/// against `allowedSparkleChannels`. So this type only carries the subscription → allowed-channels
/// mapping plus display strings.
///
/// Stored as the bare raw string ("stable"/"pre"/"nightly") via `PreferRawRepresentable`, matching
/// the `DiffViewMode`/`PRMergeMethod` convention. The raw values are BOTH a stored-data contract and
/// the Sparkle `<sparkle:channel>` names the appcast uses — keep them byte-for-byte stable.
enum ReleaseChannel: String, CaseIterable, Sendable, Defaults.Serializable,
  Defaults.PreferRawRepresentable
{
  case stable
  case pre
  case nightly

  /// The Sparkle channels this subscription may receive updates from, EXCLUDING the default
  /// (untagged) channel that Sparkle always allows. Stable builds ship untagged, so `.stable`
  /// returns the empty set; the floor for `.pre`/`.nightly` adds the tagged channels below them.
  /// Feed straight to `SPUUpdaterDelegate.allowedChannels(for:)`.
  var allowedSparkleChannels: Set<String> {
    switch self {
    case .stable: return []
    case .pre: return [ReleaseChannel.pre.rawValue]
    case .nightly: return [ReleaseChannel.pre.rawValue, ReleaseChannel.nightly.rawValue]
    }
  }

  /// The Settings picker's option label.
  var label: String {
    switch self {
    case .stable: return "Stable"
    case .pre: return "Pre-release"
    case .nightly: return "Nightly"
    }
  }

  /// Channels the main app's Settings picker offers. Nightly is a separate side-by-side product
  /// (its own app identity / DMG), never a runtime picker option — so it's excluded here.
  static let pickerCases: [ReleaseChannel] = [.stable, .pre]

  /// This build's baked channel identity, from the Info.plist `WorkroomReleaseChannel` marker (set
  /// per build configuration in project.yml): `.nightly` for the Workroom Nightly build; nil for
  /// the main app (Release) and Dev/tests, whose marker is empty and whose channel is the runtime
  /// `Defaults[.releaseChannel]` preference.
  static var current: ReleaseChannel? {
    guard
      let raw = Bundle.main.object(forInfoDictionaryKey: "WorkroomReleaseChannel") as? String,
      !raw.isEmpty
    else { return nil }
    return ReleaseChannel(rawValue: raw)
  }

  /// Whether this is the pinned nightly build (channel fixed, no runtime picker).
  static var isNightlyBuild: Bool { current == .nightly }
}
