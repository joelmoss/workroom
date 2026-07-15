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
  /// The VCS backend, injected for tests. Defaults to the real repo-kind router
  /// (`VCS.provider(for:)` — jj → jj-lib/CLI, git → SwiftGitX). Serves commit (`fileDiff`) and
  /// working-copy (`workingFileDiff`) diffs and the new-side content for highlighting (`fileContent`)
  /// — the resolver itself no longer shells out for anything.
  let makeProvider: @Sendable (URL) throws -> VCSProviding
  /// Cache for immutable **commit** diffs, shared across viewers. Working-copy diffs are never cached
  /// — their content is mutable, so a cache would serve stale hunks after an edit.
  let cache: DiffCache

  /// Diffs whose git-format text exceeds this render as `.tooLarge` instead of being parsed — a
  /// multi-MB single-file diff is unreadable and slow to lay out. (GitHub Desktop gates whole diffs
  /// at 10 MB; this is per-file.)
  static let maxDiffBytes = 3 * 1024 * 1024

  init(
    makeProvider: @escaping @Sendable (URL) throws -> VCSProviding = { try VCS.provider(for: $0) },
    cache: DiffCache = .shared
  ) {
    self.makeProvider = makeProvider
    self.cache = cache
  }

  /// Fetch and parse the diff for `descriptor`, reading the repo rooted at `dir` (the workroom
  /// directory, an absolute path). Every source is read structurally through the VCS backend
  /// (`VCSProviding`) — no diff shells out of this resolver — and the git-format text each returns
  /// feeds the one `UnifiedDiff` pipeline. Returns a `DiffResult` the viewer renders directly.
  func resolve(_ descriptor: DiffDescriptor, in dir: String) async -> DiffResult {
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    switch descriptor.source {
    case .commit(let commitID):
      return await resolveCommit(commitID: commitID, path: descriptor.path, root: root)
    case .jjWorkingCopy, .gitWorktree:
      return await resolveWorking(path: descriptor.path, base: .workingCopy, root: root)
    case .jjParent:
      return await resolveWorking(path: descriptor.path, base: .parent, root: root)
    }
  }

  /// A commit diff is immutable, so it's cached (keyed by root + commit id + path): re-selecting a
  /// file in History or reopening a changeset tab is then instant. Sourced from
  /// `VCSProviding.fileDiff` (jj-lib / SwiftGitX).
  private func resolveCommit(commitID: String, path: String, root: URL) async -> DiffResult {
    let key = "commit\u{1F}\(root.path)\u{1F}\(commitID)\u{1F}\(path)"
    if let cached = await cache.get(key) { return cached }
    do {
      let text = try await makeProvider(root).fileDiff(root: root, commitID: commitID, path: path)
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
  /// `VCSProviding.workingFileDiff`. Never cached — the working copy is mutable, so a cache would
  /// serve a stale diff after an on-disk edit.
  private func resolveWorking(path: String, base: VCSWorkingDiffBase, root: URL) async -> DiffResult
  {
    do {
      let text = try await makeProvider(root).workingFileDiff(root: root, path: path, base: base)
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

  private var entries: [String: DiffResult] = [:]
  private var sizes: [String: Int] = [:]
  private var order: [String] = []  // front = least-recently-used
  private var total = 0
  private let budget: Int

  init(budget: Int = 32 * 1024 * 1024) { self.budget = budget }

  func get(_ key: String) -> DiffResult? {
    guard let value = entries[key] else { return nil }
    touch(key)
    return value
  }

  func set(_ key: String, _ value: DiffResult, bytes: Int) {
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

  private func touch(_ key: String) {
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
  ///   `VCSProviding.fileContent` (git blob walk / jj `jj file show --ignore-working-copy`). This is
  ///   why a commit diff now highlights too.
  ///
  /// Best-effort throughout: any backend error becomes `nil` (render plain). Only additions + context
  /// are highlighted, so a deleted file (no new side) correctly yields `nil`.
  func fileContent(for descriptor: DiffDescriptor, in dir: String) async -> String? {
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    switch descriptor.source {
    case .commit(let commitID):
      return try? await makeProvider(root).fileContent(
        root: root, rev: commitID, path: descriptor.path)
    case .gitWorktree, .jjWorkingCopy:
      return Self.readWorkingFile(path: descriptor.path, in: dir)
    case .jjParent:
      return try? await makeProvider(root).fileContent(
        root: root, rev: "@-", path: descriptor.path)
    }
  }

  /// The OLD-side (pre-image) content for a diff — for syntax-highlighting its DELETED lines (the new
  /// side highlighter can't, since deletions don't exist in the new file). Routes to the provider's
  /// parent/base resolver per source. Best-effort: any error / absence → `nil` (deletions render
  /// plain). Deleted files (no new side) still highlight their removals from this old side.
  func oldFileContent(for descriptor: DiffDescriptor, in dir: String) async -> String? {
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    let provider = try? makeProvider(root)
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
