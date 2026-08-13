import Foundation
import SwiftGitX

/// git-backed `VCSProviding`, over SwiftGitX (libgit2). Maps `SwiftGitX.*` types into the app-native
/// models. Pure Swift — no Rust involved for git.
///
/// Three reads reach *past* SwiftGitX, all on raw libgit2 (see each type's doc): push state via
/// `GitGraph`, because SwiftGitX cannot express the commit RANGE that "not on origin yet" is; commit
/// diffs via `GitCommitDiff`, because rename detection has to run on a live `git_diff` and
/// SwiftGitX's `Diff` is already materialized and freed by the time we see it; and the working tree's
/// ± line counts via `GitDiffStats`, because SwiftGitX's eager `Diff` materializes every changed line
/// into a Swift `String` to derive two integers.
///
/// Errors are caught untyped (`catch { … "\(error)" }`) on purpose: binding SwiftGitX's typed-throws
/// error (`catch let e as SwiftGitXError`) trips a Swift 6 SIL ownership error across the async
/// boundary.
struct GitProvider: VCSProviding {
  func log(root: URL, limit: Int) throws -> VCSHistoryPage {
    do {
      let repo = try Repository.open(at: root)
      // A repo with no commits yet (unborn HEAD) is an empty history, not a failure.
      if repo.isHEADUnborn { return VCSHistoryPage(commits: [], reachedEnd: true) }

      // Take one extra to learn whether more history exists beyond the page.
      let window = Array(try repo.log().prefix(max(0, limit) + 1))
      let reachedEnd = window.count <= limit
      let decorations = Self.decorations(in: repo)
      let page = Array(window.prefix(limit))
      // Push state for the whole page in one libgit2 revwalk (`HEAD --not refs/remotes/origin/*`).
      // A `nil` read is unanswerable — no origin, or a ref we couldn't trust — and EVERY row then reads
      // `.unknown`, never a partial answer (a skipped tip could badge a pushed commit as unpushed).
      let push = GitGraph.unpushed(root: root, decide: Set(page.map { $0.id.hex }))
      let commits = page.map {
        Self.map(
          $0, refs: decorations[$0.id.hex] ?? [],
          pushState: Self.pushState($0.id.hex, in: push))
      }
      return VCSHistoryPage(
        commits: commits, reachedEnd: reachedEnd, pushScope: Self.scope(push?.scope))
    } catch {
      throw VCSError.io("\(error)")
    }
  }

  func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
    try await runBlocking {
      do {
        let repo = try Repository.open(at: root)
        let commit: Commit = try repo.show(id: OID(hex: commitID))
        // The file list and line counts come from `GitCommitDiff`, not SwiftGitX: its `repo.diff(commit:)`
        // is a plain tree-to-tree diff with no `git_diff_find_similar`, so a committed rename split into
        // delete + add (and a root commit came back empty). See that type's doc.
        guard let diff = GitCommitDiff.read(root: root, commitID: commit.id.hex) else {
          throw VCSError.io("could not read the diff for \(commit.id.hex)")
        }
        // One-commit push state: `git_graph_reachable_from_any` against the origin tips. There's no page
        // here to bound a walk with, which is exactly why this form exists.
        let push = GitGraph.isPushed(root: root, commitID: commit.id.hex)
        return VCSChangeset(
          commit: Self.map(
            commit, refs: Self.decorations(in: repo)[commit.id.hex] ?? [],
            pushState: push.map { $0.pushed ? .pushed : .unpushed } ?? .unknown),
          fullMessage: commit.message,
          files: diff.files,
          isMerge: ((try? commit.parents.count) ?? 0) > 1,
          insertions: diff.insertions,
          deletions: diff.deletions,
          pushScope: Self.scope(push?.scope)
        )
      } catch let error as VCSError {
        throw error  // already classified (the diff read above) — don't re-wrap it
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  func currentRef(root: URL) async throws -> VCSRef {
    try await runBlocking {
      do {
        let repo = try Repository.open(at: root)
        // Unborn HEAD (git init, no commit): HEAD symbolically points at a branch with no commit yet.
        // Report that branch name (from config's init.defaultBranch) so a fresh repo still labels.
        if repo.isHEADUnborn {
          let name = try? repo.config.defaultBranchName
          return VCSRef(name: name, kind: name == nil ? .none : .branch)
        }
        // Attached HEAD → the current branch. `branch.current` throws when HEAD is detached.
        if let branch = try? repo.branch.current {
          return VCSRef(name: branch.name, kind: .branch)
        }
        // Detached HEAD → the short commit id (mirrors `git rev-parse --short HEAD`).
        let head = try repo.HEAD
        return VCSRef(name: head.target.id.abbreviated, kind: .detached)
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
    try await runBlocking {
      do {
        let repo = try Repository.open(at: root)
        let commit: Commit = try repo.show(id: OID(hex: commitID))
        // Same rename-detected diff the file list is built from (`changeset`), so a row that reads
        // "renamed" renders as a rename here too — libgit2 prints the patch in git's own format,
        // `rename from`/`rename to` headers included. `""` ⇒ path unchanged in this changeset.
        guard let text = GitCommitDiff.patch(root: root, commitID: commit.id.hex, path: path) else {
          throw VCSError.io("could not read the diff for \(path) in \(commit.id.hex)")
        }
        return text
      } catch let error as VCSError {
        throw error  // already classified (the diff read above) — don't re-wrap it
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  /// Working-copy per-file diff, as git-format text — the working-copy counterpart of `fileDiff`,
  /// built structurally from libgit2 (no subprocess, no `git diff` shell-out). Per-file by
  /// construction: it fetches the single path's status delta, then builds just that file's `Patch`
  /// (`git_patch_from_blob*`) — never a whole-worktree diff.
  ///
  /// jj-only `.parent` isn't a git concept (git repos never request it) → unsupported.
  func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
    guard base == .workingCopy else {
      throw VCSError.unsupportedRepo("git has no working-copy parent diff")
    }
    return try await runBlocking {
      do {
        let repo = try Repository.open(at: root)
        // Same status options as `workingStatus`: untracked + rename detection, so the delta type
        // matches the badge and a `git mv` reads as one rename (blob→file), not delete + add.
        let options: StatusOption = [
          .includeUntracked, .recurseUntrackedDirectories, .renamesIndex, .renamesWorkingTree,
        ]
        guard
          let entry = try repo.status(options: options).first(where: {
            let d = $0.workingTree ?? $0.index
            return d?.newFile.path == path || d?.oldFile.path == path
          })
        else {
          return ""  // path clean / not a working-copy change
        }
        // A file staged AND further changed in the worktree carries BOTH deltas (HEAD→index,
        // index→worktree). Picking either alone (the old `workingTree ?? index`) shows only that
        // one leg — e.g. the staged half goes missing. Combine them the same way `.conflicted`
        // already reads HEAD→worktree: diff the file's HEAD blob (nil if it's new since HEAD)
        // against what's on disk now, or against nothing if the worktree half deleted it.
        if let indexDelta = entry.index, let workingTreeDelta = entry.workingTree {
          return try Self.combinedWorkingDiff(
            repo, indexDelta: indexDelta, workingTreeDelta: workingTreeDelta, root: root)
        }
        guard let delta = entry.workingTree ?? entry.index else {
          return ""
        }
        guard let patch = try Self.workingPatch(repo, delta: delta, root: root) else {
          return ""  // a delta type with no renderable per-file patch (e.g. copy without content)
        }
        // Use the status delta's real paths — a blob-built patch carries empty delta paths.
        let newPath = delta.newFile.path.isEmpty ? delta.oldFile.path : delta.newFile.path
        let oldPath = delta.oldFile.path.isEmpty ? delta.newFile.path : delta.oldFile.path
        return Self.gitFormat(patch, oldPath: oldPath, newPath: newPath, type: delta.type)
      } catch let error as VCSError {
        throw error
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  /// The content of `path` at commit `rev`, for syntax-highlighting the diff's new side. Walks the
  /// commit's tree to the blob (no subprocess). `nil` ⇒ path absent at that commit / not a blob /
  /// over the highlight cap / non-UTF-8 (binary) → the caller renders plain. Offloaded to GCD
  /// (`runBlocking`) so the synchronous libgit2 walk never runs on the fixed-width cooperative pool.
  func fileContent(root: URL, rev: String, path: String) async throws -> String? {
    try await runBlocking {
      do {
        let repo = try Repository.open(at: root)
        return try Self.fileContentSync(repo, rev: rev, path: path)
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  /// Old-side content of `path` at commit `rev`'s first parent (for highlighting deleted lines).
  /// `nil` for a root commit (no parent) / absent-at-parent / binary / over cap. GCD-offloaded.
  func commitParentFileContent(root: URL, commitID: String, path: String) async throws -> String? {
    try await runBlocking {
      do {
        let repo = try Repository.open(at: root)
        let commit: Commit = try repo.show(id: OID(hex: commitID))
        guard let parent = (try? commit.parents)?.first else { return nil }
        return try Self.fileContentSync(repo, rev: parent.id.hex, path: path)
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  /// Old-side content of `path` for a working-copy diff — the file at `HEAD`. Git has no `.parent`
  /// working surface, so that base yields `nil`. GCD-offloaded.
  func workingBaseFileContent(root: URL, base: VCSWorkingDiffBase, path: String) async throws
    -> String?
  {
    guard base == .workingCopy else { return nil }
    return try await runBlocking {
      do {
        let repo = try Repository.open(at: root)
        return try Self.fileContentSync(repo, rev: repo.HEAD.target.id.hex, path: path)
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  /// Synchronous blob read shared by the content methods (each opens the repo, then delegates here) —
  /// so the two old-side methods resolve their pre-image WITHOUT a nested async hop inside `runBlocking`.
  /// `nil` ⇒ path absent at `rev` / not a blob / over the highlight cap / non-UTF-8 (binary).
  private static func fileContentSync(_ repo: Repository, rev: String, path: String) throws
    -> String?
  {
    let commit: Commit = try repo.show(id: OID(hex: rev))
    guard let blobID = try Self.blobID(in: commit.tree, path: path, repo: repo) else { return nil }
    let blob: Blob = try repo.show(id: blobID)
    // Over the highlight cap → render plain (a truncated read would mis-map byte offsets).
    guard blob.content.count <= SyntaxLanguage.byteCap else { return nil }
    return String(data: blob.content, encoding: .utf8)  // nil ⇒ binary / non-UTF-8
  }

  /// Resolve `path` to its blob OID by walking the tree component-by-component (SwiftGitX `Tree`
  /// exposes only flat `entries`, so nested paths are walked by hand). `nil` if any component is
  /// missing or the leaf isn't a blob.
  private static func blobID(in tree: Tree, path: String, repo: Repository) throws -> OID? {
    let parts = path.split(separator: "/").map(String.init)
    guard !parts.isEmpty else { return nil }
    var current = tree
    for (index, part) in parts.enumerated() {
      guard let entry = current.entries.first(where: { $0.name == part }) else { return nil }
      if index == parts.count - 1 {
        return entry.type == .blob ? entry.id : nil
      }
      guard entry.type == .tree else { return nil }
      current = try repo.show(id: entry.id)
    }
    return nil
  }

  /// The combined HEAD→worktree diff for a file that has BOTH a `.index` delta (HEAD→index) and a
  /// `.workingTree` delta (index→worktree) — i.e. staged, then edited again. `indexDelta.oldFile.id`
  /// is the file's blob at HEAD (empty/invalid, and so `nil` after `show`, when the file is new since
  /// HEAD — same "no old side" case `gitFormat` already renders as `/dev/null`). The CURRENT on-disk
  /// path/content comes from `workingTreeDelta` (its own `oldFile`/`newFile` are both the post-index
  /// name — a rename only the worktree half made would show up there), never the staged blob, so both
  /// legs of the edit show up as one diff. Mirrors `workingPatch`'s `.conflicted` case, which reads
  /// HEAD→worktree the same way.
  private static func combinedWorkingDiff(
    _ repo: Repository, indexDelta: Diff.Delta, workingTreeDelta: Diff.Delta, root: URL
  ) throws -> String {
    let headBlob: Blob? = try? repo.show(id: indexDelta.oldFile.id)
    let oldPath =
      indexDelta.oldFile.path.isEmpty ? indexDelta.newFile.path : indexDelta.oldFile.path
    let currentPath =
      workingTreeDelta.newFile.path.isEmpty
      ? workingTreeDelta.oldFile.path : workingTreeDelta.newFile.path
    // The worktree half deleted what was staged — nothing on disk to read as the new side.
    if workingTreeDelta.type == .deleted {
      guard let headBlob else { return "" }  // never existed at HEAD either: nothing to show
      let patch = try repo.patch(from: headBlob, to: nil)
      return Self.gitFormat(patch, oldPath: oldPath, newPath: oldPath, type: .deleted)
    }
    let patch = try repo.patch(from: headBlob, to: root.appendingPathComponent(currentPath))
    return Self.gitFormat(
      patch, oldPath: oldPath, newPath: currentPath,
      type: headBlob == nil ? .added : indexDelta.type)
  }

  /// Build a single file's working-copy `Patch`. Prefers SwiftGitX's `patch(from: delta)` (handles
  /// untracked/added/modified/renamed); fills its gaps by hand: `.deleted` = old blob → empty,
  /// `.conflicted` = HEAD blob → the on-disk (conflict-marked) file. `nil` for anything else.
  private static func workingPatch(_ repo: Repository, delta: Diff.Delta, root: URL) throws
    -> Patch?
  {
    switch delta.type {
    case .untracked, .added, .modified, .renamed:
      return try repo.patch(from: delta)
    case .deleted:
      let oldBlob: Blob = try repo.show(id: delta.oldFile.id)
      return try repo.patch(from: oldBlob, to: nil)
    case .conflicted:
      let headBlob: Blob? = try? repo.show(id: delta.oldFile.id)
      let file = delta.newFile.path.isEmpty ? delta.oldFile.path : delta.newFile.path
      return try repo.patch(from: headBlob, to: root.appendingPathComponent(file))
    default:
      return nil
    }
  }

  /// The working-tree status for the sidebar/Changes badges: changed files (incl. untracked +
  /// conflicts), dirty flag, current branch (for CI lookup), and the `git diff HEAD` line counts.
  /// Read entirely through libgit2 — no subprocess.
  ///
  /// Security: this replaces the CLI status read that carried `-c core.fsmonitor=` +
  /// `--no-ext-diff --no-textconv` hardening against an untrusted repo's config executing a program.
  /// libgit2 needs no such flags here: its fsmonitor support is the bool/IPC form (it never spawns a
  /// `core.fsmonitor` hook program), and its status/diff don't honor `diff.external`/textconv — so
  /// there's no config-driven code-execution surface to neutralise.
  func workingStatus(root: URL) throws -> GitWorkingStatus {
    do {
      let repo = try Repository.open(at: root)
      var files: [ChangedFile] = []
      var conflicted = false
      // Enable rename detection (off by default in libgit2) so a `git mv` reads as one `.renamed`
      // entry, matching the CLI porcelain this replaced — not a separate delete + add.
      let options: StatusOption = [
        .includeUntracked, .recurseUntrackedDirectories, .renamesIndex, .renamesWorkingTree,
      ]
      for entry in try repo.status(options: options) {
        if entry.status.contains(.ignored) || entry.status.contains(.current) { continue }
        if entry.status.contains(.conflicted) {
          conflicted = true
          if let path = Self.statusPath(entry) {
            files.append(ChangedFile(path: path, change: .conflicted))
          }
          continue
        }
        // Prefer the working-tree delta (unstaged), fall back to the index delta (staged-only).
        guard let delta = entry.workingTree ?? entry.index,
          let change = Self.change(delta.type), let path = Self.statusPath(entry)
        else { continue }
        // The pre-move path, for the rename rows the options above enable. Guarded on the delta type
        // because libgit2 fills `oldFile` for every delta (it's the HEAD/index side of a plain
        // modification too), so an unguarded read would label every row a rename.
        let oldPath =
          (delta.type == .renamed || delta.type == .copied) ? delta.oldFile.path : nil
        files.append(
          ChangedFile(path: path, change: change, oldPath: oldPath?.isEmpty == true ? nil : oldPath)
        )
      }
      // Current branch for CI (nil when detached / unborn) — `branch.current` throws when detached.
      let branch = (try? repo.branch.current.name)
      // `git diff HEAD` line counts, on raw libgit2 rather than a second SwiftGitX `Diff`: deriving them
      // from one would materialize every patch line of the whole worktree on every refresh, for two
      // integers. See `GitDiffStats`. `nil` (a failed read) means the badge shows no count.
      let stats = GitDiffStats.workingTree(root: root)
      let (insertions, deletions) = (stats?.insertions, stats?.deletions)
      return GitWorkingStatus(
        dirty: !files.isEmpty, conflicted: conflicted, files: files, branch: branch,
        insertions: insertions, deletions: deletions)
    } catch {
      throw VCSError.io("\(error)")
    }
  }

  // MARK: - Mapping

  /// `commit sha -> decoration labels` for the history list: local branch names, then tag names,
  /// each group sorted. This is git's answer to jj's bookmarks (`bookmark_map` in the Rust core), so
  /// a git repo's history rows carry refs too.
  ///
  /// Remote-tracking refs (`origin/main`) are deliberately excluded *as labels*: jj surfaces only
  /// *local* bookmarks, and since every pushed branch has a same-named remote ref, showing them would
  /// double every label for no new information. They ARE read elsewhere — `GitGraph` uses
  /// `refs/remotes/origin/*` to answer push state — so this exclusion is about decoration, not access.
  private static func decorations(in repo: Repository) -> [String: [String]] {
    var branches: [String: [String]] = [:]
    for branch in (try? repo.branch.list(.local)) ?? [] {
      branches[branch.target.id.hex, default: []].append(branch.name)
    }
    var map = branches.mapValues { $0.sorted() }
    var tags: [String: [String]] = [:]
    for tag in (try? repo.tag.list()) ?? [] {
      tags[peeledID(tag.target), default: []].append(tag.name)
    }
    for (id, names) in tags { map[id, default: []].append(contentsOf: names.sorted()) }
    return map
  }

  /// One page commit's push state. An unanswerable read (`nil`) makes every row `.unknown`; otherwise a
  /// sha in the walk's output is unpushed and anything else was reachable from origin.
  private static func pushState(_ sha: String, in read: GitGraph.PageRead?) -> VCSPushState {
    guard let read else { return .unknown }
    return read.unpushed.contains(sha) ? .unpushed : .pushed
  }

  private static func scope(_ scope: GitGraph.Scope?) -> VCSPushScope? {
    scope.map { VCSPushScope(refName: $0.refName, count: $0.count) }
  }

  /// The id of the object a ref ultimately points at, following tag-to-tag chains (an annotated tag
  /// already exposes its target commit; a lightweight tag can point at another tag object).
  private static func peeledID(_ object: any Object) -> String {
    var object = object
    while let tag = object as? Tag { object = tag.target }
    return object.id.hex
  }

  private static func map(
    _ c: Commit, refs: [String] = [], pushState: VCSPushState = .unknown
  ) -> VCSCommit {
    let primary = VCSAuthor(name: c.author.name, email: c.author.email)
    return VCSCommit(
      commitID: c.id.hex,
      shortID: c.id.abbreviated,
      changeID: nil,  // git has no change-id
      summary: c.summary,
      body: Self.messageBody(c.message),
      // Git's author field holds one person; additional authors live in `Co-authored-by:` message
      // trailers (the GitHub convention). Surface both so a co-authored commit shows everyone.
      authors: [primary] + coAuthors(inMessage: c.message, primaryEmail: c.author.email),
      timestamp: c.date,
      refs: refs,  // local branch + tag names (see `decorations`)
      parentIDs: (try? c.parents)?.map { $0.id.hex } ?? [],
      isWorkingCopy: false,  // git has no jj-style working-copy commit
      pushState: pushState
    )
  }

  /// The commit message below its summary (first) line, trimmed — empty for a single-line message.
  static func messageBody(_ message: String) -> String {
    let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > 1 else { return "" }
    return lines.dropFirst().joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Additional authors from `Co-authored-by: Name <email>` trailers, in message order, deduped by
  /// email (case-insensitive) against the primary author and each other. Key match is
  /// case-insensitive; a trailer without a `<email>` is skipped. Internal for unit testing.
  static func coAuthors(inMessage message: String, primaryEmail: String) -> [VCSAuthor] {
    var seen: Set<String> = [primaryEmail.lowercased()]
    var result: [VCSAuthor] = []
    for rawLine in message.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      let prefix = "co-authored-by:"
      guard line.lowercased().hasPrefix(prefix) else { continue }
      let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
      guard let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close
      else { continue }
      let name = value[..<open].trimmingCharacters(in: .whitespaces)
      let email = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
      guard !email.isEmpty, seen.insert(email.lowercased()).inserted else { continue }
      result.append(VCSAuthor(name: name.isEmpty ? email : name, email: email))
    }
    return result
  }

  /// Reconstruct git-format unified-diff text from a SwiftGitX `Patch` so the existing `UnifiedDiff`
  /// parser (and `DiffViewer`) can consume it — the git-format patch is the app's diff lingua franca
  /// (jj produces the same shape).
  private static func gitFormat(
    _ patch: Patch, oldPath: String, newPath: String, type: Diff.DeltaType
  ) -> String {
    var out = "diff --git a/\(oldPath) b/\(newPath)\n"
    if patch.delta.flags.contains(.binary) {
      out += "Binary files a/\(oldPath) and b/\(newPath) differ\n"
      return out
    }
    // A file with no old side (added / untracked) uses /dev/null as the `---` side; a deleted file
    // uses it as the `+++` side.
    let noOldSide = type == .added || type == .untracked
    out += "--- " + (noOldSide ? "/dev/null" : "a/\(oldPath)") + "\n"
    out += "+++ " + (type == .deleted ? "/dev/null" : "b/\(newPath)") + "\n"
    for hunk in patch.hunks {
      out += hunk.header  // libgit2 includes the trailing newline
      for line in hunk.lines {
        let prefix =
          switch line.type {
          case .addition, .additionEOF: "+"
          case .deletion, .deletionEOF: "-"
          default: " "
          }
        out += prefix + line.content  // content includes its trailing newline
      }
    }
    return out
  }

  // MARK: - Working-status helpers

  /// The path a status entry refers to (the new path, or the old path for a delete/rename).
  private static func statusPath(_ entry: StatusEntry) -> String? {
    guard let delta = entry.workingTree ?? entry.index else { return nil }
    return delta.newFile.path.isEmpty ? delta.oldFile.path : delta.newFile.path
  }

  /// Map a libgit2 delta type to the app's working-tree change kind. `nil` for unmodified/ignored
  /// (skipped). Conflicts are handled before this by the entry's `.conflicted` status.
  private static func change(_ type: Diff.DeltaType) -> ChangedFile.Change? {
    switch type {
    case .added: return .added
    case .deleted: return .deleted
    case .modified, .typeChange: return .modified
    case .renamed, .copied: return .renamed
    case .untracked: return .untracked
    case .conflicted: return .conflicted
    case .unmodified, .ignored, .unreadable: return nil
    }
  }

}

/// The git working-tree status behind the sidebar/Changes badges (issue #59), read via SwiftGitX.
/// Git-shaped for now; the jj working status (with its `@`/`@-` disclosure structure) unifies onto a
/// shared `VCSProviding.workingStatus` in the follow-on that migrates the jj resolver reads.
struct GitWorkingStatus: Equatable, Sendable {
  let dirty: Bool
  let conflicted: Bool
  let files: [ChangedFile]
  /// Current branch (for CI lookup); nil when HEAD is detached or unborn.
  let branch: String?
  let insertions: Int?
  let deletions: Int?
}
