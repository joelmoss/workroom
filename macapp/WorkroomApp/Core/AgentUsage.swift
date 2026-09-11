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

/// How far past sustainable pace a window is, in three bands — the rule behind every quota bar's
/// fill colour. Lives here rather than in the view that draws it so the threshold below is
/// reachable by a test: it used to be a bare `> 15` inside `TerminalStatusBar.paceColor`, which no
/// test layer in this app can see.
enum PaceSeverity: Equatable, Sendable {
  case onPace
  case warning
  case critical
}

struct AgentPace: Equatable, Sendable {
  /// Percentage points ahead of sustainable use. Negative means under pace.
  let percentagePoints: Double

  var roundedPoints: Int { Int(percentagePoints.rounded()) }
  var isOver: Bool { roundedPoints > 0 }

  /// Compares `roundedPoints`, not `percentagePoints`. `isOver` already rounds, and so do the two
  /// surfaces that still print a number (the popover caption and the accessibility label), so the
  /// severity step reads the same value the user is shown — comparing the raw double would colour a
  /// pace described as "15% in deficit" as critical.
  var severity: PaceSeverity {
    guard isOver else { return .onPace }
    return roundedPoints > 15 ? .critical : .warning
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

  /// Where a quota bar's pace pin sits: the point usage would have reached if it exactly tracked
  /// the window's elapsed time. Recovered from `pace(at:)` (`usedPercentage - percentagePoints`
  /// gives back that elapsed fraction) rather than computing elapsed a second time, so the pin and
  /// the pace figure beside it can never disagree. Clamped because `usedPercentage` is clamped but
  /// the subtraction is not — a window past its reset can otherwise land outside the track.
  ///
  /// Lives here rather than in either view because BOTH bars need it: the footer segment and the
  /// popover's rows used to carry this same expression, each commenting that it avoided a second
  /// copy of the calculation.
  /// No clamp needed: `pace(at:)` already clamps its elapsed fraction to 0…100, and
  /// `used - (used - elapsed)` is `elapsed`, so the result is in range by construction. (The
  /// `duration <= 0` branch returns `usedPercentage`, which cancels to 0.)
  func sustainablePacePercentage(at now: Date) -> Double {
    usedPercentage - pace(at: now).percentagePoints
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

  /// How many of the newest rollouts one read will try, and so how many directories it asks to be
  /// watched. A malformed or partially-written newest file must not suppress a slightly older valid
  /// one; the cap is what keeps both the read and the watch set bounded on a years-deep tree.
  static let candidateLimit = 12

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

  /// A Claude cache read, carrying WHY it produced nothing so the footer can say so.
  enum ClaudeRead: Sendable {
    case snapshot(AgentQuotaSnapshot)
    case failure(String)

    var snapshot: AgentQuotaSnapshot? {
      if case .snapshot(let value) = self { return value }
      return nil
    }
  }

  static func readClaudeSnapshot(cacheURL: URL, now: Date) -> ClaudeRead {
    guard let data = try? Data(contentsOf: cacheURL),
      let modified = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[
        .modificationDate] as? Date
    else {
      return .failure(
        "Workroom hasn't received a Claude quota snapshot yet — Claude writes one each time its "
          + "status line runs.")
    }
    if let snapshot = claude(data: data, capturedAt: modified, now: now) {
      return .snapshot(snapshot)
    }
    // `isFresh` is `now < resetsAt`, so decoding again at `.distantPast` keeps every window that
    // parsed — the only thing that separates "the file is unreadable" from "its windows have all
    // reset since it was written".
    guard claude(data: data, capturedAt: modified, now: .distantPast) != nil else {
      return .failure("Claude's cached quota file couldn't be read.")
    }
    let written = modified.formatted(.relative(presentation: .named))
    return .failure(
      "Claude's cached quota (written \(written)) covers windows that have since reset.")
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

  /// What one Codex read produced: the snapshot, and where to watch for the next one.
  struct CodexRead: Sendable {
    let snapshot: AgentQuotaSnapshot?
    /// Every directory holding a rollout this read considered, plus that rollout's ancestors up to
    /// and including `sessionsRoot`.
    let watchDirectories: [URL]
  }

  /// Read the newest usable rollout, and report the directories worth watching for the next one.
  ///
  /// Both answers come out of ONE enumeration, on whatever background thread called this. The watch
  /// set used to be derived by a *second*, fully recursive walk performed on the main actor after
  /// every read (`AgentUsageMonitor.updateWatches`), which is why it's computed here now.
  ///
  /// `isCancelled` is polled between files rather than read from `Task.isCancelled`, because this
  /// runs inside `runBlocking`'s GCD closure where there is no ambient task and `Task.isCancelled`
  /// is always `false`. Without it, superseding a read only sets a flag nobody reads: the walk runs
  /// to the end anyway — one `resourceValues` stat per rollout in the tree plus up to
  /// `candidateLimit` 256KB tail reads — so at the refresh cadence this monitor actually sees (one
  /// per Claude status-line invocation) several abandoned full-tree walks pile up at once.
  static func readCodex(
    sessionsRoot: URL, now: Date, maximumTailBytes: Int = maximumTailBytes,
    fileManager: FileManager = .default, isCancelled: () -> Bool = { false }
  ) -> CodexRead {
    guard
      let enumerator = fileManager.enumerator(
        at: sessionsRoot,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return CodexRead(snapshot: nil, watchDirectories: [sessionsRoot.standardizedFileURL]) }
    var candidates: [(URL, Date)] = []
    for case let url as URL in enumerator {
      // Before the extension filter, not after: `where` runs per element ahead of the body, so a
      // poll inside a filtered loop never sees directories or non-rollout entries.
      if isCancelled() { return CodexRead(snapshot: nil, watchDirectories: []) }
      guard url.pathExtension == "jsonl" else { continue }
      guard
        let values = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .contentModificationDateKey,
        ]),
        values.isRegularFile == true
      else { continue }
      candidates.append((url, values.contentModificationDate ?? .distantPast))
    }
    // A malformed/partially-written newest rollout must not suppress a slightly older valid one.
    let newest = candidates.sorted(by: { $0.1 > $1.1 }).prefix(candidateLimit)
    let watchDirectories = watchDirectories(for: newest.map(\.0), root: sessionsRoot)
    for (url, modifiedAt) in newest {
      if isCancelled() { return CodexRead(snapshot: nil, watchDirectories: []) }
      guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
      defer { try? handle.close() }
      let size = (try? handle.seekToEnd()) ?? 0
      let count = min(UInt64(maximumTailBytes), size)
      try? handle.seek(toOffset: size - count)
      guard let data = try? handle.read(upToCount: Int(count)), !data.isEmpty else { continue }
      if let snapshot = codexRollout(
        data: data, fileSize: size, modifiedAt: modifiedAt, now: now)
      {
        return CodexRead(snapshot: snapshot, watchDirectories: watchDirectories)
      }
    }
    return CodexRead(snapshot: nil, watchDirectories: watchDirectories)
  }

  /// The rollouts' own directories plus every ancestor up to `root`, deduped, `root` always first.
  ///
  /// The ancestor chain is load-bearing. A rollout lands in `sessions/YYYY/MM/DD`, a directory that
  /// does not exist until that day arrives, so nothing can watch it in advance — but whichever
  /// level has to *create* it is itself watched, and because the chain always reaches the root, a
  /// gap of any length (a new day, a new month, a first-ever session) still fires one event, which
  /// brings both the snapshot and this set up to date. Watching every directory in the tree instead
  /// (what this replaced) buys nothing: Codex only ever appends to the newest ones.
  private static func watchDirectories(
    for rollouts: [URL], root: URL, fileManager: FileManager = .default
  ) -> [URL] {
    let rootPath = root.standardizedFileURL.path
    var ordered: [URL] = []
    var seen = Set<String>()
    func add(_ url: URL) {
      guard seen.insert(url.path).inserted else { return }
      ordered.append(url)
    }

    add(root.standardizedFileURL)
    for rollout in rollouts {
      var directory = rollout.standardizedFileURL.deletingLastPathComponent()
      while directory.path.hasPrefix(rootPath + "/") {
        add(directory)
        directory = directory.deletingLastPathComponent()
      }
    }
    for directory in newestChain(from: root.standardizedFileURL, fileManager: fileManager) {
      add(directory)
    }
    return ordered
  }

  /// Walk down from `root` taking the highest-sorting subdirectory at each level.
  ///
  /// The ancestor chains above only cover directories that ALREADY hold a rollout, which leaves a
  /// real gap: `sessions/YYYY/MM/DD` exists from the moment Codex creates it, but until it holds a
  /// file this read has no reason to name it, and a directory watch is not recursive — so the first
  /// rollout written into it notifies nobody and the quota sits stale until something else fires.
  /// Reproduced against the previous full-tree walk, which did catch it. Following the newest
  /// subdirectory down finds that directory without knowing the layout or the local date (a
  /// date-derived guess gets the timezone wrong at midnight; sort order does not), and without the
  /// walk this replaced: `maximumChainDepth` levels, one listing each, whatever the history's size.
  private static let maximumChainDepth = 4

  private static func newestChain(from root: URL, fileManager: FileManager) -> [URL] {
    var chain: [URL] = []
    var directory = root
    for _ in 0..<maximumChainDepth {
      guard
        let children = try? fileManager.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { break }
      let subdirectories = children.filter {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      }
      guard let newest = subdirectories.max(by: { $0.lastPathComponent < $1.lastPathComponent })
      else { break }
      directory = newest.standardizedFileURL
      chain.append(directory)
    }
    return chain
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

  /// Parsed with two cached `ISO8601FormatStyle`s, fractional seconds first.
  ///
  /// This used to allocate one or two `ISO8601DateFormatter`s per call, and each allocation builds
  /// an ICU date formatter: ~0.2 ms, against ~0.005 ms for the parse itself. A rollout tail holds
  /// ~1000 `token_count` records and the scan above walks them until one has an unexpired window,
  /// so a tail of stale records cost ~180 ms per file and up to `candidateLimit`× that per refresh —
  /// measured at 2.2 s, and an app-hang report sampled the main-thread stall with this very
  /// allocation running. `ISO8601FormatStyle` is a `Sendable` value type parsed in Swift: no
  /// formatter, no allocation, and the same instants back (it keeps sub-millisecond digits the
  /// formatter truncated).
  private static let iso8601Fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let iso8601 = Date.ISO8601FormatStyle()

  private static func parseISO8601(_ value: String) -> Date? {
    (try? iso8601Fractional.parse(value)) ?? (try? iso8601.parse(value))
  }
}

/// One read's "give up" switch, readable from the GCD thread the read runs on.
///
/// `Task.isCancelled` cannot do this job here: the read executes inside `runBlocking`'s
/// `DispatchQueue.global` closure, which carries no task context, so that flag reads `false` no
/// matter what the owning task does.
private final class ReadCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func isCancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

@MainActor
final class AgentUsageMonitor: ObservableObject {
  @Published private(set) var snapshots: [AgentBackend: AgentQuotaSnapshot] = [:]
  @Published private(set) var loading: Set<AgentBackend> = []
  /// Why the last read produced no snapshot, per backend. Surfaced by the footer so an unavailable
  /// quota says what's missing instead of being a dead end.
  @Published private(set) var readFailures: [AgentBackend: String] = [:]

  let codexSessionsURL: URL
  let claudeCacheURL: URL
  private let now: () -> Date
  private var refreshTask: Task<Void, Never>?
  private var watches: [DispatchSourceFileSystemObject] = []
  /// Paths that actually got a descriptor in the last `updateWatches` — a record of what IS
  /// watched, never a cache consulted to skip work. Assigned only from successful `open()` calls so
  /// it cannot claim coverage that does not exist.
  private(set) var watchedDirectoryPaths: Set<String> = []
  /// Reads that reached `apply`. Not `@Published` — it exists so a test can wait for a read to land
  /// rather than for a published value to change, which is precisely what a read that correctly
  /// publishes nothing never does.
  private(set) var completedReadCount = 0
  /// Cancels the in-flight read. Not `Task.isCancelled`: the read runs in `runBlocking`'s GCD
  /// closure, outside any task, where that flag is always `false`.
  private var activeRead: ReadCancellation?
  private var debounce: DispatchWorkItem?
  private static let initialWatchRetryDelay: TimeInterval = 1
  private static let maximumWatchRetryDelay: TimeInterval = 60
  private var watchRetry: DispatchWorkItem?
  private var watchRetryDelay: TimeInterval = initialWatchRetryDelay

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
    // No `installWatches()` here: the first read reports which directories to watch (it enumerates
    // the tree anyway, off the main thread), so the watches come up with its result rather than
    // costing a second recursive walk during window setup.
    if startAutomatically { refresh() }
  }

  deinit {
    refreshTask?.cancel()
    activeRead?.cancel()
    debounce?.cancel()
    watchRetry?.cancel()
    for watch in watches { watch.cancel() }
  }

  func snapshot(for backend: AgentBackend) -> AgentQuotaSnapshot? {
    snapshots[backend]?.fresh(at: now())
  }

  /// One sentence explaining an empty `snapshot(for:)`, evaluated at READ time — a stored snapshot
  /// expires wherever it sits, with no refresh running to record why, so expiry can only be caught
  /// here.
  func unavailableReason(for backend: AgentBackend) -> String {
    let name = backend.displayName
    if let stored = snapshots[backend], stored.fresh(at: now()) == nil {
      let captured = stored.capturedAt.formatted(.relative(presentation: .named))
      return "The last \(name) quota snapshot (\(captured)) covers windows that have since reset."
    }
    return readFailures[backend] ?? "No \(name) quota snapshot has been read yet."
  }

  /// Re-read both backends.
  ///
  /// `userInitiated` is the difference between a read the user asked for and the many that arrive on
  /// their own. It decides only whether a backend that has ALREADY failed gets a spinner: an
  /// automatic read must not flag one (see `pendingBackends`), but the footer's retry button and the
  /// Settings toggle must, or a click on "usage unavailable" produces no visible response at all.
  func refresh(userInitiated: Bool = false) {
    // A seeded agent title is a model-only UI fixture. Never replace its deterministic snapshot
    // (including the intentional unavailable case) by reading the developer's real provider files.
    guard UITestFixture.usageAgentTitle == nil else {
      loading.removeAll()
      return
    }
    refreshTask?.cancel()
    activeRead?.cancel()
    let cancellation = ReadCancellation()
    activeRead = cancellation
    // An AUTOMATIC read may only ADD to `loading`, never shrink it. A watch event landing while a
    // user-initiated retry is still in flight would otherwise recompute `pending` from the
    // not-yet-cleared `readFailures`, drop that backend, and take the spinner away from the click
    // that asked for it — the exact response `userInitiated` exists to guarantee. `apply` stays the
    // only place that clears. Unioning with an empty set is a no-op, so the `[] -> [x] -> []` flip
    // this parameter was added to kill does not come back.
    let pending = pendingBackends(userInitiated: userInitiated)
    let next = userInitiated ? pending : loading.union(pending)
    if loading != next { loading = next }
    let codexURL = codexSessionsURL
    let claudeURL = claudeCacheURL
    let current = now()
    // `Task`, not `Task.detached`: this type is `@MainActor`, so the body resumes here and `apply`
    // needs no second hop. `[weak self]` because a detached task holding `self` strongly made
    // `deinit` — and therefore the watch teardown in it — unreachable for the life of a read.
    refreshTask = Task { [weak self] in
      // `runBlocking` (GCD), not the Swift cooperative pool: both reads block their thread for the
      // whole call, and the pool is only as wide as the core count. That is the "History pane loads
      // forever" starvation this repo already fixed once; see `Timeout.swift`.
      let read = try? await runBlocking(qos: .utility) {
        (
          codex: AgentUsageDecoding.readCodex(
            sessionsRoot: codexURL, now: current, isCancelled: cancellation.isCancelled),
          claude: AgentUsageDecoding.readClaudeSnapshot(cacheURL: claudeURL, now: current)
        )
      }
      guard let self, let read, !cancellation.isCancelled(), !Task.isCancelled else { return }
      var failures: [AgentBackend: String] = [:]
      if read.codex.snapshot == nil {
        failures[.codex] =
          "No recent Codex rate-limit record in \(codexURL.path(percentEncoded: false))."
      }
      if case .failure(let reason) = read.claude { failures[.claude] = reason }
      self.apply(
        snapshots: [read.codex.snapshot, read.claude.snapshot].compactMap { $0 },
        failures: failures, codexDirectories: read.codex.watchDirectories)
    }
  }

  /// Which backends may show a spinner.
  ///
  /// Only a backend with nothing on screen can: `TerminalStatusBar` reads `loading` solely in its
  /// no-snapshot branch, and only for the ONE active agent's backend. A backend that has already
  /// recorded a `readFailures` reason is excluded too, because it is not loading — it is settled and
  /// unavailable, and it never resolves for a user who runs only the other agent. Without that
  /// exclusion `loading` flips `[] -> [backend] -> []` on every automatic read forever, which is two
  /// whole view-graph passes per read (the status bar's `ViewThatFits` instantiates every child to
  /// measure it) for a spinner nothing renders — and automatic reads are frequent: every watched
  /// directory event schedules one, and the Claude bridge's status line rewrites its cache file (a
  /// create + rename in a watched directory) on every single invocation.
  private func pendingBackends(userInitiated: Bool) -> Set<AgentBackend> {
    Set(
      AgentBackend.allCases.filter {
        snapshot(for: $0) == nil && (userInitiated || readFailures[$0] == nil)
      })
  }

  /// Publish only what actually changed.
  ///
  /// Every `@Published` write invalidates every view observing this object, and the status bar's
  /// `ViewThatFits` instantiates all of its children to measure them — so the common read (one
  /// rollout line appended, same percentages) has to be silent.
  private func apply(
    snapshots read: [AgentQuotaSnapshot], failures: [AgentBackend: String],
    codexDirectories: [URL]
  ) {
    completedReadCount += 1
    let keyed = Dictionary(uniqueKeysWithValues: read.map { ($0.backend, $0) })
    if !Self.displaysSame(snapshots, keyed) { snapshots = keyed }
    if readFailures != failures { readFailures = failures }
    if !loading.isEmpty { loading.removeAll() }
    updateWatches(codexDirectories: codexDirectories)
  }

  /// Would these two read the same on screen? `capturedAt` is deliberately excluded.
  ///
  /// `AgentQuotaSnapshot`'s synthesized `==` includes it, and Claude's `capturedAt` is the cache
  /// file's mtime — which the bridge's status-line wrapper freshens on EVERY invocation by `mv -f`
  /// of a rebuilt temp file, whether or not a single percentage moved. Comparing on it therefore
  /// made the guard above fire on every read for the most frequent trigger there is, which is the
  /// one thing this method exists to prevent. Nothing displays `capturedAt`; it reaches the user
  /// only through `unavailableReason`'s relative phrase for an EXPIRED snapshot, and holding the
  /// instant the numbers last actually changed is the more truthful answer there anyway.
  private static func displaysSame(
    _ lhs: [AgentBackend: AgentQuotaSnapshot], _ rhs: [AgentBackend: AgentQuotaSnapshot]
  ) -> Bool {
    lhs.count == rhs.count
      && lhs.allSatisfy { backend, snapshot in rhs[backend]?.windows == snapshot.windows }
  }

  /// Install the file-system watches, rebuilding unconditionally.
  ///
  /// Main-actor work, because the sources deliver to `.main` and are owned here — so it has to stay
  /// O(watched set). It used to re-walk the entire sessions tree and reopen one descriptor per
  /// directory found, on every read — 43 ms and 699 descriptors for two years of sessions, and a
  /// read follows every watched directory event — plus once more during window setup, synchronously,
  /// with a cold page cache. The set now arrives from the read's own enumeration
  /// (`AgentUsageDecoding.watchDirectories`) and is a handful of directories, so reopening it every
  /// time costs a few syscalls.
  ///
  /// There is deliberately NO "skip if the paths are unchanged" fast path. A vnode source watches an
  /// INODE, not a name, so path-string equality is not evidence the descriptors are still live:
  /// deleting a watched directory and recreating it at the same path leaves the descriptor bound to
  /// the unlinked inode — measured, a file created in the replacement fires nothing — and a
  /// per-directory `open()` failure (EACCES, or the window between the existence check and the open)
  /// leaves that one directory uncovered. Memoizing makes either permanent, because these watches
  /// are the monitor's ONLY automatic refresh trigger.
  ///
  /// Rebuilding does NOT rescue the process-wide case: if the descriptor limit is reached, every
  /// `open()` in the loop fails together, no watch survives to deliver the event that would call
  /// this again, and nothing here retries. Note also that cancelling a source closes its descriptor
  /// asynchronously, on this same queue — so the old ones are still held while the replacements
  /// open, and the peak is twice the watched set. That bound is what keeps this affordable; it is
  /// also why the replacements are guaranteed fresh descriptor numbers rather than reusing the ones
  /// being closed.
  private func updateWatches(codexDirectories: [URL]) {
    var wanted: [URL] = []
    var seen = Set<String>()
    for url in codexDirectories + [claudeCacheURL.deletingLastPathComponent()] {
      guard let existing = Self.nearestExisting(url), seen.insert(existing.path).inserted else {
        continue
      }
      wanted.append(existing)
    }
    for watch in watches { watch.cancel() }
    watches.removeAll()
    watchedDirectoryPaths.removeAll()
    for url in wanted {
      let descriptor = open(url.path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      watchedDirectoryPaths.insert(url.path)
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .rename, .delete],
        queue: .main)
      source.setEventHandler { [weak self] in self?.scheduleRefresh() }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      watches.append(source)
    }
    noteWatchShortfall(installed: watchedDirectoryPaths.count, wanted: wanted.count)
  }

  /// The path itself if it exists, else the closest parent that does, at most two levels up.
  ///
  /// Dropping a missing directory outright is a dead end, because these watches are the only
  /// automatic refresh trigger: `~/.codex/sessions` deleted and recreated would never be noticed
  /// again, and the Claude bridge's directory does not exist at all until the bridge is enabled, so
  /// enabling it fired nothing. Two levels is the cap because one more reaches shared ground like
  /// `~/Library/Application Support`, where every unrelated app's writes would drive a refresh.
  private static func nearestExisting(_ url: URL) -> URL? {
    var candidate = url.standardizedFileURL
    for _ in 0...2 {
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      let parent = candidate.deletingLastPathComponent()
      guard parent.path != candidate.path else { return nil }
      candidate = parent
    }
    return nil
  }

  /// Re-read on a backoff when fewer directories got a descriptor than were asked for.
  ///
  /// Nothing else would: a failed `open()` costs the event that would have called this again, and
  /// with no watches left there is no trigger at all — the quota bar simply stops updating for the
  /// rest of the session. The descriptor limit is the case that takes them all at once (it is
  /// process-wide, so every `open()` in the loop fails together), and it is also the one that
  /// clears on its own once whatever exhausted the table lets go, which is exactly what a backoff
  /// retry is for. Resets on the first fully-installed read, so a healthy app never schedules one.
  private func noteWatchShortfall(installed: Int, wanted: Int) {
    watchRetry?.cancel()
    watchRetry = nil
    guard installed < wanted else {
      watchRetryDelay = Self.initialWatchRetryDelay
      return
    }
    let delay = watchRetryDelay
    watchRetryDelay = min(delay * 2, Self.maximumWatchRetryDelay)
    let item = DispatchWorkItem { [weak self] in self?.refresh() }
    watchRetry = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func scheduleRefresh() {
    debounce?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.refresh() }
    debounce = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
  }
}
