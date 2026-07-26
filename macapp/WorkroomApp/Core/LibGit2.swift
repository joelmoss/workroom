import Foundation
import libgit2
import os

/// The app's owner of libgit2's global state and of raw `git_repository` handles — shared by the three
/// readers that go straight to the C API (`GitGraph` for reachability, `GitCommitDiff` for
/// rename-detected commit diffs, `GitDiffStats` for working-tree line counts). Those three plus this
/// file are the ONLY four in the app touching raw libgit2; everything else on the git side goes
/// through SwiftGitX.
///
/// It exists so there is exactly ONE `git_libgit2_init` owner in the app: SwiftGitX initializes the
/// library inside `Repository.open` (`SwiftGitXRuntime.initialize()`), which a direct C caller can't
/// rely on having happened, so the raw readers need their own refcounted `+1` — but they should not
/// each keep one.
///
/// It also owns the layer's **diagnostics** (`lastError`/`reportFailure`). A raw reader can only
/// answer `nil`, and `GitProvider` flattens every `nil` into one `VCSError.io` string — so without
/// `git_error_last` a bad oid, a missing object, a corrupt pack and an odb I/O failure are
/// indistinguishable in a bug report. See `reportFailure`.
enum LibGit2 {
  /// The refcounted `+1`. Deliberately never paired with `git_libgit2_shutdown()`: the count must stay
  /// above zero for the app's lifetime, and tearing it down while SwiftGitX holds live repositories
  /// would pull the rug out from under them.
  private static let initialized: Bool = {
    git_libgit2_init() >= 0
  }()

  private static let log = Logger(subsystem: "com.developwithstyle.workroom", category: "libgit2")

  /// Open the repo, run `body`, always free the handle. Returns `nil` if libgit2 or the open failed.
  /// No pointer may escape `body`.
  static func withRepository<T>(_ root: URL, _ body: (OpaquePointer) -> T?) -> T? {
    guard initialized else {
      log.error("git_libgit2_init failed; the raw libgit2 readers are unavailable")
      return nil
    }
    var repo: OpaquePointer?
    let code = git_repository_open(&repo, root.path)
    guard code == 0, let repo else {
      reportFailure("git_repository_open(\(root.path))", code: code)
      return nil
    }
    defer { git_repository_free(repo) }
    return body(repo)
  }

  static func oid(fromHex hex: String) -> git_oid? {
    var oid = git_oid()
    let code = git_oid_fromstr(&oid, hex)
    guard code == 0 else {
      reportFailure("git_oid_fromstr(\(hex))", code: code)
      return nil
    }
    return oid
  }

  static func hexString(_ oid: UnsafePointer<git_oid>) -> String {
    guard let raw = git_oid_tostr_s(oid) else { return "" }
    return String(cString: raw)
  }

  // MARK: - Diagnostics

  /// libgit2's own message for the call that JUST failed, or `nil` when it left none.
  ///
  /// Read it immediately after the non-zero return code and nowhere else. `git_error_last` is a
  /// per-thread singleton that the very next libgit2 call overwrites — including a `git_*_free` fired
  /// from a `defer` — so a message read even one call late describes something else; and after a call
  /// that SUCCEEDED it still holds whatever failed before it, which is why a return code, never this,
  /// is what decides that there was an error at all. libgit2 owns the buffer (never freed here); the
  /// `String` is a copy, so nothing dangles once the next call clobbers it.
  static func lastError() -> String? {
    guard let raw = git_error_last()?.pointee.message else { return nil }
    let message = String(cString: raw)
    return message.isEmpty ? nil : message
  }

  /// Record a failed libgit2 call, so the flat `VCSError.io` a user reports back is diagnosable.
  ///
  /// The raw readers can only answer `nil`, and their callers turn every `nil` into the SAME string
  /// ("could not read the diff for <sha>") — a bad oid, an object missing from the odb, a corrupt pack
  /// and an odb I/O failure all arrive looking identical. The detail that separates them exists only
  /// in `git_error_last`, so it goes here: `log stream --predicate 'category == "libgit2"'` (or
  /// Console.app) then names the exact call, its code, and libgit2's reason for it.
  ///
  /// Failure paths only — `lastError()` is meaningless anywhere else, and this is the one place in the
  /// layer that pays for a `String`. `operation` is logged `.public` (it carries the repo path / oid /
  /// file path that make the line worth having); these logs stay on the device.
  static func reportFailure(_ operation: String, code: Int32) {
    let reason = lastError() ?? "no libgit2 message"
    log.error("\(operation, privacy: .public) failed (\(code)): \(reason, privacy: .public)")
  }
}
