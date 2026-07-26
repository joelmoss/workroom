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
/// **Detection is the repo's config, not ours.** `git_diff_find_similar` is passed NULL options,
/// which is the one form that makes libgit2 read `diff.renames` (and `diff.renamelimit`) from the
/// repo: `normalize_find_opts` consults config only when the caller set no `GIT_DIFF_FIND_*` bit.
/// Spelling `GIT_DIFF_FIND_RENAMES` out — which this used to do — silently overrode the user:
/// `diff.renames=false` still got renames the CLI would not pair, and `diff.renames=copies` lost its
/// copies. So `GIT_DELTA_COPIED` is genuinely reachable here, for the repos that ask for it.
///
/// **Type changes stay one row.** The diff is built with `GIT_DIFF_INCLUDE_TYPECHANGE`; without it
/// libgit2 splits a file↔symlink or file↔submodule change into DELETED + ADDED *for the same path* —
/// and `VCSChangedFile.id` IS the path, so the History file list gets two rows sharing one id and its
/// `ForEach` over `Identifiable` breaks. (The two halves can't be re-paired into a rename from a path
/// to itself: `is_rename_source`/`is_rename_target` both require a plain-blob mode, and exactly one
/// side of a type change has one. The duplicate id is the whole of the damage.) git reports the same
/// change as a single entry too — `T` in `git diff --raw`.
///
/// The diff basis is the **first parent** (`git show`'s own rule for a merge) and, for a root commit,
/// the empty tree — so an initial commit lists its files as added instead of coming back empty. The
/// oldest commit of a shallow/partial clone takes the same empty-tree path: it names a parent whose
/// object the odb does not have, and a history boundary is not a failure.
///
/// `nil` from either entry point means the read failed (unknown commit id, unreadable odb); the
/// caller must surface that, not treat it as "no changes". Because the caller can only flatten it
/// into one `VCSError.io` string, every failure path also hands libgit2's own reason to
/// `LibGit2.reportFailure`. Every handle is freed with `defer`; no pointer escapes.
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
      let statsCode = git_diff_get_stats(&stats, diff)
      guard statsCode == 0, let stats else {
        LibGit2.reportFailure("git_diff_get_stats(\(commitID))", code: statsCode)
        return nil
      }
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
      let patchCode = git_patch_from_diff(&patch, diff, match)
      guard patchCode == 0, let patch else {
        LibGit2.reportFailure("git_patch_from_diff(\(path) in \(commitID))", code: patchCode)
        return nil
      }
      defer { git_patch_free(patch) }

      var buf = git_buf()
      // The `defer` deliberately sits AFTER the guard: on failure libgit2's `git_buf_tostr` has
      // already moved this (still empty) buffer's storage into its own scratch `git_str` and disposed
      // that, leaving `buf.ptr` at the library's static empty string — nothing to free, and nothing
      // leaked by the early return.
      let bufCode = git_patch_to_buf(&buf, patch)
      guard bufCode == 0 else {
        LibGit2.reportFailure("git_patch_to_buf(\(path) in \(commitID))", code: bufCode)
        return nil
      }
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
      let lookupCode = git_commit_lookup(&commit, repo, &oid)
      guard lookupCode == 0, let commit else {
        LibGit2.reportFailure("git_commit_lookup(\(commitID))", code: lookupCode)
        return nil
      }
      defer { git_commit_free(commit) }

      var newTree: OpaquePointer?
      let newTreeCode = git_commit_tree(&newTree, commit)
      guard newTreeCode == 0, let newTree else {
        LibGit2.reportFailure("git_commit_tree(\(commitID))", code: newTreeCode)
        return nil
      }
      defer { git_tree_free(newTree) }

      // A root commit has no parent, and `nil` here means the empty tree — every file added, which is
      // what `git show` prints for a first commit. `git_commit_tree` looks the tree up fresh, so it
      // outlives the parent handle freed at the end of this block.
      var oldTree: OpaquePointer?
      if git_commit_parentcount(commit) > 0 {
        var parent: OpaquePointer?
        let parentCode = git_commit_parent(&parent, commit, 0)
        // `GIT_ENOTFOUND` means the commit names a first parent whose object this odb doesn't hold —
        // a history boundary, not a failure. git diffs a shallow boundary commit against the empty
        // tree, so leave `oldTree` NULL and do the same: History lists the oldest row's files as
        // added instead of erroring out. (A well-formed shallow clone rarely gets this far: libgit2
        // reads `.git/shallow` as grafts when the repo is opened and rewrites the boundary commit to
        // zero parents, which takes the root-commit path above. This covers a missing or stale
        // `.git/shallow`, a partial clone, and a pruned odb.) Logged either way — for the pruned-odb
        // case it's the only diagnosis, and for the boundary it explains an all-added row. Any OTHER
        // code is an outright read failure and is NOT swallowed.
        if parentCode != 0 {
          LibGit2.reportFailure("git_commit_parent(\(commitID))", code: parentCode)
          guard parentCode == GIT_ENOTFOUND.rawValue else { return nil }
        }
        if let parent {
          defer { git_commit_free(parent) }
          let oldTreeCode = git_commit_tree(&oldTree, parent)
          guard oldTreeCode == 0, oldTree != nil else {
            // Nothing was written to `oldTree` on failure, so the `defer` below has nothing to free.
            LibGit2.reportFailure("git_commit_tree(parent of \(commitID))", code: oldTreeCode)
            return nil
          }
        }
      }
      defer { git_tree_free(oldTree) }

      // `GIT_DIFF_INCLUDE_TYPECHANGE` — see the type doc: without it a file↔symlink change arrives as
      // two deltas sharing one path, i.e. two rows with the same `Identifiable` id. Everything else
      // stays libgit2's default (`git_diff_options_init`).
      var options = git_diff_options()
      let optionsCode = git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
      guard optionsCode == 0 else {
        LibGit2.reportFailure("git_diff_options_init", code: optionsCode)
        return nil
      }
      options.flags = GIT_DIFF_INCLUDE_TYPECHANGE.rawValue

      var diff: OpaquePointer?
      let diffCode = git_diff_tree_to_tree(&diff, repo, oldTree, newTree, &options)
      guard diffCode == 0, let diff else {
        LibGit2.reportFailure("git_diff_tree_to_tree(\(commitID))", code: diffCode)
        return nil
      }
      defer { git_diff_free(diff) }

      // NULL find-options, deliberately: that is the ONLY form under which libgit2 reads the repo's
      // `diff.renames`/`diff.renamelimit` config (see the type doc). It allocates nothing the caller
      // must free.
      let findCode = git_diff_find_similar(diff, nil)
      guard findCode == 0 else {
        LibGit2.reportFailure("git_diff_find_similar(\(commitID))", code: findCode)
        return nil
      }

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
      // `VCSChangeKind` has no type-change case (jj doesn't surface one either), and `.other` renders
      // as a featureless "•" — a file that became a symlink would look like something the app failed
      // to classify. `.modified` is the honest approximation (one path, changed content) and it's
      // already what the working-copy side does: `GitProvider.change` folds SwiftGitX's `.typeChange`
      // into `.modified` too, so both halves of the app agree. Give this its own case if the badges
      // ever grow git's `T`.
      case GIT_DELTA_TYPECHANGE: .modified
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
