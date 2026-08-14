import Darwin
import Foundation

enum AgentQuotaWindowKind: Equatable, Sendable {
  case fiveHour
  case weekly
  case duration(minutes: Int)

  var compactLabel: String {
    switch self {
    case .fiveHour: return "5h"
    case .weekly: return "wk"
    case .duration(let minutes):
      if minutes.isMultiple(of: 1440) { return "\(minutes / 1440)d" }
      if minutes.isMultiple(of: 60) { return "\(minutes / 60)h" }
      return "\(minutes)m"
    }
  }
}

struct AgentPace: Equatable, Sendable {
  /// Percentage points ahead of sustainable use. Negative means under pace.
  let percentagePoints: Double

  var roundedPoints: Int { Int(percentagePoints.rounded()) }
  var isOver: Bool { roundedPoints > 0 }

  var compactDescription: String {
    if roundedPoints == 0 { return "0%" }
    return "\(roundedPoints > 0 ? "+" : "−")\(abs(roundedPoints))%"
  }

  var accessibilityDescription: String {
    if roundedPoints == 0 { return "on sustainable pace" }
    if roundedPoints > 0 { return "\(roundedPoints)% in deficit" }
    return "\(abs(roundedPoints))% in reserve"
  }
}

struct AgentQuotaWindow: Equatable, Sendable, Identifiable {
  let kind: AgentQuotaWindowKind
  let usedPercentage: Double
  let duration: TimeInterval
  let resetsAt: Date

  var id: String { kind.compactLabel }

  init(
    kind: AgentQuotaWindowKind, usedPercentage: Double, duration: TimeInterval, resetsAt: Date
  ) {
    self.kind = kind
    self.usedPercentage = min(max(usedPercentage, 0), 100)
    self.duration = duration
    self.resetsAt = resetsAt
  }

  func pace(at now: Date) -> AgentPace {
    guard duration > 0 else { return AgentPace(percentagePoints: usedPercentage) }
    let startsAt = resetsAt.addingTimeInterval(-duration)
    let elapsed = min(max(now.timeIntervalSince(startsAt) / duration, 0), 1) * 100
    return AgentPace(percentagePoints: usedPercentage - elapsed)
  }

  func isFresh(at now: Date) -> Bool { now < resetsAt }

  func resetDescription(at now: Date) -> String {
    let remaining = resetsAt.timeIntervalSince(now)
    guard remaining > 0 else { return "resets now" }

    // Round up so a still-fresh window never claims to reset in 0m. The footer deliberately stops at
    // minutes: second-level precision adds noise and suggests more certainty than provider snapshots
    // offer.
    var minutes = Int(ceil(remaining / 60))
    let days = minutes / (24 * 60)
    minutes %= 24 * 60
    let hours = minutes / 60
    minutes %= 60

    // Capped at two units — "1d 3h", never "1d 3h 10m" — the third unit adds noise without adding
    // anything actionable.
    var parts: [String] = []
    if days > 0 { parts.append("\(days)d") }
    if hours > 0 { parts.append("\(hours)h") }
    if minutes > 0 { parts.append("\(minutes)m") }
    return "resets in " + parts.prefix(2).joined(separator: " ")
  }
}

struct AgentQuotaSnapshot: Equatable, Sendable {
  let backend: AgentBackend
  let windows: [AgentQuotaWindow]
  let capturedAt: Date

  func fresh(at now: Date) -> AgentQuotaSnapshot? {
    let freshWindows = windows.filter { $0.isFresh(at: now) }
    guard !freshWindows.isEmpty else { return nil }
    return AgentQuotaSnapshot(backend: backend, windows: freshWindows, capturedAt: capturedAt)
  }
}

enum AgentTitleRecognition {
  /// Shell integration reports either the actual command line or the provider's own stable title.
  /// Only the first executable token is considered; wrappers and prose containing an agent name are
  /// deliberately rejected.
  static func backend(for title: String?) -> AgentBackend? {
    guard let title else { return nil }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    switch trimmed.lowercased() {
    case "claude code": return .claude
    case "codex": return .codex
    default: break
    }

    guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else { return nil }
    let token = String(first).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    // Provider-owned display titles are handled exactly above. Command titles come from the shell
    // and use the real, lower-case executable name; keeping this comparison case-sensitive avoids
    // treating prose such as "Claude Code setup" as a running agent.
    let executable = (token as NSString).lastPathComponent
    switch executable {
    case "claude": return .claude
    case "codex": return .codex
    default: return nil
    }
  }
}

enum AgentProcessRecognition {
  static func backend(forProcessName name: String?) -> AgentBackend? {
    guard let name else { return nil }
    switch (name as NSString).lastPathComponent.lowercased() {
    case "claude": return .claude
    case "codex": return .codex
    default: return nil
    }
  }

  static func backend(forPID pid: pid_t) -> AgentBackend? {
    guard pid > 1 else { return nil }
    var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
    return backend(forProcessName: String(cString: name))
  }
}

enum AgentUsageDecoding {
  static let maximumTailBytes = 256 * 1024

  static func claude(data: Data, capturedAt: Date, now: Date) -> AgentQuotaSnapshot? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let limits = (root["rate_limits"] as? [String: Any]) ?? root
    var windows: [AgentQuotaWindow] = []
    if let value = decodeClaudeWindow(
      limits["five_hour"], kind: .fiveHour, duration: 5 * 60 * 60)
    {
      windows.append(value)
    }
    if let value = decodeClaudeWindow(
      limits["seven_day"], kind: .weekly, duration: 7 * 24 * 60 * 60)
    {
      windows.append(value)
    }
    return normalized(.claude, windows: windows, capturedAt: capturedAt, now: now)
  }

  static func codexRollout(data: Data, fileSize: UInt64, modifiedAt: Date, now: Date)
    -> AgentQuotaSnapshot?
  {
    var bytes = data
    // A bounded tail can begin halfway through a JSONL record. Drop that fragment.
    if fileSize > UInt64(data.count), let newline = bytes.firstIndex(of: 0x0A) {
      bytes.removeSubrange(...newline)
    }
    for rawLine in bytes.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
        let payload = object["payload"] as? [String: Any],
        payload["type"] as? String == "token_count",
        let limits = payload["rate_limits"] as? [String: Any]
      else { continue }

      let capturedAt = (object["timestamp"] as? String).flatMap(parseISO8601) ?? modifiedAt
      var windows: [AgentQuotaWindow] = []
      for key in ["primary", "secondary"] {
        guard let value = limits[key] as? [String: Any],
          let minutes = number(value["window_minutes"]).map(Int.init), minutes > 0,
          let used = number(value["used_percent"])
        else { continue }
        let reset: Date?
        if let seconds = number(value["resets_at"]) {
          reset = Date(timeIntervalSince1970: seconds)
        } else if let remaining = number(value["resets_in_seconds"]) {
          reset = capturedAt.addingTimeInterval(remaining)
        } else {
          reset = nil
        }
        guard let reset else { continue }
        windows.append(
          AgentQuotaWindow(
            kind: kind(for: minutes), usedPercentage: used,
            duration: TimeInterval(minutes * 60), resetsAt: reset))
      }
      if let snapshot = normalized(.codex, windows: windows, capturedAt: capturedAt, now: now) {
        return snapshot
      }
    }
    return nil
  }

  static func readCodexSnapshot(
    sessionsRoot: URL, now: Date, maximumTailBytes: Int = maximumTailBytes,
    fileManager: FileManager = .default
  ) -> AgentQuotaSnapshot? {
    guard
      let enumerator = fileManager.enumerator(
        at: sessionsRoot,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return nil }
    var candidates: [(URL, Date)] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .contentModificationDateKey,
        ]),
        values.isRegularFile == true
      else { continue }
      candidates.append((url, values.contentModificationDate ?? .distantPast))
    }
    // A malformed/partially-written newest rollout must not suppress a slightly older valid one.
    for (url, modifiedAt) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(12) {
      guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
      defer { try? handle.close() }
      let size = (try? handle.seekToEnd()) ?? 0
      let count = min(UInt64(maximumTailBytes), size)
      try? handle.seek(toOffset: size - count)
      guard let data = try? handle.read(upToCount: Int(count)), !data.isEmpty else { continue }
      if let snapshot = codexRollout(
        data: data, fileSize: size, modifiedAt: modifiedAt, now: now)
      {
        return snapshot
      }
    }
    return nil
  }

  private static func decodeClaudeWindow(
    _ raw: Any?, kind: AgentQuotaWindowKind, duration: TimeInterval
  ) -> AgentQuotaWindow? {
    guard let value = raw as? [String: Any],
      let used = number(value["used_percentage"]),
      let reset = number(value["resets_at"])
    else { return nil }
    return AgentQuotaWindow(
      kind: kind, usedPercentage: used, duration: duration,
      resetsAt: Date(timeIntervalSince1970: reset))
  }

  private static func normalized(
    _ backend: AgentBackend, windows: [AgentQuotaWindow], capturedAt: Date, now: Date
  ) -> AgentQuotaSnapshot? {
    let fresh = windows.filter { $0.isFresh(at: now) }.sorted { $0.duration < $1.duration }
    guard !fresh.isEmpty else { return nil }
    return AgentQuotaSnapshot(backend: backend, windows: fresh, capturedAt: capturedAt)
  }

  private static func kind(for minutes: Int) -> AgentQuotaWindowKind {
    switch minutes {
    case 300: return .fiveHour
    case 10080: return .weekly
    default: return .duration(minutes: minutes)
    }
  }

  private static func number(_ value: Any?) -> Double? {
    switch value {
    case let value as NSNumber: return value.doubleValue
    case let value as String: return Double(value)
    default: return nil
    }
  }

  private static func parseISO8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

@MainActor
final class AgentUsageMonitor: ObservableObject {
  @Published private(set) var snapshots: [AgentBackend: AgentQuotaSnapshot] = [:]
  @Published private(set) var loading: Set<AgentBackend> = []

  let codexSessionsURL: URL
  let claudeCacheURL: URL
  private let now: () -> Date
  private var refreshTask: Task<Void, Never>?
  private var watches: [DispatchSourceFileSystemObject] = []
  private var debounce: DispatchWorkItem?

  init(
    codexSessionsURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/sessions", isDirectory: true),
    claudeCacheURL: URL = ClaudeUsageBridge.defaultDirectory
      .appendingPathComponent("claude-rate-limits.json"),
    now: @escaping () -> Date = Date.init, startAutomatically: Bool = true
  ) {
    self.codexSessionsURL = codexSessionsURL
    self.claudeCacheURL = claudeCacheURL
    self.now = now
    if let fixture = UITestFixture.usageSnapshot {
      snapshots[fixture.backend] = fixture
      return
    }
    if UITestFixture.usageAgentTitle != nil { return }
    if startAutomatically {
      refresh()
      installWatches()
    }
  }

  deinit {
    refreshTask?.cancel()
    debounce?.cancel()
    for watch in watches { watch.cancel() }
  }

  func snapshot(for backend: AgentBackend) -> AgentQuotaSnapshot? {
    snapshots[backend]?.fresh(at: now())
  }

  func refresh() {
    // A seeded agent title is a model-only UI fixture. Never replace its deterministic snapshot
    // (including the intentional unavailable case) by reading the developer's real provider files.
    guard UITestFixture.usageAgentTitle == nil else {
      loading.removeAll()
      return
    }
    refreshTask?.cancel()
    loading = Set(AgentBackend.allCases)
    let codexURL = codexSessionsURL
    let claudeURL = claudeCacheURL
    let current = now()
    refreshTask = Task.detached(priority: .utility) {
      let codex = AgentUsageDecoding.readCodexSnapshot(sessionsRoot: codexURL, now: current)
      let claude: AgentQuotaSnapshot? = {
        guard let data = try? Data(contentsOf: claudeURL),
          let attrs = try? FileManager.default.attributesOfItem(atPath: claudeURL.path),
          let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return AgentUsageDecoding.claude(data: data, capturedAt: modified, now: current)
      }()
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self.snapshots = Dictionary(
          uniqueKeysWithValues: [codex, claude].compactMap { $0 }.map { ($0.backend, $0) })
        self.loading.removeAll()
        self.rebuildWatches()
      }
    }
  }

  private func installWatches() { rebuildWatches() }

  private func rebuildWatches() {
    for watch in watches { watch.cancel() }
    watches.removeAll()
    var paths = [codexSessionsURL, claudeCacheURL.deletingLastPathComponent()]
    if let enumerator = FileManager.default.enumerator(
      at: codexSessionsURL, includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants])
    {
      for case let url as URL in enumerator {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          paths.append(url)
        }
      }
    }
    for url in paths where FileManager.default.fileExists(atPath: url.path) {
      let descriptor = open(url.path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .rename, .delete],
        queue: .main)
      source.setEventHandler { [weak self] in self?.scheduleRefresh() }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      watches.append(source)
    }
  }

  private func scheduleRefresh() {
    debounce?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.refresh() }
    debounce = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
  }
}
