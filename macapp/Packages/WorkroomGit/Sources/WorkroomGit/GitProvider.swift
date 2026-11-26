import Foundation
import WorkroomSystem
import WorkroomVCS
import libgit2

/// git-backed `LocalVCSProviding`, on libgit2's C API (the vendored `LibGit2` package). Maps
/// `GitRepository`'s values into the app-native models. Pure Swift and C — no Rust involved for git.
///
/// Three reads have readers of their own (see each type's doc): push state via `GitGraph`, because
/// "not on origin yet" is a commit RANGE (`git_revwalk_hide`); commit diffs via `GitCommitDiff`,
/// because rename detection has to run on a live `git_diff`; and the working tree's ± line counts via
/// `GitDiffStats`, which counts in C rather than materializing every changed line.
///
/// Every libgit2 failure surfaces as `VCSError.io`, carrying libgit2's reason.
public struct GitProvider: LocalVCSProviding {
  /// The largest blob a content read returns: the syntax highlighter's cap. It equals
  /// `SyntaxLanguage.byteCap`, spelled here so this package needn't build tree-sitter and its
  /// grammars; a hosted test pins the two together.
  public static let maxContentBytes = 2 * 1024 * 1024

  public init() {}

  public func log(root: URL, limit: Int) throws -> VCSHistoryPage {
    do {
      return try GitRepository.read(root) { repo in
        // A repo with no commits yet (unborn HEAD) is an empty history, not a failure.
        if repo.isHEADUnborn { return VCSHistoryPage(commits: [], reachedEnd: true) }

        // Take one extra to learn whether more history exists beyond the page.
        let window = try repo.log(limit: max(0, limit) + 1)
        let reachedEnd = window.count <= limit
        let decorations = Self.decorations(in: repo)
        let page = Array(window.prefix(limit))
        // Push state for the whole page in one libgit2 revwalk (`HEAD --not refs/remotes/origin/*`).
        // A `nil` read is unanswerable — no origin, or a ref we couldn't trust — and EVERY row then
        // reads `.unknown`, never a partial answer (a skipped tip could badge a pushed commit as
        // unpushed).
        let push = GitGraph.unpushed(root: root, decide: Set(page.map(\.id)))
        let commits = page.map {
          Self.map($0, refs: decorations[$0.id] ?? [], pushState: Self.pushState($0.id, in: push))
        }
        return VCSHistoryPage(
          commits: commits, reachedEnd: reachedEnd, pushScope: Self.scope(push?.scope))
      }
    } catch {
      throw VCSError.io("\(error)")
    }
  }

  public func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
    try await runBlocking {
      do {
        return try GitRepository.read(root) { repo in
          let commit = try repo.commit(hex: commitID)
          // The file list and line counts come from `GitCommitDiff`: a plain tree-to-tree diff has no
          // `git_diff_find_similar`, so a committed rename would split into delete + add. See that
          // type's doc.
          guard let diff = GitCommitDiff.read(root: root, commitID: commit.id) else {
            throw VCSError.io("could not read the diff for \(commit.id)")
          }
          // One-commit push state: `git_graph_reachable_from_any` against the origin tips. There's no
          // page here to bound a walk with, which is exactly why this form exists.
          let push = GitGraph.isPushed(root: root, commitID: commit.id)
          return VCSChangeset(
            commit: Self.map(
              commit, refs: Self.decorations(in: repo)[commit.id] ?? [],
              pushState: push.map { $0.pushed ? .pushed : .unpushed } ?? .unknown),
            fullMessage: commit.message,
            files: diff.files,
            isMerge: (commit.parentIDs?.count ?? 0) > 1,
            insertions: diff.insertions,
            deletions: diff.deletions,
            pushScope: Self.scope(push?.scope)
          )
        }
      } catch let error as VCSError {
        throw error  // already classified (the diff read above) — don't re-wrap it
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  public func currentRef(root: URL) async throws -> VCSRef {
    try await runBlocking {
      do {
        return try GitRepository.read(root) { repo in
          // Unborn HEAD (git init, no commit): HEAD symbolically points at a branch with no commit
          // yet. Report that branch name (from config's init.defaultBranch) so a fresh repo still
          // labels.
          if repo.isHEADUnborn {
            let name = repo.defaultBranchName()
            return VCSRef(name: name, kind: name == nil ? .none : .branch)
          }
          // Attached HEAD → the current branch.
          if let branch = repo.currentBranchName() {
            return VCSRef(name: branch, kind: .branch)
          }
          // Detached HEAD → the short commit id.
          return VCSRef(name: String(try repo.headCommitID().prefix(8)), kind: .detached)
        }
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  public func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
    try await runBlocking {
      do {
        return try GitRepository.read(root) { repo in
          let commit = try repo.commit(hex: commitID)
          // Same rename-detected diff the file list is built from (`changeset`), so a row that reads
          // "renamed" renders as a rename here too — libgit2 prints the patch in git's own format,
          // `rename from`/`rename to` headers included. `""` ⇒ path unchanged in this changeset.
          guard let text = GitCommitDiff.patch(root: root, commitID: commit.id, path: path) else {
            throw VCSError.io("could not read the diff for \(path) in \(commit.id)")
          }
          return text
        }
      } catch let error as VCSError {
        throw error  // already classified (the diff read above) — don't re-wrap it
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  /// Working-copy per-file diff, as git-format text — the working-copy counterpart of `fileDiff`,
  /// built structurally from libgit2 (no subprocess, no `git diff` shell-out). Per-file by
  /// construction: it fetches the single path's status delta, then builds just that file's patch
  /// (`git_patch_from_blob*`) — never a whole-worktree diff.
  public func workingFileDiff(root: URL, path: String) async throws -> String {
    try await runBlocking {
      do {
        return try GitRepository.read(root) { repo in
          // Same status options as `workingStatus`: untracked + rename detection, so the delta type
          // matches the badge and a `git mv` reads as one rename (blob→file), not delete + add.
          guard
            let entry = try repo.status(flags: Self.statusFlags).first(where: {
              let d = $0.workingTree ?? $0.index
              return d?.newPath == path || d?.oldPath == path
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
          let newPath = delta.newPath.isEmpty ? delta.oldPath : delta.newPath
          let oldPath = delta.oldPath.isEmpty ? delta.newPath : delta.oldPath
          return Self.gitFormat(patch, oldPath: oldPath, newPath: newPath, type: delta.type)
        }
      } catch let error as VCSError {
        throw error
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  /// The content of `path` at commit `rev`, for syntax-highlighting the diff's new side. Looks the
  /// path up in the commit's tree (no subprocess). `nil` ⇒ path absent at that commit / not a blob /
  /// over the highlight cap / non-UTF-8 (binary) → the caller renders plain. Offloaded to GCD
  /// (`runBlocking`) so the synchronous libgit2 read never runs on the fixed-width cooperative pool.
  public func fileContent(root: URL, rev: String, path: String) async throws -> String? {
    try await runBlocking {
      do {
        return try GitRepository.read(root) { try Self.fileContentSync($0, rev: rev, path: path) }
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  /// Old-side content of `path` at commit `rev`'s first parent (for highlighting deleted lines).
  /// `nil` for a root commit (no parent) / absent-at-parent / binary / over cap. GCD-offloaded.
  public func commitParentFileContent(root: URL, commitID: String, path: String) async throws
    -> String?
  {
    try await runBlocking {
      do {
        return try GitRepository.read(root) { repo in
          guard let parent = try repo.commit(hex: commitID).parentIDs?.first else { return nil }
          return try Self.fileContentSync(repo, rev: parent, path: path)
        }
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  /// Old-side content of `path` for a working-copy diff — the file at `HEAD`. GCD-offloaded.
  public func workingBaseFileContent(root: URL, path: String) async throws
    -> String?
  {
    try await runBlocking {
      do {
        return try GitRepository.read(root) { repo in
          try Self.fileContentSync(repo, rev: repo.headCommitID(), path: path)
        }
      } catch {
        throw VCSError.io("\(error)")
      }
    }
  }

  /// Synchronous blob read shared by the content methods (each opens the repo, then delegates here) —
  /// so the two old-side methods resolve their pre-image WITHOUT a nested async hop inside `runBlocking`.
  /// `nil` ⇒ path absent at `rev` / not a blob / over the highlight cap / non-UTF-8 (binary).
  private static func fileContentSync(_ repo: GitRepository, rev: String, path: String) throws
    -> String?
  {
    let commit = try repo.commit(hex: rev)
    guard let blobID = try repo.blobID(at: path, in: commit) else { return nil }
    let content = try repo.blobContent(blobID)
    // Over the highlight cap → render plain (a truncated read would mis-map byte offsets).
    guard content.count <= maxContentBytes else { return nil }
    return String(data: content, encoding: .utf8)  // nil ⇒ binary / non-UTF-8
  }

  /// The combined HEAD→worktree diff for a file that has BOTH an index delta (HEAD→index) and a
  /// working-tree delta (index→worktree) — i.e. staged, then edited again. A missing old side is
  /// only EXPECTED when `indexDelta.type` is added (the file is new since HEAD — `oldID` is a null
  /// OID, and `gitFormat` already renders that as `/dev/null`); checking the delta's own type
  /// first, rather than inferring "new since HEAD" from whether the blob lookup happened to throw,
  /// means a genuine read failure (corrupt object, partial clone) on a blob that's supposed to exist
  /// propagates as an error instead of silently rendering the file as a fabricated whole-file add.
  /// The CURRENT on-disk path/content comes from `workingTreeDelta` (its own old and new paths are
  /// both the post-index name — a rename only the worktree half made would show up there), never the
  /// staged blob, so both legs of the edit show up as one diff. Mirrors `workingPatch`'s conflicted
  /// case, which reads HEAD→worktree the same way (that case's own blob lookup is a pre-existing,
  /// separate gap).
  private static func combinedWorkingDiff(
    _ repo: GitRepository, indexDelta: GitRepository.Delta,
    workingTreeDelta: GitRepository.Delta, root: URL
  ) throws -> String {
    let headBlob: git_oid? = indexDelta.type == GIT_DELTA_ADDED ? nil : indexDelta.oldID
    let oldPath = indexDelta.oldPath.isEmpty ? indexDelta.newPath : indexDelta.oldPath
    let currentPath =
      workingTreeDelta.newPath.isEmpty ? workingTreeDelta.oldPath : workingTreeDelta.newPath
    // The worktree half deleted what was staged — nothing on disk to read as the new side.
    if workingTreeDelta.type == GIT_DELTA_DELETED {
      guard let headBlob else { return "" }  // never existed at HEAD either: nothing to show
      let patch = try repo.patch(fromBlob: headBlob, toBlob: nil)
      return Self.gitFormat(patch, oldPath: oldPath, newPath: oldPath, type: GIT_DELTA_DELETED)
    }
    // `gitFormat`'s `type` only ever changes which SIDE renders as `/dev/null` (added/untracked
    // ⇒ no old side, deleted ⇒ no new side) — never rename/copy metadata, which this formatter
    // doesn't emit regardless. Deriving it from `indexDelta.type` (e.g. deleted for a staged
    // delete that got recreated on disk with new content) forced `/dev/null` on a side the patch
    // itself has real content for — a self-contradictory header against real hunks. There ARE real
    // on-disk bytes past this point (this branch is reached only when `workingTreeDelta.type` isn't
    // deleted), so the only question `gitFormat` actually needs answered is whether a HEAD side
    // exists at all.
    let patch = try repo.patch(fromBlob: headBlob, toFile: root.appendingPathComponent(currentPath))
    return Self.gitFormat(
      patch, oldPath: oldPath, newPath: currentPath,
      type: headBlob == nil ? GIT_DELTA_ADDED : GIT_DELTA_MODIFIED)
  }

  /// Build a single file's working-copy patch, by delta type: untracked = nothing → the file on
  /// disk; modified/renamed = the old blob → the file on disk (so a staged-only change shows against
  /// the worktree, not the index); added = nothing → the file on disk; deleted = old blob → empty;
  /// conflicted = HEAD blob, if readable → the on-disk (conflict-marked) file. `nil` for anything
  /// else.
  private static func workingPatch(_ repo: GitRepository, delta: GitRepository.Delta, root: URL)
    throws -> GitRepository.Patch?
  {
    switch delta.type {
    case GIT_DELTA_UNTRACKED:
      return try repo.patch(
        fromBlob: nil, toFile: repo.workingDirectory().appendingPathComponent(delta.newPath))
    case GIT_DELTA_MODIFIED, GIT_DELTA_RENAMED:
      return try repo.patch(
        fromBlob: delta.oldID,
        toFile: repo.workingDirectory().appendingPathComponent(delta.newPath))
    case GIT_DELTA_ADDED:
      // A file new since HEAD (e.g. a staged `git add` of a new file) has a null old OID: no old
      // side, rather than a lookup of it.
      return try repo.patch(fromBlob: nil, toFile: root.appendingPathComponent(delta.newPath))
    case GIT_DELTA_DELETED:
      return try repo.patch(fromBlob: delta.oldID, toBlob: nil)
    case GIT_DELTA_CONFLICTED:
      // No readable HEAD blob (one side added it) ⇒ no old side.
      let headBlob: git_oid? = (try? repo.blobContent(delta.oldID)) == nil ? nil : delta.oldID
      let file = delta.newPath.isEmpty ? delta.oldPath : delta.newPath
      return try repo.patch(fromBlob: headBlob, toFile: root.appendingPathComponent(file))
    default:
      return nil
    }
  }

  /// The status options every working-tree read uses: untracked files (recursing into untracked
  /// directories), and rename detection in both halves, which libgit2 leaves off by default.
  private static let statusFlags = [
    GIT_STATUS_OPT_INCLUDE_UNTRACKED, GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS,
    GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX, GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR,
  ]

  /// The working-tree status for the sidebar/Changes badges: changed files (incl. untracked +
  /// conflicts), dirty flag, current branch (for CI lookup), and the `git diff HEAD` line counts.
  /// Read entirely through libgit2 — no subprocess.
  ///
  /// Security: this replaces the CLI status read that carried `-c core.fsmonitor=` +
  /// `--no-ext-diff --no-textconv` hardening against an untrusted repo's config executing a program.
  /// libgit2 needs no such flags here: its fsmonitor support is the bool/IPC form (it never spawns a
  /// `core.fsmonitor` hook program), and its status/diff don't honor `diff.external`/textconv — so
  /// there's no config-driven code-execution surface to neutralise.
  public func workingStatus(root: URL) throws -> WorkroomStatus {
    do {
      return try GitRepository.read(root) { repo in
        var files: [ChangedFile] = []
        var conflicted = false
        // Rename detection (off by default in libgit2) makes a `git mv` read as one renamed entry,
        // matching the CLI porcelain this replaced — not a separate delete + add.
        for entry in try repo.status(flags: Self.statusFlags) {
          if entry.has(GIT_STATUS_IGNORED) { continue }
          if entry.has(GIT_STATUS_CONFLICTED) {
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
          // The pre-move path, for the rename rows the options above enable. Guarded on the delta
          // type because libgit2 fills the old file for every delta (it's the HEAD/index side of a
          // plain modification too), so an unguarded read would label every row a rename.
          let isMove = delta.type == GIT_DELTA_RENAMED || delta.type == GIT_DELTA_COPIED
          let oldPath = isMove && !delta.oldPath.isEmpty ? delta.oldPath : nil
          files.append(ChangedFile(path: path, change: change, oldPath: oldPath))
        }
        // Current branch for CI (nil when detached / unborn).
        let branch = repo.currentBranchName()
        // `git diff HEAD` line counts, counted in C rather than from a second diff materialized
        // line by line. See `GitDiffStats`. `nil` (a failed read) means the badge shows no count.
        let stats = GitDiffStats.workingTree(root: root)
        // `branchForCI` rather than a `branch` of its own: the only thing the app does with a
        // git branch here is look up CI for it. `ci`, `failure` and `localReadAt` stay unset — they
        // are the resolver's to fill.
        return WorkroomStatus(
          dirty: !files.isEmpty, conflicted: conflicted, changedFiles: files,
          insertions: stats?.insertions, deletions: stats?.deletions, branchForCI: branch)
      }
    } catch {
      throw VCSError.io("\(error)")
    }
  }

  // MARK: - Mapping

  /// `commit sha -> decoration labels` for the history list: local branch names, then tag names,
  /// each group sorted, so history rows carry refs.
  ///
  /// Remote-tracking refs (`origin/main`) are deliberately excluded *as labels*: every pushed branch
  /// has a same-named remote ref, so showing them would double every label for no new information.
  /// They ARE read elsewhere — `GitGraph` uses `refs/remotes/origin/*` to answer push state — so this
  /// exclusion is about decoration, not access.
  private static func decorations(in repo: GitRepository) -> [String: [String]] {
    var branches: [String: [String]] = [:]
    for branch in repo.localBranches() {
      branches[branch.target, default: []].append(branch.name)
    }
    var map = branches.mapValues { $0.sorted() }
    var tags: [String: [String]] = [:]
    for tag in repo.tags() {
      tags[tag.target, default: []].append(tag.name)
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

  private static func map(
    _ c: GitRepository.Commit, refs: [String] = [], pushState: VCSPushState = .unknown
  ) -> VCSCommit {
    let primary = VCSAuthor(name: c.authorName, email: c.authorEmail)
    return VCSCommit(
      commitID: c.id,
      shortID: c.shortID,
      summary: c.summary,
      body: Self.messageBody(c.message),
      // Git's author field holds one person; additional authors live in `Co-authored-by:` message
      // trailers (the GitHub convention). Surface both so a co-authored commit shows everyone.
      authors: [primary] + coAuthors(inMessage: c.message, primaryEmail: c.authorEmail),
      timestamp: c.date,
      refs: refs,  // local branch + tag names (see `decorations`)
      parentIDs: c.parentIDs ?? [],
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

  /// Reconstruct git-format unified-diff text from a single-file patch so the existing `UnifiedDiff`
  /// parser (and `DiffViewer`) can consume it — the git-format patch is the app's diff lingua
  /// franca.
  private static func gitFormat(
    _ patch: GitRepository.Patch, oldPath: String, newPath: String, type: git_delta_t
  ) -> String {
    var out = "diff --git a/\(oldPath) b/\(newPath)\n"
    if patch.delta.isBinary {
      out += "Binary files a/\(oldPath) and b/\(newPath) differ\n"
      return out
    }
    // A file with no old side (added / untracked) uses /dev/null as the `---` side; a deleted file
    // uses it as the `+++` side.
    let noOldSide = type == GIT_DELTA_ADDED || type == GIT_DELTA_UNTRACKED
    out += "--- " + (noOldSide ? "/dev/null" : "a/\(oldPath)") + "\n"
    out += "+++ " + (type == GIT_DELTA_DELETED ? "/dev/null" : "b/\(newPath)") + "\n"
    for hunk in patch.hunks {
      out += hunk.header  // libgit2 includes the trailing newline
      for line in hunk.lines {
        out += Self.prefix(line.origin) + line.content  // content includes its trailing newline
      }
    }
    return out
  }

  /// A patch line's prefix: `+` for an addition, `-` for a deletion (each with or without the
  /// end-of-file-newline marker), a space for everything else.
  private static func prefix(_ origin: CChar) -> String {
    switch UInt32(UInt8(bitPattern: origin)) {
    case GIT_DIFF_LINE_ADDITION.rawValue, GIT_DIFF_LINE_ADD_EOFNL.rawValue: "+"
    case GIT_DIFF_LINE_DELETION.rawValue, GIT_DIFF_LINE_DEL_EOFNL.rawValue: "-"
    default: " "
    }
  }

  // MARK: - Working-status helpers

  /// The path a status entry refers to (the new path, or the old path for a delete/rename).
  private static func statusPath(_ entry: GitRepository.StatusEntry) -> String? {
    guard let delta = entry.workingTree ?? entry.index else { return nil }
    return delta.newPath.isEmpty ? delta.oldPath : delta.newPath
  }

  /// Map a libgit2 delta type to the app's working-tree change kind. `nil` for unmodified/ignored/
  /// unreadable (skipped). Conflicts are handled before this by the entry's conflicted status.
  private static func change(_ type: git_delta_t) -> ChangedFile.Change? {
    switch type {
    case GIT_DELTA_ADDED: .added
    case GIT_DELTA_DELETED: .deleted
    case GIT_DELTA_MODIFIED, GIT_DELTA_TYPECHANGE: .modified
    case GIT_DELTA_RENAMED, GIT_DELTA_COPIED: .renamed
    case GIT_DELTA_UNTRACKED: .untracked
    case GIT_DELTA_CONFLICTED: .conflicted
    default: nil
    }
  }
}
