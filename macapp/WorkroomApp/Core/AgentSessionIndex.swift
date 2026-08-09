import Foundation
import OSLog

/// Which agent CLIs have a resumable conversation for a given directory (issue #145).
///
/// libghostty exposes no child pid and no pty fd (`ghostty.h` carries only
/// `ghostty_surface_message_childexited_s`), so the app **cannot** know what was running in a pane.
/// The only answerable question is the weaker one: *does this directory have agent history from
/// around the time we quit?* That is a filesystem read of each agent's own session store.
///
/// **Matching is exact, never guessed.** Both stores record the working directory inside the session
/// file, so a candidate is confirmed by reading it:
///
/// - **Claude** — `~/.claude/projects/<slug>/<uuid>.jsonl`. Line 1 is a `{leafUuid, sessionId, type}`
///   summary with no `cwd`; the `user` / `assistant` / `attachment` records that follow each carry
///   one, so extraction scans forward to the first record that has it.
/// - **Codex** — `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, whose first line is a
///   `session_meta` record with `payload.cwd`.
///
/// The slug is a **candidate-directory hint only** — it saves listing 58 project directories to find
/// the one that matters, and nothing rests on it being right. That distinction is load-bearing:
/// Claude's slug scheme replaces `.` as well as `/` (`/Users/x/.buzz` is stored as
/// `-Users-x--buzz`), and the treatment of other character classes is undocumented and not ours to
/// pin down. An earlier design keyed identity on a reconstructed slug; it would have silently shown
/// no button for any workroom path containing a dot, and had no way to tell that apart from "no
/// history here". When the hint misses, `enumerateClaudeProjects` finds it anyway.
///
/// Exact matching also **resolves** the `/a-b/c` vs `/a/b/c` slug collision rather than accepting it,
/// and removes any need to case-fold (wrong on a case-sensitive or external volume) or to resolve
/// symlinks before slugging (a session started through a symlink may be recorded under the textual
/// path, so resolving first looks in the wrong place).
///
/// Every read is best-effort and bounded. A missing, unreadable or enormous store yields no offers
/// and no error — the failure mode is a button that does not appear.
final class AgentSessionIndex {
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "agent-resume")

  /// Hard bounds on the scan. Discovery runs on the launch path, and a Codex store accumulates one
  /// file per session forever — several thousand on a machine like this one — so "read them all"
  /// is not a bound. Every limit is enforced, and hitting one publishes a PARTIAL result rather
  /// than nothing: a missing button is the designed failure, an unbounded scan is not.
  struct Limits {
    /// Ceiling on files opened across the whole build. Directory entries are cheap; opens are not.
    var maxFiles = 2_000
    /// Ceiling per file. Only the head of a transcript is ever needed, and a session file grows
    /// without limit.
    var maxBytesPerFile = 256 * 1024
    /// How far into a Claude transcript to look for the first record carrying `cwd`. It is normally
    /// line 2; a long tool-result preamble could push it further, but not far.
    var maxLinesPerFile = 64
    /// Wall clock for the whole build.
    var deadline: TimeInterval = 3

    static let standard = Limits()
  }

  /// Where each agent keeps its transcripts. Rooted at a home directory so a UI test can seed a fake
  /// tree (`-WorkroomUITestAgentSessionRoot`) instead of reading the developer's real `~/.claude`.
  struct Roots {
    var claudeProjects: URL
    var codexSessions: URL

    init(home: URL) {
      claudeProjects = home.appendingPathComponent(".claude/projects", isDirectory: true)
      codexSessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    static var standard: Roots {
      Roots(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }
  }

  private let roots: Roots
  private let limits: Limits
  private let fileManager: FileManager
  /// Injected so tests drive the deadline without sleeping.
  private let now: () -> Date

  init(
    roots: Roots = .standard, limits: Limits = .standard, fileManager: FileManager = .default,
    now: @escaping () -> Date = Date.init
  ) {
    self.roots = roots
    self.limits = limits
    self.fileManager = fileManager
    self.now = now
  }

  /// The index this build should use, or **nil to disable discovery entirely**.
  ///
  /// Mirrors `SessionStore.forCurrentEnvironment`, and for the same reason: these stores belong to
  /// the developer, not to the app. A UI test gets a seeded fake `$HOME` only when it asks for one,
  /// and a unit test never gets a real store at all — otherwise `AgentSessionIndexTests` would pass
  /// or fail depending on which directories the developer had used an agent in that day.
  static func forCurrentEnvironment() -> AgentSessionIndex? {
    if let root = UITestFixture.agentSessionRoot {
      return AgentSessionIndex(roots: Roots(home: URL(fileURLWithPath: root, isDirectory: true)))
    }
    guard !UITestFixture.isActive,
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    else { return nil }
    return AgentSessionIndex()
  }

  // MARK: Recency

  /// How far a session file's mtime may sit from the quit and still count (issue #145, D3).
  ///
  /// Deliberately not the ±5 minutes first proposed. A transcript's mtime is its last **message**,
  /// not the last moment the session was alive: leaving Claude idle at its prompt for forty minutes
  /// and then quitting — an ordinary way to end a day — puts the mtime far outside a five-minute
  /// window, and the feature silently does nothing on exactly the day it was wanted.
  ///
  /// Twelve hours is affordable only *because* matching is exact. With directory guessing a wider
  /// window multiplies genuine false positives; with a confirmed `cwd` a "false positive" means this
  /// exact directory really does have a resumable conversation, which is true information. Nothing
  /// auto-resumes either way — the click is the gate and the agent still shows its picker.
  static let recencyWindow: TimeInterval = 12 * 60 * 60

  /// Symmetric on purpose: a future-dated mtime is clock skew (or a restored backup), not evidence
  /// of absence.
  static func isRecent(_ modified: Date, savedAt: Date, window: TimeInterval = recencyWindow)
    -> Bool
  {
    abs(modified.timeIntervalSince(savedAt)) <= window
  }

  // MARK: Path comparison

  /// Whether a recorded `cwd` denotes the same directory as a pane's.
  ///
  /// Textual comparison first, because that is what the agent actually wrote. A symlink match is
  /// accepted as a secondary candidate — a session started through `/work/link` may be recorded
  /// under either the link or its target, and we cannot know which — but resolution is never applied
  /// *before* the textual check, or a session recorded under the link would stop matching.
  ///
  /// No `lowercased()`. The boot volume is case-insensitive by default, but a case-sensitive APFS
  /// volume or an external disk is not, and folding there would merge two genuinely different
  /// directories.
  static func pathsMatch(_ recorded: String, _ pane: String) -> Bool {
    let a = trimmed(recorded)
    let b = trimmed(pane)
    guard !a.isEmpty, !b.isEmpty else { return false }
    if a == b { return true }
    return resolved(a) == resolved(b)
  }

  private static func trimmed(_ path: String) -> String {
    var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.count > 1, value.hasSuffix("/") { value.removeLast() }
    return value
  }

  private static func resolved(_ path: String) -> String {
    trimmed(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
  }

  // MARK: Claude

  /// Claude's directory name for a working directory — a **hint**, not an identity. See the type
  /// comment: `/` and `.` both become `-`, other classes are undocumented, and every candidate this
  /// produces is confirmed against the `cwd` recorded inside the file before it counts.
  static func claudeSlugHint(for path: String) -> String {
    String(trimmed(path).map { $0 == "/" || $0 == "." ? "-" : $0 })
  }

  /// The working directory a Claude transcript records, or nil.
  ///
  /// Scans forward: line 1 is a summary record with no `cwd`, so stopping there would find nothing.
  static func claudeCwd(inLines lines: [String]) -> String? {
    for line in lines {
      guard let object = jsonObject(line), let cwd = object["cwd"] as? String, !cwd.isEmpty else {
        continue
      }
      return cwd
    }
    return nil
  }

  // MARK: Codex

  /// The working directory a Codex rollout records, from its `session_meta` first line.
  ///
  /// The type check is not decoration: a file whose first line is some other record kind is a shape
  /// we do not understand, and guessing at it would be how a future Codex format silently starts
  /// matching the wrong directory.
  static func codexCwd(inFirstLine line: String) -> String? {
    guard let object = jsonObject(line), object["type"] as? String == "session_meta",
      let payload = object["payload"] as? [String: Any],
      let cwd = payload["cwd"] as? String, !cwd.isEmpty
    else { return nil }
    return cwd
  }

  private static func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  // MARK: Building

  /// Which backends have a resumable conversation for each of `cwds`, as of `savedAt`.
  ///
  /// Blocking. The caller runs this off the main actor and delivers the result back on it; see
  /// `AgentResumeCoordinator`. `isCancelled` is consulted between entries so a scan whose panes have
  /// all closed stops promptly rather than finishing on principle.
  func backends(
    forCwds cwds: [String], savedAt: Date, isCancelled: @escaping () -> Bool = { false }
  ) -> [String: Set<AgentBackend>] {
    var budget = Budget(limits: limits, start: now(), now: now, isCancelled: isCancelled)
    var result: [String: Set<AgentBackend>] = [:]

    for cwd in cwds where !budget.isExhausted {
      if claudeHasHistory(cwd: cwd, savedAt: savedAt, budget: &budget) {
        result[cwd, default: []].insert(.claude)
      }
    }

    // Codex cannot be addressed by path — its tree is keyed by date — so the day directories are
    // scanned once and every pane is answered from the resulting set, rather than re-walking them
    // per pane.
    if !budget.isExhausted {
      let codexCwds = codexRecordedCwds(savedAt: savedAt, budget: &budget)
      for cwd in cwds where codexCwds.contains(where: { Self.pathsMatch($0, cwd) }) {
        result[cwd, default: []].insert(.codex)
      }
    }

    if budget.isExhausted {
      Self.logger.notice(
        "agent session scan stopped early (files: \(budget.filesOpened, privacy: .public)) — offers may be incomplete"
      )
    }
    return result
  }

  private func claudeHasHistory(cwd: String, savedAt: Date, budget: inout Budget) -> Bool {
    // The hint first: one directory listing instead of 58.
    let hinted = roots.claudeProjects.appendingPathComponent(
      Self.claudeSlugHint(for: cwd), isDirectory: true)
    if directoryExists(hinted),
      transcriptMatches(in: hinted, cwd: cwd, savedAt: savedAt, budget: &budget)
    {
      return true
    }
    // The hint missed — an undocumented character class, or a genuinely absent directory. Fall back
    // to looking at every project directory, which is what makes the hint safe to be wrong about.
    guard !directoryExists(hinted) else { return false }
    for directory in enumerateClaudeProjects() where !budget.isExhausted {
      guard directory != hinted else { continue }
      if transcriptMatches(in: directory, cwd: cwd, savedAt: savedAt, budget: &budget) {
        return true
      }
    }
    return false
  }

  /// Depth 1 only. `~/.claude/projects/<slug>/` also holds per-session subdirectories and other
  /// tooling state; the resumable unit is a `.jsonl` sitting directly in the project directory.
  private func transcriptMatches(
    in directory: URL, cwd: String, savedAt: Date, budget: inout Budget
  ) -> Bool {
    for file in recentJSONLFiles(in: directory, savedAt: savedAt) where !budget.isExhausted {
      budget.filesOpened += 1
      let lines = head(of: file, lines: limits.maxLinesPerFile)
      guard let recorded = Self.claudeCwd(inLines: lines) else { continue }
      if Self.pathsMatch(recorded, cwd) { return true }
    }
    return false
  }

  private func enumerateClaudeProjects() -> [URL] {
    contents(of: roots.claudeProjects).filter { directoryExists($0) }
  }

  /// Every `cwd` recorded by a Codex rollout inside the recency window.
  private func codexRecordedCwds(savedAt: Date, budget: inout Budget) -> Set<String> {
    var found: Set<String> = []
    for day in codexDayDirectories(savedAt: savedAt) where !budget.isExhausted {
      for file in recentJSONLFiles(in: day, savedAt: savedAt, prefix: "rollout-")
      where !budget.isExhausted {
        budget.filesOpened += 1
        guard let first = head(of: file, lines: 1).first,
          let recorded = Self.codexCwd(inFirstLine: first)
        else { continue }
        found.insert(recorded)
      }
    }
    return found
  }

  /// Only the `YYYY/MM/DD` directories whose day intersects the window — at most three for a 12-hour
  /// window, however many years of sessions the store holds.
  private func codexDayDirectories(savedAt: Date) -> [URL] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let days = Set(
      [-Self.recencyWindow, 0, Self.recencyWindow].map {
        calendar.startOfDay(for: savedAt.addingTimeInterval($0))
      })

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy/MM/dd"

    return days.sorted().map {
      roots.codexSessions.appendingPathComponent(formatter.string(from: $0), isDirectory: true)
    }
    .filter { directoryExists($0) }
  }

  // MARK: Filesystem

  private func recentJSONLFiles(in directory: URL, savedAt: Date, prefix: String? = nil) -> [URL] {
    contents(of: directory, keys: [.contentModificationDateKey, .isRegularFileKey])
      .filter { url in
        guard url.pathExtension == "jsonl" else { return false }
        if let prefix, !url.lastPathComponent.hasPrefix(prefix) { return false }
        let values = try? url.resourceValues(forKeys: [
          .contentModificationDateKey, .isRegularFileKey,
        ])
        // Regular files only. A symlinked candidate is a path out of the store we were pointed at,
        // and following one would let anything that can write into an agent directory aim our reads
        // somewhere else entirely.
        guard values?.isRegularFile == true, let modified = values?.contentModificationDate else {
          return false
        }
        return Self.isRecent(modified, savedAt: savedAt)
      }
  }

  private func contents(of directory: URL, keys: [URLResourceKey] = []) -> [URL] {
    (try? fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
  }

  private func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// The first `lines` lines of a file, reading at most `maxBytesPerFile`.
  ///
  /// A transcript grows without bound, so this never loads one whole: it pulls a bounded prefix and
  /// splits it. A trailing partial line is dropped unless it is the only thing read, which keeps a
  /// half-written record from being parsed as a complete one.
  private func head(of url: URL, lines: Int) -> [String] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limits.maxBytesPerFile), !data.isEmpty else {
      return []
    }
    let text = String(decoding: data, as: UTF8.self)
    var split = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    if data.count == limits.maxBytesPerFile, split.count > 1 { split.removeLast() }
    return Array(split.prefix(lines))
  }

  // MARK: Budget

  /// The running cost of one build, so every limit is checked in one place rather than at each
  /// call site (where the next one added would be the one that gets forgotten).
  private struct Budget {
    let limits: Limits
    let start: Date
    let now: () -> Date
    let isCancelled: () -> Bool
    var filesOpened = 0

    var isExhausted: Bool {
      isCancelled() || filesOpened >= limits.maxFiles
        || now().timeIntervalSince(start) >= limits.deadline
    }
  }
}
