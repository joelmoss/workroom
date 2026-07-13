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
}
