import Foundation

/// The running app's marketing version (`CFBundleShortVersionString`, e.g. "1.2.3" or
/// "2.0.0-beta.1"), plus a SemVer 2.0.0–correct comparison (`SemanticVersion`).
///
/// Feature 2's "What's New" dialog filters GitHub releases by this version, so prerelease ordering
/// has to be right: this repo ships betas (`.goreleaser.yml` `prerelease: auto`), and a naive
/// numeric-string compare sorts `2.0.0-beta.1` *after* `2.0.0` — which would suppress the dialog on a
/// beta→stable upgrade, exactly for the users most likely to read release notes. An unparseable
/// string is surfaced as `nil` so callers skip the dialog rather than crash.
enum AppVersion {
  /// The running app's short version, or nil if the bundle has no / a blank
  /// `CFBundleShortVersionString` (callers then skip the What's-New flow).
  static var current: String? {
    let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty == false) ? trimmed : nil
  }
}

/// A parsed SemVer 2.0.0 version: a numeric `core` (`[major, minor, patch]`) plus optional
/// dot-separated `prerelease` identifiers. Build metadata (`+…`) is parsed off and ignored for
/// ordering (SemVer §10). `Comparable` implements the precedence rules of SemVer §11 — including
/// "a release outranks any prerelease of the same core" and the numeric-vs-alphanumeric identifier
/// rules of §11.4.
struct SemanticVersion: Comparable {
  /// `[major, minor, patch]`. A missing component (e.g. "1.2") is normalised to 0.
  let core: [Int]
  /// Dot-separated prerelease identifiers, or empty for a normal release. An empty set sorts ABOVE
  /// any non-empty set of the same core.
  let prerelease: [String]

  /// Parse "1.2.3", "v1.2", "2.0.0-beta.1", or "1.0.0-rc.2+build5". Tolerates a leading "v"/"V" and
  /// surrounding whitespace. Returns nil if the core contains a non-numeric / negative component or
  /// the prerelease segment is empty (a trailing "-").
  init?(_ string: String) {
    var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
    guard !s.isEmpty else { return nil }

    // Strip build metadata (ignored for ordering), then split off the prerelease, then the core.
    let noBuild = s.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let coreAndPre = noBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)

    let coreParts = coreAndPre[0].split(separator: ".", omittingEmptySubsequences: false)
    guard !coreParts.isEmpty else { return nil }
    var nums: [Int] = []
    for part in coreParts {
      guard let n = Int(part), n >= 0 else { return nil }
      nums.append(n)
    }
    while nums.count < 3 { nums.append(0) }
    core = nums

    if coreAndPre.count == 2 {
      let pre = coreAndPre[1]
      guard !pre.isEmpty else { return nil }
      prerelease = pre.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    } else {
      prerelease = []
    }
  }

  static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    // Numeric core, padded so [1,2] and [1,2,0] compare equal.
    let count = max(lhs.core.count, rhs.core.count)
    for i in 0..<count {
      let l = i < lhs.core.count ? lhs.core[i] : 0
      let r = i < rhs.core.count ? rhs.core[i] : 0
      if l != r { return l < r }
    }
    // Cores equal: a release (no prerelease) has higher precedence than any prerelease (§11.3).
    switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
    case (true, true): return false  // equal precedence
    case (true, false): return false  // lhs release > rhs prerelease
    case (false, true): return true  // lhs prerelease < rhs release
    case (false, false): return comparePrerelease(lhs.prerelease, rhs.prerelease)
    }
  }

  static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    !(lhs < rhs) && !(rhs < lhs)
  }

  /// SemVer §11.4: compare identifiers field by field — numeric identifiers compare numerically and
  /// rank below alphanumeric ones; if all shared fields tie, the longer identifier set wins.
  private static func comparePrerelease(_ a: [String], _ b: [String]) -> Bool {
    for (x, y) in zip(a, b) where x != y {
      switch (Int(x), Int(y)) {
      case (.some(let xi), .some(let yi)): return xi < yi  // both numeric
      case (.some, .none): return true  // numeric < alphanumeric
      case (.none, .some): return false
      case (.none, .none): return x < y  // ASCII order
      }
    }
    return a.count < b.count
  }
}
