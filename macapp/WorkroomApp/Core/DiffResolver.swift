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

/// Resolves the diff for a single `DiffDescriptor` by shelling to `git` or `jj`. Pure — all VCS
/// specifics are in `command(for:dir:)` (unit-tested without spawning). `resolve(_:in:)` calls
/// the runner, interprets the result, and parses the unified diff.
struct DiffResolver: Sendable {
  /// Optional raw local engine injection for existing engine tests. Production always uses the
  /// context-bound router, including the overload accepting an explicit remote location.
  let makeProvider: (@Sendable (URL) throws -> LocalVCSProviding)?
  let router: RepositoryRouter
  /// Cache for immutable **commit** diffs, shared across viewers. Working-copy diffs are never cached
  /// — their content is mutable, so a cache would serve stale hunks after an edit.
  let cache: DiffCache
  /// Serializes jj working-copy snapshots per project root (see `JJSnapshotGate`) — only the
  /// `.jjWorkingCopy` source (below) ever reaches a snapshotting call.
  let gate: JJSnapshotGate

  /// Diffs whose git-format text exceeds this render as `.tooLarge` instead of being parsed — a
  /// multi-MB single-file diff is unreadable and slow to lay out. (GitHub Desktop gates whole diffs
  /// at 10 MB; this is per-file.)
  static let maxDiffBytes = 3 * 1024 * 1024

  init(
    makeProvider: (@Sendable (URL) throws -> LocalVCSProviding)? = nil,
    router: RepositoryRouter = .shared,
    cache: DiffCache = .shared, gate: JJSnapshotGate = .shared
  ) {
    self.makeProvider = makeProvider
    self.router = router
    self.cache = cache
    self.gate = gate
  }

  /// Fetch and parse the diff for `descriptor`, reading the repo rooted at `dir` (the workroom
  /// directory, an absolute path). Every source is read structurally through the VCS backend
  /// (`LocalVCSProviding`) — no diff shells out of this resolver — and the git-format text each returns
  /// feeds the one `UnifiedDiff` pipeline. Returns a `DiffResult` the viewer renders directly.
  ///
  /// The string entry point belongs to local persisted records. It normalizes asynchronously and
  /// then routes by identity. `projectRoot` is used only by explicitly injected local engine tests;
  /// production snapshots obtain ownership exclusively from the captured registry entry.
  func resolve(_ descriptor: DiffDescriptor, in dir: String, projectRoot: String?) async
    -> DiffResult
  {
    if makeProvider == nil {
      do { return await resolve(descriptor, in: try await RepositoryLocation.local(dir)) } catch {
        return .failed(error.localizedDescription)
      }
    }
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    switch descriptor.source {
    case .commit(let commitID):
      return await resolveCommit(commitID: commitID, path: descriptor.path, root: root)
    case .jjWorkingCopy:
      return await resolveWorking(
        path: descriptor.path, base: .workingCopy, root: root, projectRoot: projectRoot ?? dir)
    case .gitWorktree:
      return await resolveWorking(
        path: descriptor.path, base: .workingCopy, root: root, projectRoot: nil)
    case .jjParent:
      return await resolveWorking(
        path: descriptor.path, base: .parent, root: root, projectRoot: nil)
    }
  }

  func resolve(_ descriptor: DiffDescriptor, in location: RepositoryLocation) async -> DiffResult {
    do {
      let provider = try await router.reader(for: location)
      switch descriptor.source {
      case .commit(let revision):
        let key = DiffCache.Key(
          location: location, backend: provider.context.backend,
          revision: revision, path: descriptor.path)
        if let cached = await cache.get(key) { return cached }
        let text = try await provider.fileDiff(commitID: revision, path: descriptor.path)
        let result = Self.interpret(text)
        if case .failed = result {} else { await cache.set(key, result, bytes: text.utf8.count) }
        return result
      case .jjWorkingCopy, .gitWorktree:
        return Self.interpret(
          try await provider.workingFileDiff(path: descriptor.path, base: .workingCopy))
      case .jjParent:
        return Self.interpret(
          try await provider.workingFileDiff(path: descriptor.path, base: .parent))
      }
    } catch let error as VCSError { return .failed(Self.message(for: error)) } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// A commit diff is immutable, so it's cached (keyed by root + commit id + path): re-selecting a
  /// file in History or reopening a changeset tab is then instant. Sourced from
  /// `LocalVCSProviding.fileDiff` (jj-lib / SwiftGitX).
  private func resolveCommit(commitID: String, path: String, root: URL) async -> DiffResult {
    do {
      let location = try await RepositoryLocation.local(root.path)
      let key = DiffCache.Key(location: location, backend: .git, revision: commitID, path: path)
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

  /// A working-copy diff (jj `@`/`@-`, git worktree) read structurally via
  /// `LocalVCSProviding.workingFileDiff`. Never cached — the working copy is mutable, so a cache would
  /// serve a stale diff after an on-disk edit. `base == .workingCopy` for a jj repo is the one case
  /// that snapshots `@` (no `--ignore-working-copy`, unlike `.parent`) — gated per project root
  /// when `projectRoot` is supplied (always true for `.jjWorkingCopy`, always `nil` for
  /// `.gitWorktree`/`.jjParent`; see `resolve`'s dispatch) so it can't race the status sweep's own
  /// snapshot of the same project.
  private func resolveWorking(
    path: String, base: VCSWorkingDiffBase, root: URL, projectRoot: String?
  ) async -> DiffResult {
    do {
      let text: String
      if base == .workingCopy, let projectRoot {
        text = try await gate.run(projectRoot: projectRoot) {
          try await self.makeProvider!(root).workingFileDiff(root: root, path: path, base: base)
        }
      } else {
        text = try await makeProvider!(root).workingFileDiff(root: root, path: path, base: base)
      }
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
    let backend: RepositoryBackend
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
  /// - working-copy sources (`gitWorktree`, `jjWorkingCopy`): a guarded disk read (the working copy
  ///   is `@`, so nothing shells out and nothing contends on the jj working-copy lock).
  /// - `commit(id)` / jj `parent` (`@-`): the new side is a committed revision (not on disk) →
  ///   `LocalVCSProviding.fileContent` (git blob walk / jj `jj file show --ignore-working-copy`). This is
  ///   why a commit diff now highlights too.
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
    case .gitWorktree, .jjWorkingCopy:
      return Self.readWorkingFile(path: descriptor.path, in: dir)
    case .jjParent:
      return try? await makeProvider!(root).fileContent(
        root: root, rev: "@-", path: descriptor.path)
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
    case .gitWorktree, .jjWorkingCopy:
      return try? await provider?.workingBaseFileContent(
        root: root, base: .workingCopy, path: descriptor.path)
    case .jjParent:
      return try? await provider?.workingBaseFileContent(
        root: root, base: .parent, path: descriptor.path)
    }
  }

  func fileContent(for descriptor: DiffDescriptor, in location: RepositoryLocation) async -> String?
  {
    switch descriptor.source {
    case .gitWorktree, .jjWorkingCopy:
      guard location.host == .local else { return nil }
      return try? await runBlocking {
        Self.readWorkingFile(path: descriptor.path, in: location.path)
      }
    case .commit(let revision):
      return try? await router.reader(for: location).fileContent(
        rev: revision, path: descriptor.path)
    case .jjParent:
      return try? await router.reader(for: location).fileContent(rev: "@-", path: descriptor.path)
    }
  }

  func oldFileContent(for descriptor: DiffDescriptor, in location: RepositoryLocation) async
    -> String?
  {
    guard let provider = try? await router.reader(for: location) else { return nil }
    switch descriptor.source {
    case .commit(let revision):
      return try? await provider.commitParentFileContent(commitID: revision, path: descriptor.path)
    case .gitWorktree, .jjWorkingCopy:
      return try? await provider.workingBaseFileContent(base: .workingCopy, path: descriptor.path)
    case .jjParent:
      return try? await provider.workingBaseFileContent(base: .parent, path: descriptor.path)
    }
  }

  /// Read a working-copy file for highlighting, guarded against the traps a syntax parse would
  /// otherwise hit (a symlink whose *target text* git diffs, a path escaping the workroom, an
  /// over-cap file). Returns `nil` (⇒ render plain) on any guard failure or non-UTF-8 content.
  static func readWorkingFile(path: String, in dir: String) -> String? {
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    let target = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL

    // Canonical-path containment: resolve symlinks on BOTH sides (consistently — so /tmp→/private
    // doesn't trip a legit file) and require the real target to live under the real workroom. This
    // catches an intermediate symlinked directory that would otherwise escape via a string prefix.
    let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let realTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
    guard realTarget == realRoot || realTarget.hasPrefix(realRoot + "/") else { return nil }

    // lstat the leaf (don't follow symlinks): a symlink's diff is its *target path text*, not file
    // content, so parsing it as source would be wrong → render plain. Require a regular file.
    guard
      let values = try? target.resourceValues(forKeys: [
        .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
      ]),
      values.isSymbolicLink != true,
      values.isRegularFile == true,
      let size = values.fileSize, size <= SyntaxLanguage.byteCap
    else { return nil }

    return try? String(contentsOf: target, encoding: .utf8)
  }
}
