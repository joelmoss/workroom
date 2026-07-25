import Foundation
import libgit2

/// The app's owner of libgit2's global state and of raw `git_repository` handles — shared by the two
/// readers that go straight to the C API (`GitGraph` for reachability, `GitCommitDiff` for
/// rename-detected commit diffs). Everything else on the git side goes through SwiftGitX.
///
/// It exists so there is exactly ONE `git_libgit2_init` owner in the app: SwiftGitX initializes the
/// library inside `Repository.open` (`SwiftGitXRuntime.initialize()`), which a direct C caller can't
/// rely on having happened, so the raw readers need their own refcounted `+1` — but they should not
/// each keep one.
enum LibGit2 {
  /// The refcounted `+1`. Deliberately never paired with `git_libgit2_shutdown()`: the count must stay
  /// above zero for the app's lifetime, and tearing it down while SwiftGitX holds live repositories
  /// would pull the rug out from under them.
  private static let initialized: Bool = {
    git_libgit2_init() >= 0
  }()

  /// Open the repo, run `body`, always free the handle. Returns `nil` if libgit2 or the open failed.
  /// No pointer may escape `body`.
  static func withRepository<T>(_ root: URL, _ body: (OpaquePointer) -> T?) -> T? {
    guard initialized else { return nil }
    var repo: OpaquePointer?
    guard git_repository_open(&repo, root.path) == 0, let repo else { return nil }
    defer { git_repository_free(repo) }
    return body(repo)
  }

  static func oid(fromHex hex: String) -> git_oid? {
    var oid = git_oid()
    guard git_oid_fromstr(&oid, hex) == 0 else { return nil }
    return oid
  }

  static func hexString(_ oid: UnsafePointer<git_oid>) -> String {
    guard let raw = git_oid_tostr_s(oid) else { return "" }
    return String(cString: raw)
  }
}
