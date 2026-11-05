import Foundation
import libgit2

/// `git diff HEAD --shortstat` for a working tree — the `+N −M` behind the sidebar/Changes badges —
/// read straight on libgit2's C API.
///
/// **Why not SwiftGitX**, which the rest of `GitProvider` uses? Its `Diff` is EAGER. `Diff.init` walks
/// every delta, builds a `Patch` for each (`git_patch_from_diff`), and materializes every hunk line into
/// a Swift `String` before the caller ever sees the value. Deriving two integers from that costs one
/// `String` plus a `Hunk.Line` struct per changed line of the WHOLE worktree, on every status refresh
/// (focus, appear, manual) — for a cosmetic count. libgit2's own `git_diff_get_stats` does the same
/// count in C and allocates nothing on the Swift side. SwiftGitX surfaces no stats API and keeps its
/// `git_repository` pointer `internal`, so we open our own handle (see `LibGit2`) — the third raw
/// reader, alongside `GitGraph` (reachability) and `GitCommitDiff` (rename-detected commit diffs).
///
/// The diff itself is irreducible — a line count cannot be answered without one, which is exactly what
/// `git diff --shortstat` costs too. What this removes is the Swift-side materialization on top of it.
///
/// **Renames.** `git_diff_find_similar` runs over the diff before it is counted, with NULL options so
/// the repo's own `diff.renames`/`diff.renamelimit` decide — the same pairing the file list built
/// beside it already gets from libgit2's `.renamesIndex`/`.renamesWorkingTree` status options. Without
/// it the two halves of `GitProvider.workingStatus` disagreed: `git mv big.txt moved.txt && git add -A`
/// on a 500-line file gave ONE row badged "renamed" carrying `+500 −500`, because the stat diff still
/// had it as a delete plus an add. `git diff HEAD --shortstat` says `0 insertions(+), 0 deletions(-)`.
///
/// **Parity.** `git_patch_line_stats` skips the EOFNL marker lines (`\ No newline at end of file`)
/// because, in libgit2's own words, "diff --stat and --numstat don't count EOFNL marks because they will
/// always be paired with a ADDITION or DELETION line". Verified against git: changing only a file's
/// trailing newline is `1 insertion(+), 1 deletion(-)`. The hand-rolled Swift sum this replaced counted
/// those markers as real lines, so it over-reported by one on such a file. `GitCommitDiff` gets this
/// right for free, being the same C call on a commit's diff.
enum GitDiffStats {
  /// `(insertions, deletions)` for `git diff HEAD`: staged + unstaged changes to tracked files, with
  /// untracked files excluded and renames paired — the same scoping AND the same rename detection as
  /// git's own `--shortstat HEAD` (see the type doc for why the pairing has to be asked for).
  ///
  /// `nil` means the read failed (not a repo, damaged odb) and the caller should report no count;
  /// `(0, 0)` is the honest answer for a clean tree. An unborn HEAD (a repo with no commits yet) diffs
  /// against the empty tree — a NULL `git_tree *` is how libgit2 spells that — so a fresh repo's staged
  /// files count as insertions. git itself has no answer to compare against there (`git diff HEAD` is
  /// fatal without a HEAD); counting from the empty tree is the same choice SwiftGitX made, kept so the
  /// badge doesn't go blank on a just-initialized project.
  static func workingTree(root: URL) -> (insertions: Int, deletions: Int)? {
    LibGit2.withRepository(root) { repo in
      // NULL tree on unborn HEAD (see above); libgit2's free functions tolerate NULL.
      let tree = headTree(repo)
      defer { git_object_free(tree) }

      var diff: OpaquePointer?
      // `git diff HEAD` is HEAD-tree → worktree *with* the index folded in, which is the one form that
      // sees a staged-then-further-modified file as a single change rather than one side of it.
      let diffCode = git_diff_tree_to_workdir_with_index(&diff, repo, tree, nil)
      guard diffCode == 0, let diff else {
        LibGit2.reportFailure("git_diff_tree_to_workdir_with_index(\(root.path))", code: diffCode)
        return nil
      }
      defer { git_diff_free(diff) }

      // Pair renames BEFORE counting, or a moved file is a delete plus an add and its entire content
      // lands in the totals. NULL options is what makes libgit2 read the repo's `diff.renames` config
      // (its `normalize_find_opts` consults config only when the caller sets no `GIT_DIFF_FIND_*`
      // bit), so this obeys exactly the switch the CLI obeys. Allocates nothing the caller must free.
      let findCode = git_diff_find_similar(diff, nil)
      guard findCode == 0 else {
        LibGit2.reportFailure("git_diff_find_similar(\(root.path))", code: findCode)
        return nil
      }

      var stats: OpaquePointer?
      let statsCode = git_diff_get_stats(&stats, diff)
      guard statsCode == 0, let stats else {
        LibGit2.reportFailure("git_diff_get_stats(\(root.path))", code: statsCode)
        return nil
      }
      defer { git_diff_stats_free(stats) }

      return (Int(git_diff_stats_insertions(stats)), Int(git_diff_stats_deletions(stats)))
    }
  }

  /// HEAD's tree, or `nil` when there is nothing to peel — an unborn branch (`GIT_EUNBORNBRANCH`, a repo
  /// with no commits) or a HEAD pointing at a missing object. Both mean "diff against the empty tree",
  /// which is a documented degrade rather than a failure, so neither is reported to `LibGit2`.
  private static func headTree(_ repo: OpaquePointer) -> OpaquePointer? {
    var head: OpaquePointer?
    guard git_repository_head(&head, repo) == 0, let head else { return nil }
    defer { git_reference_free(head) }
    var tree: OpaquePointer?
    guard git_reference_peel(&tree, head, GIT_OBJECT_TREE) == 0 else { return nil }
    return tree
  }
}
