import Foundation
import SwiftGitX

/// git-backed `VCSProviding`, over SwiftGitX (libgit2). Maps `SwiftGitX.*` types into the app-native
/// models. Pure Swift — no Rust involved for git.
///
/// Errors are caught untyped (`catch { … "\(error)" }`) on purpose: binding SwiftGitX's typed-throws
/// error (`catch let e as SwiftGitXError`) trips a Swift 6 SIL ownership error across the async
/// boundary.
struct GitProvider: VCSProviding {
  func log(root: URL, limit: Int) async throws -> VCSHistoryPage {
    do {
      let repo = try Repository.open(at: root)
      // A repo with no commits yet (unborn HEAD) is an empty history, not a failure.
      if repo.isHEADUnborn { return VCSHistoryPage(commits: [], reachedEnd: true) }

      // Take one extra to learn whether more history exists beyond the page.
      let window = Array(try repo.log().prefix(max(0, limit) + 1))
      let reachedEnd = window.count <= limit
      let commits = window.prefix(limit).map(Self.map)
      return VCSHistoryPage(commits: Array(commits), reachedEnd: reachedEnd)
    } catch {
      throw VCSError.io("\(error)")
    }
  }

  func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
    do {
      let repo = try Repository.open(at: root)
      let commit: Commit = try repo.show(id: OID(hex: commitID))
      let diff = try repo.diff(commit: commit)
      return VCSChangeset(
        commit: Self.map(commit),
        fullMessage: commit.message,
        files: diff.changes.map(Self.mapDelta),
        isMerge: ((try? commit.parents.count) ?? 0) > 1
      )
    } catch {
      throw VCSError.io("\(error)")
    }
  }

  func currentRef(root: URL) async throws -> VCSRef {
    do {
      let repo = try Repository.open(at: root)
      // Unborn HEAD (git init, no commit): HEAD symbolically points at a branch that has no commit
      // yet. Report that branch name (from config's init.defaultBranch) so a fresh repo still labels.
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

  func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
    do {
      let repo = try Repository.open(at: root)
      let commit: Commit = try repo.show(id: OID(hex: commitID))
      let diff = try repo.diff(commit: commit)
      guard
        let patch = diff.patches.first(where: {
          $0.delta.newFile.path == path || $0.delta.oldFile.path == path
        })
      else {
        return ""  // path unchanged in this changeset
      }
      return Self.gitFormat(patch)
    } catch {
      throw VCSError.io("\(error)")
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
        files.append(ChangedFile(path: path, change: change))
      }
      // Current branch for CI (nil when detached / unborn) — `branch.current` throws when detached.
      let branch = (try? repo.branch.current.name)
      let (insertions, deletions) = Self.workingLineStats(repo)
      return GitWorkingStatus(
        dirty: !files.isEmpty, conflicted: conflicted, files: files, branch: branch,
        insertions: insertions, deletions: deletions)
    } catch {
      throw VCSError.io("\(error)")
    }
  }

  // MARK: - Mapping

  private static func map(_ c: Commit) -> VCSCommit {
    VCSCommit(
      commitID: c.id.hex,
      shortID: c.id.abbreviated,
      changeID: nil,  // git has no change-id
      summary: c.summary,
      authors: [VCSAuthor(name: c.author.name, email: c.author.email)],
      timestamp: c.date,
      refs: [],  // branch/tag decoration: a later increment
      parentIDs: (try? c.parents)?.map { $0.id.hex } ?? [],
      isWorkingCopy: false  // git has no jj-style working-copy commit
    )
  }

  private static func mapDelta(_ d: Diff.Delta) -> VCSChangedFile {
    let path = d.newFile.path.isEmpty ? d.oldFile.path : d.newFile.path
    let kind: VCSChangeKind =
      switch d.type {
      case .added: .added
      case .deleted: .deleted
      case .modified: .modified
      case .renamed: .renamed
      case .copied: .copied
      case .conflicted: .conflicted
      default: .other
      }
    let oldPath = (d.type == .renamed || d.type == .copied) ? d.oldFile.path : nil
    return VCSChangedFile(path: path, oldPath: oldPath, kind: kind)
  }

  /// Reconstruct git-format unified-diff text from a SwiftGitX `Patch` so the existing `UnifiedDiff`
  /// parser (and `DiffViewer`) can consume it — the git-format patch is the app's diff lingua franca
  /// (jj produces the same shape).
  private static func gitFormat(_ patch: Patch) -> String {
    let d = patch.delta
    let oldPath = d.oldFile.path.isEmpty ? d.newFile.path : d.oldFile.path
    let newPath = d.newFile.path.isEmpty ? d.oldFile.path : d.newFile.path
    var out = "diff --git a/\(oldPath) b/\(newPath)\n"
    if d.flags.contains(.binary) {
      out += "Binary files a/\(oldPath) and b/\(newPath) differ\n"
      return out
    }
    out += "--- " + (d.type == .added ? "/dev/null" : "a/\(oldPath)") + "\n"
    out += "+++ " + (d.type == .deleted ? "/dev/null" : "b/\(newPath)") + "\n"
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

  /// `git diff HEAD` line counts (staged + unstaged tracked changes; untracked files excluded, as
  /// git's `--shortstat HEAD` does). `nil` when there's no diff to read. Summed from patch lines
  /// since libgit2's diff-stats aren't surfaced by SwiftGitX.
  private static func workingLineStats(_ repo: Repository) -> (insertions: Int?, deletions: Int?) {
    guard let diff = try? repo.diff(to: [.workingTree, .index]) else { return (nil, nil) }
    var insertions = 0
    var deletions = 0
    for patch in diff.patches {
      for hunk in patch.hunks {
        for line in hunk.lines {
          switch line.type {
          case .addition, .additionEOF: insertions += 1
          case .deletion, .deletionEOF: deletions += 1
          default: break
          }
        }
      }
    }
    return (insertions, deletions)
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
