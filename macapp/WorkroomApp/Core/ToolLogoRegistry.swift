import AppKit
import os

/// One curated entry (issue #141): identifies a CLI/TUI by its exec'd basename (or, for tools that
/// rewrite their own title, a literal provider title) and names the bundled `ToolLogo-<id>` imageset
/// carrying its real brand favicon. Loaded from `Resources/tool-logos/registry.json` — the SAME file
/// `Scripts/fetch-tool-logos.sh` reads to know what to fetch, so the fetch list and the match list
/// can't drift apart.
struct ToolLogoEntry: Codable, Equatable {
  let id: String
  let displayName: String
  let executables: [String]
  let titles: [String]?
  let faviconSource: String
}

/// Latched onto a running terminal tab (mirrors `AgentBackend`, but data-driven and not limited to
/// two cases). Deliberately smaller than `ToolLogoEntry` — a tab only needs to remember the match.
struct RecognizedTool: Equatable {
  let id: String
  let displayName: String
}

enum ToolLogoRegistry {
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "ToolLogoRegistry")

  static let entries: [ToolLogoEntry] = loadEntries()

  private static let byExecutable: [String: ToolLogoEntry] = {
    var map: [String: ToolLogoEntry] = [:]
    for entry in entries {
      for exe in entry.executables { map[exe] = entry }
    }
    return map
  }()

  private static let byTitle: [String: ToolLogoEntry] = {
    var map: [String: ToolLogoEntry] = [:]
    for entry in entries {
      for title in entry.titles ?? [] { map[title.lowercased()] = entry }
    }
    return map
  }()

  /// Pure data match — works even before `fetch-tool-logos.sh` has produced an imageset for the id,
  /// so it's directly unit-testable against `registry.json` content alone.
  ///
  /// Case-sensitive on purpose, mirroring `AgentTitleRecognition.backend(for:)`
  /// (`AgentUsage.swift`): a command title is the real, lower-case executable name, so comparing
  /// case-sensitively rejects prose like "Go to definition" matching the `go` entry.
  static func matchingEntry(forTitle title: String?) -> ToolLogoEntry? {
    guard let title else { return nil }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let literal = byTitle[trimmed.lowercased()] { return literal }
    guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else { return nil }
    let token = String(first).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    return byExecutable[(token as NSString).lastPathComponent]
  }

  /// Lowercased before lookup (review finding) — matching `AgentProcessRecognition.backend(forProcessName:)`'s
  /// precedent. Unlike the title-matching path above, a `proc_name`-resolved executable name is never
  /// prose, so there's no "Go to definition" style false-positive risk to guard against by staying
  /// case-sensitive here — and macOS's default case-insensitive filesystem means a real binary can
  /// genuinely be invoked with non-lowercase casing. `byExecutable`'s own keys are already all-lowercase
  /// as authored in `registry.json` (only the lookup side needed normalizing, not the map).
  static func matchingEntry(forExecutableName name: String?) -> ToolLogoEntry? {
    guard let name else { return nil }
    return byExecutable[(name as NSString).lastPathComponent.lowercased()]
  }

  /// The gate production call sites actually use: nil unless the id's real logo made it into
  /// Assets.xcassets. A `registry.json` entry can exist before the fetch script has been run for it
  /// (or a fetch failed for one tool) — this must never surface a broken/blank image.
  static func tool(forTitle title: String?) -> RecognizedTool? {
    matchingEntry(forTitle: title).flatMap(recognizedIfBundled)
  }

  static func tool(forExecutableName name: String?) -> RecognizedTool? {
    matchingEntry(forExecutableName: name).flatMap(recognizedIfBundled)
  }

  static func assetName(for id: String) -> String { "ToolLogo-\(id)" }

  private static func recognizedIfBundled(_ entry: ToolLogoEntry) -> RecognizedTool? {
    guard NSImage(named: assetName(for: entry.id)) != nil else { return nil }
    return RecognizedTool(id: entry.id, displayName: entry.displayName)
  }

  private static func loadEntries() -> [ToolLogoEntry] {
    guard
      let url = Bundle.main.url(
        forResource: "registry", withExtension: "json", subdirectory: "tool-logos")
    else {
      logger.error("tool-logos/registry.json not found in the app bundle")
      return []
    }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode([ToolLogoEntry].self, from: data)
    } catch {
      logger.error("tool-logos/registry.json failed to decode: \(error, privacy: .public)")
      return []
    }
  }
}
