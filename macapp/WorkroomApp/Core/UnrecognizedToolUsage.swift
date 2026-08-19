import Foundation
import os

/// Local-only usage counter for foreground commands that AREN'T in the curated `ToolLogoRegistry`
/// (issue #141 follow-up): every distinct executable seen running that isn't a known registry id
/// gets tallied, so a periodic look at this file shows which non-curated tools are actually run
/// often enough to be worth fetching a favicon for. Nothing here leaves the machine — it's a plain
/// JSON dictionary the developer inspects by hand (e.g. `jq -r 'to_entries|sort_by(-.value)|.[]'`).
enum UnrecognizedToolUsage {
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "UnrecognizedToolUsage")

  /// Where the file lives, scoped by bundle id — same convention as `SessionStore.defaultURL`, so
  /// Workroom/Workroom Dev/Workroom Nightly never mix each other's usage data (a Dev-build test run
  /// shouldn't pollute what the real, daily-driver build actually sees used).
  static func defaultURL(
    bundleID: String? = Bundle.main.bundleIdentifier,
    fileManager: FileManager = .default
  ) -> URL {
    // A missing bundle id should never fall back to the real production identifier — that would
    // silently redirect an oddly-configured process into the shipped app's own usage file instead
    // of an obviously-scoped one (review finding).
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Workroom", isDirectory: true)
      .appendingPathComponent(bundleID ?? "unknown-bundle", isDirectory: true)
      .appendingPathComponent("unrecognized-tool-usage.json")
  }

  /// Increments the on-disk count for `name` (an executable basename). Callers should keep this off
  /// the main thread — production's only caller (`TerminalSessions.recordUnrecognizedTool`) already
  /// dispatches to a background queue, since `updateTitle` itself runs on the main thread.
  static func recordUnrecognized(_ name: String, url: URL = defaultURL()) {
    var counts = load(url: url)
    counts[name, default: 0] += 1
    save(counts, url: url)
  }

  private static func load(url: URL) -> [String: Int] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    guard let data = try? Data(contentsOf: url) else {
      logger.error("unrecognized-tool-usage.json exists but is unreadable")
      return [:]
    }
    guard let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
      // Distinct from "file doesn't exist yet" (the common, expected first-run case above) — this
      // is real data loss: a corrupt or foreign-schema file about to be silently overwritten by the
      // next write (review finding). Nothing to recover here (there's no schema version to branch
      // on, unlike SessionStore's newer-build case), but at least the loss is visible in Console.app.
      logger.error("unrecognized-tool-usage.json exists but failed to decode — resetting counts")
      return [:]
    }
    return decoded
  }

  private static func save(_ counts: [String: Int], url: URL) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(counts).write(to: url, options: .atomic)
    } catch {
      logger.error("failed to persist unrecognized-tool-usage.json: \(error, privacy: .public)")
    }
  }
}
