import Foundation
import libgit2

/// A commit's diff **with rename detection**, straight on libgit2's C API (via `LibGit2`).
///
/// Why not SwiftGitX (which the rest of `GitProvider` uses)? Rename pairing is
/// `git_diff_find_similar` applied to a live `git_diff`, and a SwiftGitX `Diff` can't be
/// post-processed: it materializes its deltas/patches eagerly in an `internal` initializer,
/// `Repository+diff.swift` frees the underlying `git_diff` in a `defer` before returning, and the
/// repository pointer is `internal` too — there is nothing left to run detection on. So the diff is
/// built here instead.
///
/// Without this a committed rename reads as delete-old + add-new, while `git show` on that same
/// commit shows ONE rename row (git's CLI defaults to `diff.renames=true`) — and jj, which pairs
/// renames natively, disagreed with our git read. Working-copy state was never affected:
/// `GitProvider.workingStatus` gets pairing from libgit2's `.renamesIndex`/`.renamesWorkingTree`
/// status options.
///
/// **Renames only, not copies** — `GIT_DIFF_FIND_RENAMES` at libgit2's default 50% threshold, which
/// is what git does by default; copies need an explicit `-C` there, so detecting them would diverge
/// from the CLI we're matching.
///
/// The diff basis is the **first parent** (`git show`'s own rule for a merge) and, for a root commit,
/// the empty tree — so an initial commit lists its files as added instead of coming back empty.
///
/// `nil` from either entry point means the read failed (unknown commit id, unreadable odb); the
/// caller must surface that, not treat it as "no changes". Every handle is freed with `defer`; no
/// pointer escapes.
enum GitCommitDiff {
  /// A commit's changed files plus its line totals, both measured on the rename-detected diff — so a
  /// pure rename contributes one row and zero lines, exactly as `git show --stat` reports it.
  struct Read: Equatable, Sendable {
    let files: [VCSChangedFile]
    let insertions: Int
    let deletions: Int
  }

  /// The changed-file list + line totals for one commit.
  static func read(root: URL, commitID: String) -> Read? {
    withDetectedDiff(root: root, commitID: commitID) { diff in
      var files: [VCSChangedFile] = []
      for index in 0..<git_diff_num_deltas(diff) {
        guard let delta = git_diff_get_delta(diff, index)?.pointee else { continue }
        files.append(changedFile(delta))
      }

      var stats: OpaquePointer?
      guard git_diff_get_stats(&stats, diff) == 0, let stats else { return nil }
      defer { git_diff_stats_free(stats) }

      return Read(
        files: files,
        insertions: Int(git_diff_stats_insertions(stats)),
        deletions: Int(git_diff_stats_deletions(stats)))
    }
  }

  /// One path's patch within a commit, as git-format unified-diff text — `git_patch_to_buf` prints
  /// git's own file headers, so a rename carries `similarity index` / `rename from` / `rename to`
  /// (which `UnifiedDiff.parse` reads into `renamedFrom`).
  ///
  /// Matches on either side of the delta, so the pre-move path finds a rename too. `""` (not `nil`)
  /// when the path simply isn't part of this commit.
  static func patch(root: URL, commitID: String, path: String) -> String? {
    withDetectedDiff(root: root, commitID: commitID) { diff in
      var match: Int?
      for index in 0..<git_diff_num_deltas(diff) {
        guard let delta = git_diff_get_delta(diff, index)?.pointee else { continue }
        if string(delta.new_file.path) == path || string(delta.old_file.path) == path {
          match = index
          break
        }
      }
      guard let match else { return "" }  // path unchanged in this commit

      var patch: OpaquePointer?
      guard git_patch_from_diff(&patch, diff, match) == 0, let patch else { return nil }
      defer { git_patch_free(patch) }

      var buf = git_buf()
      guard git_patch_to_buf(&buf, patch) == 0 else { return nil }
      defer { git_buf_dispose(&buf) }
      guard let text = buf.ptr else { return "" }
      return String(cString: text)
    }
  }

  // MARK: - Internals

  /// Build the commit's first-parent diff, run rename detection over it, then hand it to `body`.
  private static func withDetectedDiff<T>(
    root: URL, commitID: String, _ body: (OpaquePointer) -> T?
  ) -> T? {
    LibGit2.withRepository(root) { repo in
      guard var oid = LibGit2.oid(fromHex: commitID) else { return nil }
      var commit: OpaquePointer?
      guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { return nil }
      defer { git_commit_free(commit) }

      var newTree: OpaquePointer?
      guard git_commit_tree(&newTree, commit) == 0, let newTree else { return nil }
      defer { git_tree_free(newTree) }

      // A root commit has no parent, and `nil` here means the empty tree — every file added, which is
      // what `git show` prints for a first commit. `git_commit_tree` looks the tree up fresh, so it
      // outlives the parent handle freed at the end of this block.
      var oldTree: OpaquePointer?
      if git_commit_parentcount(commit) > 0 {
        var parent: OpaquePointer?
        guard git_commit_parent(&parent, commit, 0) == 0, let parent else { return nil }
        defer { git_commit_free(parent) }
        guard git_commit_tree(&oldTree, parent) == 0, oldTree != nil else { return nil }
      }
      defer { git_tree_free(oldTree) }

      var diff: OpaquePointer?
      guard git_diff_tree_to_tree(&diff, repo, oldTree, newTree, nil) == 0, let diff else {
        return nil
      }
      defer { git_diff_free(diff) }

      var find = git_diff_find_options()
      guard git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)) == 0
      else { return nil }
      find.flags = GIT_DIFF_FIND_RENAMES.rawValue
      guard git_diff_find_similar(diff, &find) == 0 else { return nil }

      return body(diff)
    }
  }

  /// Map one libgit2 delta to the app's changed-file row. `oldPath` is carried only for a pair
  /// (rename/copy), which is what the History row shows as "old → new"; for a delete libgit2 fills
  /// BOTH paths, so the row still names the deleted file.
  private static func changedFile(_ delta: git_diff_delta) -> VCSChangedFile {
    let newPath = string(delta.new_file.path)
    let oldPath = string(delta.old_file.path)
    let kind: VCSChangeKind =
      switch delta.status {
      case GIT_DELTA_ADDED: .added
      case GIT_DELTA_DELETED: .deleted
      case GIT_DELTA_MODIFIED: .modified
      case GIT_DELTA_RENAMED: .renamed
      case GIT_DELTA_COPIED: .copied
      case GIT_DELTA_CONFLICTED: .conflicted
      default: .other
      }
    let isPaired = delta.status == GIT_DELTA_RENAMED || delta.status == GIT_DELTA_COPIED
    return VCSChangedFile(
      path: newPath.isEmpty ? oldPath : newPath,
      oldPath: isPaired ? oldPath : nil,
      kind: kind)
  }

  private static func string(_ raw: UnsafePointer<CChar>?) -> String {
    guard let raw else { return "" }
    return String(cString: raw)
  }
}
