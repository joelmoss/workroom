import Foundation

/// Whether a folder is there, answered on the main actor without touching the disk: the last
/// answer a bounded stat off the main actor gave (`GitRepositoryProbe.blockingRead`), refreshed in
/// the background as it is read. A stat on a stalled network mount blocks its thread until the
/// kernel gives up, so a synchronous caller (a new terminal picking its folder) reads the last
/// answer and an async one awaits a fresh one (`check`).
///
/// A path never checked reads as present: the healthy case is the folder still being there, and
/// the read starts the check that corrects it within a moment. A stat that outruns `timeout` reads
/// as absent, as a folder that is gone does.
@MainActor
final class FolderPresence {
  static let shared = FolderPresence()

  /// How long one stat may take before the folder reads as unreachable.
  let timeout: TimeInterval
  /// How old an answer may be before a read refreshes it.
  let maxAge: Duration
  /// Whether `path` is a folder. Blocking: only ever run inside `blockingRead`. Nil for the disk.
  private let stat: (@Sendable (String) -> Bool)?

  private var known: [String: (isFolder: Bool, checked: ContinuousClock.Instant)] = [:]
  private var checking: [String: Task<Bool, Never>] = [:]

  init(
    timeout: TimeInterval = 2, maxAge: Duration = .seconds(1),
    stat: (@Sendable (String) -> Bool)? = nil
  ) {
    self.timeout = timeout
    self.maxAge = maxAge
    self.stat = stat
  }

  /// The last answer for `path`, true when it was never checked; refreshes it when it is older
  /// than `maxAge`. Never touches the disk.
  func isFolder(_ path: String) -> Bool {
    let last = known[path]
    if last.map({ ContinuousClock.now - $0.checked >= maxAge }) ?? true { refresh(path) }
    return last?.isFolder ?? true
  }

  /// A fresh answer for `path`, awaited: false when the stat outruns `timeout`.
  @discardableResult
  func check(_ path: String) async -> Bool {
    await refresh(path).value
  }

  /// Whether `path` exists, from a stat off the main actor under `timeout`: false when it outruns
  /// it, as for a path that is gone. `stat` stands in for the disk in tests.
  nonisolated static func exists(
    _ path: String, timeout: TimeInterval, stat: (@Sendable (String) -> Bool)? = nil
  ) async -> Bool {
    await GitRepositoryProbe.blockingRead("exists\u{0}\(path)", timeout: timeout) {
      stat?(path) ?? FileManager.default.fileExists(atPath: path)
    } ?? false
  }

  /// Which of `paths` exist, stat-ed at once, each as `exists` does.
  nonisolated static func existing(
    _ paths: Set<String>, timeout: TimeInterval, stat: (@Sendable (String) -> Bool)? = nil
  ) async -> Set<String> {
    await withTaskGroup(of: String?.self) { group in
      for path in paths {
        group.addTask { await exists(path, timeout: timeout, stat: stat) ? path : nil }
      }
      var found: Set<String> = []
      for await path in group { if let path { found.insert(path) } }
      return found
    }
  }

  @discardableResult
  private func refresh(_ path: String) -> Task<Bool, Never> {
    if let inFlight = checking[path] { return inFlight }
    let stat = stat
    let timeout = timeout
    let task = Task { [weak self] in
      // Keyed as the probe keys its own folder stat, so the two join on a wedged mount.
      let isFolder =
        await GitRepositoryProbe.blockingRead("folder\u{0}\(path)", timeout: timeout) {
          stat?(path) ?? GitRepositoryProbe.isFolder(path)
        } ?? false
      self?.known[path] = (isFolder, ContinuousClock.now)
      self?.checking[path] = nil
      return isFolder
    }
    checking[path] = task
    return task
  }
}
