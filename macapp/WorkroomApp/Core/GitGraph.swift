import Foundation
import libgit2

/// Reachability reads against a git repo's `origin` refs, straight on libgit2's C API (one of only two
/// readers that do — see `GitCommitDiff` for the other; both open their handles through `LibGit2`).
///
/// Why not SwiftGitX (which the rest of `GitProvider` uses)? It cannot express a commit RANGE: its
/// `CommitSequence` only calls `git_revwalk_push` and never `git_revwalk_hide`, it surfaces no
/// merge-base/graph helper, and it keeps its own `git_repository` pointer `internal` so we can't borrow
/// one. "Which of these commits aren't on origin yet" is exactly `HEAD --not <origin tips>`, so we open
/// our own handle and ask libgit2 directly. Every handle is freed with `defer`; no pointer escapes.
///
/// **Semantics.** `origin` only, deliberately: a commit sitting on some other remote (a backup, a fork)
/// is not on the project's shared repo, and that's what the badge claims. `nil` from either entry point
/// means "couldn't answer" — no origin refs, or a read failed — and the caller must then report
/// `.unknown` for EVERY row rather than a partial answer. Skipping one unreadable tip would be worse
/// than useless: if that tip was the only one containing a commit, the commit would be badged
/// "unpushed" when it isn't.
enum GitGraph {
  /// What a push-state read was measured against, for tooltip copy. `refName` is set only when origin
  /// has exactly one branch, so the UI can name it ("not on origin/main") instead of counting.
  struct Scope: Equatable, Sendable {
    let refName: String?
    let count: Int
  }

  /// The result of a page read: the commits from `decide` that are NOT reachable from origin, plus the
  /// comparison scope.
  struct PageRead: Equatable, Sendable {
    let unpushed: Set<String>
    let scope: Scope
  }

  /// Which of `decide` are unreachable from any `origin` tip — i.e. `git rev-list HEAD --not
  /// <origin tips>` intersected with the page. `nil` ⇒ unanswerable (see the type doc).
  ///
  /// The walk stops as soon as every id in `decide` has been seen, which is what keeps the pathological
  /// case cheap: when NO origin tip intersects local history, hiding removes nothing and the raw walk
  /// would enumerate all of history — but then every page commit is unpushed, so they're all found in
  /// the first `decide.count` steps and we quit. Ids never yielded before the walk ends are reachable
  /// from origin, hence pushed.
  static func unpushed(root: URL, decide: Set<String>) -> PageRead? {
    LibGit2.withRepository(root) { repo in
      guard let tips = originTips(repo), !tips.isEmpty else { return nil }
      guard var head = resolve("HEAD", in: repo) else { return nil }

      var walk: OpaquePointer?
      guard git_revwalk_new(&walk, repo) == 0, let walk else { return nil }
      defer { git_revwalk_free(walk) }
      guard git_revwalk_push(walk, &head) == 0 else { return nil }
      for tip in tips {
        var oid = tip.oid
        // A tip we can't hide (pruned object, a ref pointing at a non-commit) invalidates the whole
        // read — see the type doc on why skipping it would produce a FALSE "unpushed".
        guard git_revwalk_hide(walk, &oid) == 0 else { return nil }
      }

      var found: Set<String> = []
      var oid = git_oid()
      while found.count < decide.count {
        let status = git_revwalk_next(&oid, walk)
        if status == GIT_ITEROVER.rawValue { break }
        // Any OTHER failure mid-walk (corrupt object in the odb) has to invalidate the read: the ids we
        // haven't yielded yet would otherwise be reported "pushed" purely because the walk stopped.
        guard status == 0 else { return nil }
        let hex = LibGit2.hexString(&oid)
        if decide.contains(hex) { found.insert(hex) }
      }
      return PageRead(unpushed: found, scope: scope(of: tips))
    }
  }

  /// Whether one arbitrary commit is reachable from any `origin` tip — the single-commit form for the
  /// changeset detail, where there's no page to bound a walk with. `nil` ⇒ unanswerable.
  static func isPushed(root: URL, commitID: String) -> (pushed: Bool, scope: Scope)? {
    LibGit2.withRepository(root) { repo in
      guard let tips = originTips(repo), !tips.isEmpty else { return nil }
      guard var oid = LibGit2.oid(fromHex: commitID) else { return nil }
      let oids = tips.map(\.oid)
      let status = oids.withUnsafeBufferPointer { buf in
        git_graph_reachable_from_any(repo, &oid, buf.baseAddress, buf.count)
      }
      // 1 = reachable, 0 = not, negative = error (unknown object, corrupt odb) ⇒ unanswerable.
      guard status >= 0 else { return nil }
      return (status == 1, scope(of: tips))
    }
  }

  // MARK: - Internals

  private struct Tip {
    let name: String
    let oid: git_oid
  }

  /// Every `refs/remotes/origin/*` tip, resolved to a commit id. `nil` on an iteration failure (damaged
  /// refs) — distinct from an empty list (no origin), though both end up `.unknown` at the caller.
  ///
  /// `refs/remotes/origin/HEAD` is skipped: it's symbolic and resolves to another origin branch already
  /// in this list, so it would double a tip and put a meaningless "origin/HEAD" in the tooltip.
  private static func originTips(_ repo: OpaquePointer) -> [Tip]? {
    // `git_reference_iterator` is a complete type in the headers (unlike the opaque repo/revwalk/ref
    // handles), so Swift types it as a concrete pointer rather than `OpaquePointer`.
    var iter: UnsafeMutablePointer<git_reference_iterator>?
    guard git_reference_iterator_glob_new(&iter, repo, "refs/remotes/origin/*") == 0, let iter
    else { return nil }
    defer { git_reference_iterator_free(iter) }

    var tips: [Tip] = []
    var ref: OpaquePointer?
    while true {
      let status = git_reference_next(&ref, iter)
      if status == GIT_ITEROVER.rawValue { break }
      guard status == 0, let ref else { return nil }
      defer { git_reference_free(ref) }
      guard let raw = git_reference_name(ref) else { return nil }
      let name = String(cString: raw)
      if name == "refs/remotes/origin/HEAD" { continue }
      // `name_to_id` resolves symbolic refs, so this is the ref's commit either way.
      guard var oid = resolve(name, in: repo) else { return nil }
      // The ref resolving is not enough — it can name an object that isn't in the odb (a ref written by
      // hand, a pruned pack). `git_revwalk_hide` accepts such an oid without complaint and the walk then
      // just ends early, which would silently report unpushed commits as pushed. So prove each tip is a
      // real commit up front, and fail the WHOLE read if one isn't.
      var commit: OpaquePointer?
      guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { return nil }
      git_commit_free(commit)
      tips.append(Tip(name: shortName(name), oid: oid))
    }
    return tips
  }

  private static func scope(of tips: [Tip]) -> Scope {
    Scope(refName: tips.count == 1 ? tips[0].name : nil, count: tips.count)
  }

  /// `refs/remotes/origin/main` → `origin/main`, the form git itself prints.
  private static func shortName(_ fullName: String) -> String {
    let prefix = "refs/remotes/"
    return fullName.hasPrefix(prefix) ? String(fullName.dropFirst(prefix.count)) : fullName
  }

  private static func resolve(_ refName: String, in repo: OpaquePointer) -> git_oid? {
    var oid = git_oid()
    guard git_reference_name_to_id(&oid, repo, refName) == 0 else { return nil }
    return oid
  }
}
