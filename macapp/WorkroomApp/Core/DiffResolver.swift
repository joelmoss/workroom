import Foundation

/// The outcome of a `DiffResolver.resolve` call.
enum DiffResult: Equatable, Sendable {
  /// A parseable text diff.
  case diff(UnifiedDiff)
  /// The VCS reported binary content; there are no textual hunks to render.
  case binary
  /// No differences (the file is clean / unchanged for this source).
  case empty
  /// The diff exceeds `DiffResolver.maxDiffBytes` — the UI shows a "too large" placeholder rather
  /// than parsing a multi-MB (or CLI-truncated) buffer that would render slowly or wrongly.
  case tooLarge
  /// The command failed or timed out. The associated value is a short human-readable message
  /// (the first non-empty stderr line, or a generic fallback).
  case failed(String)
}

/// Resolves the diff for a single `DiffDescriptor` through the VCS backend. `resolve(_:in:)` reads
/// the git-format text, interprets the result, and parses the unified diff.
struct DiffResolver: Sendable {
  /// Optional raw local engine injection for existing engine tests. Production always uses the
  /// context-bound router, including the overload accepting an explicit remote location.
  let makeProvider: (@Sendable (URL) throws -> LocalVCSProviding)?
  let router: RepositoryRouter
  /// Cache for immutable **commit** diffs, shared across viewers. Working-copy diffs are never cached
  /// — their content is mutable, so a cache would serve stale hunks after an edit.
  let cache: DiffCache

  /// Diffs whose git-format text exceeds this render as `.tooLarge` instead of being parsed — a
  /// multi-MB single-file diff is unreadable and slow to lay out. (GitHub Desktop gates whole diffs
  /// at 10 MB; this is per-file.)
  static let maxDiffBytes = 3 * 1024 * 1024

  init(
    makeProvider: (@Sendable (URL) throws -> LocalVCSProviding)? = nil,
    router: RepositoryRouter = .shared,
    cache: DiffCache = .shared
  ) {
    self.makeProvider = makeProvider
    self.router = router
    self.cache = cache
  }

  /// Fetch and parse the diff for `descriptor`, reading the repo rooted at `dir` (the workroom
  /// directory, an absolute path). Every source is read structurally through the VCS backend
  /// (`LocalVCSProviding`) — no diff shells out of this resolver — and the git-format text each returns
  /// feeds the one `UnifiedDiff` pipeline. Returns a `DiffResult` the viewer renders directly.
  ///
  /// The string entry point belongs to local persisted records. It normalizes asynchronously and
  /// then routes by identity.
  func resolve(_ descriptor: DiffDescriptor, in dir: String) async -> DiffResult {
    if makeProvider == nil {
      do { return await resolve(descriptor, in: try await RepositoryLocation.local(dir)) } catch {
        return .failed(error.localizedDescription)
      }
    }
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    switch descriptor.source {
    case .commit(let commitID):
      return await resolveCommit(commitID: commitID, path: descriptor.path, root: root)
    case .gitWorktree:
      return await resolveWorking(path: descriptor.path, root: root)
    }
  }

  func resolve(_ descriptor: DiffDescriptor, in location: RepositoryLocation) async -> DiffResult {
    do {
      let provider = try await router.reader(for: location)
      switch descriptor.source {
      case .commit(let revision):
        let key = DiffCache.Key(location: location, revision: revision, path: descriptor.path)
        if let cached = await cache.get(key) { return cached }
        let text = try await provider.fileDiff(commitID: revision, path: descriptor.path)
        let result = Self.interpret(text)
        if case .failed = result {} else { await cache.set(key, result, bytes: text.utf8.count) }
        return result
      case .gitWorktree:
        return Self.interpret(
          try await provider.workingFileDiff(path: descriptor.path))
      }
    } catch let error as VCSError { return .failed(Self.message(for: error)) } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// A commit diff is immutable, so it's cached (keyed by root + commit id + path): re-selecting a
  /// file in History or reopening a changeset tab is then instant. Sourced from
  /// `LocalVCSProviding.fileDiff`.
  private func resolveCommit(commitID: String, path: String, root: URL) async -> DiffResult {
    do {
      let location = try await RepositoryLocation.local(root.path)
      let key = DiffCache.Key(location: location, revision: commitID, path: path)
      if let cached = await cache.get(key) { return cached }
      let text = try await makeProvider!(root).fileDiff(root: root, commitID: commitID, path: path)
      let result = Self.interpret(text)
      // Cache only settled outcomes — never a transient failure.
      if case .failed = result {} else { await cache.set(key, result, bytes: text.utf8.count) }
      return result
    } catch let error as VCSError {
      return .failed(Self.message(for: error))
    } catch {
      return .failed("Diff unavailable")
    }
  }

  /// A git worktree diff read structurally via `LocalVCSProviding.workingFileDiff`. Never cached —
  /// the working copy is mutable, so a cache would serve a stale diff after an on-disk edit.
  private func resolveWorking(path: String, root: URL) async -> DiffResult {
    do {
      let text = try await makeProvider!(root).workingFileDiff(
        root: root, path: path)
      return Self.interpret(text)
    } catch let error as VCSError {
      return .failed(Self.message(for: error))
    } catch {
      return .failed("Diff unavailable")
    }
  }

  /// Classify git-format diff text into a render outcome. Size-gate first (cheapest rejection of a
  /// huge/truncated buffer), then binary, then empty, then parse. Pure — unit-tested.
  static func interpret(_ text: String) -> DiffResult {
    if text.utf8.count > maxDiffBytes { return .tooLarge }
    if UnifiedDiff.isBinary(text) { return .binary }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
    return .diff(UnifiedDiff.parse(text))
  }

  /// A short, human-readable message for a backend error (shown in the diff pane's failed state).
  private static func message(for error: VCSError) -> String {
    switch error {
    case .unsupportedRepo(let m): return "Unsupported repository: \(m)"
    case .notFound(let m): return "Not found: \(m)"
    case .lockContention: return "Repository is busy"
    case .staleSnapshot: return "Repository changed — retry"
    case .partialData(let m): return m
    case .backendVersion(let m): return m
    case .io(let m): return m
    }
  }

}

/// LRU byte-budgeted cache for immutable (commit) diffs, shared across `DiffViewer`s. Modeled on
/// jayjay's `DiffCache`: evict least-recently-used until under budget, but always keep the most
/// recent entry so a single oversized diff still stays cached for its own view. An `actor` so
/// concurrent viewers can read/write it without a data race.
actor DiffCache {
  static let shared = DiffCache()

  struct Key: Hashable, Sendable {
    let location: RepositoryLocation
    let revision: String
    let path: String
  }

  private var entries: [Key: DiffResult] = [:]
  private var sizes: [Key: Int] = [:]
  private var order: [Key] = []  // front = least-recently-used
  private var total = 0
  private let budget: Int

  init(budget: Int = 32 * 1024 * 1024) { self.budget = budget }

  func get(_ key: Key) -> DiffResult? {
    guard let value = entries[key] else { return nil }
    touch(key)
    return value
  }

  func set(_ key: Key, _ value: DiffResult, bytes: Int) {
    if entries[key] != nil {
      total -= sizes[key] ?? 0
      order.removeAll { $0 == key }
    }
    entries[key] = value
    sizes[key] = bytes
    order.append(key)
    total += bytes
    evict()
  }

  func clear() {
    entries.removeAll()
    sizes.removeAll()
    order.removeAll()
    total = 0
  }

  private func touch(_ key: Key) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  private func evict() {
    while total > budget, order.count > 1, let oldest = order.first {
      order.removeFirst()
      total -= sizes.removeValue(forKey: oldest) ?? 0
      entries.removeValue(forKey: oldest)
    }
  }
}

// MARK: - New-file content (for syntax highlighting)

extension DiffResolver {
  /// The **new-side** file content for syntax highlighting, or `nil` ⇒ the caller renders the diff
  /// plain. Read structurally through the VCS backend, except the working copy (the new side *is* the
  /// on-disk file):
  ///
  /// - `gitWorktree`: a guarded disk read (nothing shells out).
  /// - `commit(id)`: the new side is a committed revision (not on disk) →
  ///   `LocalVCSProviding.fileContent` (git blob walk). This is why a commit diff highlights too.
  ///
  /// Best-effort throughout: any backend error becomes `nil` (render plain). Only additions + context
  /// are highlighted, so a deleted file (no new side) correctly yields `nil`.
  func fileContent(for descriptor: DiffDescriptor, in dir: String) async -> String? {
    if makeProvider == nil {
      guard let location = try? await RepositoryLocation.local(dir) else { return nil }
      return await fileContent(for: descriptor, in: location)
    }
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    switch descriptor.source {
    case .commit(let commitID):
      return try? await makeProvider!(root).fileContent(
        root: root, rev: commitID, path: descriptor.path)
    case .gitWorktree:
      return await readWorkingFile(path: descriptor.path, in: dir)
    }
  }

  /// The OLD-side (pre-image) content for a diff — for syntax-highlighting its DELETED lines (the new
  /// side highlighter can't, since deletions don't exist in the new file). Routes to the provider's
  /// parent/base resolver per source. Best-effort: any error / absence → `nil` (deletions render
  /// plain). Deleted files (no new side) still highlight their removals from this old side.
  func oldFileContent(for descriptor: DiffDescriptor, in dir: String) async -> String? {
    if makeProvider == nil {
      guard let location = try? await RepositoryLocation.local(dir) else { return nil }
      return await oldFileContent(for: descriptor, in: location)
    }
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    let provider = try? makeProvider!(root)
    switch descriptor.source {
    case .commit(let commitID):
      return try? await provider?.commitParentFileContent(
        root: root, commitID: commitID, path: descriptor.path)
    case .gitWorktree:
      return try? await provider?.workingBaseFileContent(
        root: root, path: descriptor.path)
    }
  }

  func fileContent(for descriptor: DiffDescriptor, in location: RepositoryLocation) async -> String?
  {
    switch descriptor.source {
    case .gitWorktree:
      guard location.host == .local else { return nil }
      return await readWorkingFile(path: descriptor.path, location: location)
    case .commit(let revision):
      return try? await router.reader(for: location).fileContent(
        rev: revision, path: descriptor.path)
    }
  }

  func oldFileContent(for descriptor: DiffDescriptor, in location: RepositoryLocation) async
    -> String?
  {
    guard let provider = try? await router.reader(for: location) else { return nil }
    switch descriptor.source {
    case .commit(let revision):
      return try? await provider.commitParentFileContent(commitID: revision, path: descriptor.path)
    case .gitWorktree:
      return try? await provider.workingBaseFileContent(path: descriptor.path)
    }
  }

  /// Read a working-copy file for highlighting through the file service, or `nil` (⇒ render plain).
  ///
  /// Under the `refuse` symlink policy: a symlink's diff is its *target path text*, not file content,
  /// so parsing it as source would be wrong; and a path that escapes the workroom, a non-regular file
  /// and an over-cap file are refused the same way. Enforced on the host that holds the file, on the
  /// opened descriptor — the guards this used to run client-side against a path it then opened
  /// separately. Non-UTF-8 content also yields `nil`.
  private func readWorkingFile(path: String, in dir: String) async -> String? {
    guard let location = try? await RepositoryLocation.local(dir) else { return nil }
    return await readWorkingFile(path: path, location: location)
  }

  private func readWorkingFile(path: String, location: RepositoryLocation) async -> String? {
    guard let files = try? await router.files(for: location),
      let data = try? await files.read(
        path: path, symlinks: .refuse, maxBytes: SyntaxLanguage.byteCap)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
