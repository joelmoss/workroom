import Foundation
import WrVcs

/// jj-backed `VCSProviding`, over the Rust core (`wr-vcs-core` → UniFFI `WrVcs`). Maps the generated
/// `WrVcs.*` types into the app-native models.
struct RustJJProvider: VCSProviding {
  func log(root: URL, limit: Int) throws -> VCSHistoryPage {
    let page: WrVcs.HistoryPage
    do {
      page = try WrVcs.logPage(root: root.path, limit: UInt32(max(0, limit)))
    } catch {
      throw Self.mapError(error)
    }
    return VCSHistoryPage(
      commits: page.commits.map(Self.map), reachedEnd: page.reachedEnd,
      pushScope: Self.map(page.pushScope))
  }

  func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
    // The jj-lib read + mapping is synchronous, blocking UniFFI work — run it on GCD (`runBlocking`),
    // never the fixed-width cooperative pool. Map to the (Sendable) app model inside the closure so no
    // non-Sendable `WrVcs.*` type crosses the boundary.
    //
    // The detail header's `+N −M` is summed from the SAME per-file counts that produced the rows
    // (`jj_backend::changed_files`), so the totals can't describe a different diff than the list. This
    // used to be a second read — `firstParentID` + `jj diff --stat`, two more `jj` processes per
    // History selection — anchored by hand to the first parent because `-r <commit>` stats a merge
    // against its auto-merged parents. The native counts are first-parent-anchored by construction.
    do {
      return try await runBlocking {
        let cs = try WrVcs.changeset(root: root.path, commitId: commitID)
        let stats = Self.lineTotals(cs.files)
        return VCSChangeset(
          commit: Self.map(cs.commit),
          fullMessage: cs.fullMessage,
          files: cs.files.map(Self.map),
          isMerge: cs.isMerge,
          insertions: stats.insertions,
          deletions: stats.deletions,
          pushScope: Self.map(cs.pushScope)
        )
      }
    } catch {
      throw Self.mapError(error)
    }
  }

  func currentRef(root: URL) async throws -> VCSRef {
    // Synchronous, blocking UniFFI read — GCD-offloaded so it never occupies a cooperative-pool
    // thread. Mapped to the Sendable `VCSRef` inside the closure.
    do {
      return try await runBlocking {
        let ref = try WrVcs.currentRef(root: root.path)
        return VCSRef(name: ref.name, kind: Self.map(ref.kind))
      }
    } catch {
      throw Self.mapError(error)
    }
  }

  /// The jj working-copy status via the native Rust core (jj-lib): snapshots `@` (so it reflects
  /// disk), then reads its change set, its per-file line counts and the CI branch — mapped to the
  /// app's `WorkroomStatus`. (The core also returns the parent `@-` state, no longer surfaced
  /// app-side.) Synchronous (blocking jj-lib work); the resolver runs it off-main under a timeout.
  ///
  /// `insertions`/`deletions` are summed from the same read as `changedFiles`, which is the point:
  /// they used to come from a separate `jj diff -r @ --stat` process in `WorkroomStatusResolver
  /// .resolveJJ`, so on a merge `@` they described the auto-merged-parents diff rather than the rows
  /// beside them, and an edit landing between the two reads skewed them.
  func workingStatus(root: URL) throws -> WorkroomStatus {
    let w: WrVcs.WorkingStatus
    do {
      w = try WrVcs.workingStatus(root: root.path)
    } catch {
      throw Self.mapError(error)
    }
    let workingCopy = Self.jjCommitChanges(w.workingCopy)
    let stats = Self.lineTotals(w.workingCopy.files)
    return WorkroomStatus(
      dirty: w.dirty, conflicted: w.conflicted, changedFiles: workingCopy.files,
      insertions: stats.insertions, deletions: stats.deletions,
      branchForCI: w.branchForCi, jjWorkingCopy: workingCopy)
  }

  /// Sum the per-file counts for a header total. A file the core declined to count — binary,
  /// oversized, or not a file — carries `nil` and contributes nothing, the same way git and jj both
  /// leave a binary out of a diffstat. All-`nil` therefore reads as `0`, not as "unknown": the rows
  /// exist and are known to contain no countable lines.
  private static func lineTotals(_ files: [WrVcs.ChangedFile]) -> (insertions: Int, deletions: Int)
  {
    files.reduce(into: (insertions: 0, deletions: 0)) { totals, f in
      totals.insertions += Int(f.insertions ?? 0)
      totals.deletions += Int(f.deletions ?? 0)
    }
  }

  /// The content of `path` at revision `rev` (a commit id or a revset like `@-`), for
  /// syntax-highlighting a diff's new side. jj-lib has no ergonomic file-content read, so this uses
  /// the `jj file show` CLI — read-only with `--ignore-working-copy`, so it never locks `@`. `nil` ⇒
  /// absent / empty / over the highlight cap (or the CLI erred) → the caller renders plain.
  func fileContent(root: URL, rev: String, path: String) async throws -> String? {
    let text: String
    do {
      text = try await Self.run(
        "jj", ["file", "show", "-r", rev, "--ignore-working-copy", "--", path], cwd: root)
    } catch {
      return nil  // path absent at rev / CLI error → no highlightable content (best-effort)
    }
    guard !text.isEmpty, text.utf8.count <= SyntaxLanguage.byteCap else { return nil }
    return text
  }

  /// Old-side content at the commit's parent, for highlighting deleted lines. Resolved to the FIRST
  /// parent's id rather than the `<commitID>-` revset, which errors on a merge (it resolves to >1
  /// revision) and left merge diffs with unhighlighted deletions — the same first-parent anchoring
  /// `fileDiff` uses, so the highlighted old side matches the patch's old side.
  func commitParentFileContent(root: URL, commitID: String, path: String) async throws -> String? {
    let rev = (try? await Self.firstParentID(root: root, rev: commitID)) ?? "\(commitID)-"
    return try await fileContent(root: root, rev: rev, path: path)
  }

  /// Old-side content for a working-copy diff base: `@-` (`.workingCopy`) or `@--` (`.parent`).
  func workingBaseFileContent(root: URL, base: VCSWorkingDiffBase, path: String) async throws
    -> String?
  {
    try await fileContent(root: root, rev: base == .parent ? "@--" : "@-", path: path)
  }

  func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
    // jj-lib exposes raw diff regions but no git-format writer (that lives in the jj CLI). Rather
    // than reimplement unified-diff formatting, use the jj CLI for the per-file patch text — the
    // plan's sanctioned CLI fallback for ops jj-lib doesn't expose ergonomically. `--git` gives the
    // git-format patch the UnifiedDiff parser wants; `--ignore-working-copy` never locks `@`.
    //
    // Anchored to the commit's FIRST parent for the same reason as `workingFileDiff`: `-r <merge>`
    // diffs against the auto-merged parents, so a History row for a merge commit renders "No changes"
    // for every file that differs only from the first parent — which is exactly what `changeset`
    // lists (`changed_files` diffs the first parent), and always the case for a conflicted file.
    let from = try? await Self.firstParentID(root: root, rev: commitID)
    return try await Self.run(
      "jj", Self.commitDiffArgs(commitID: commitID, path: path, from: from),
      cwd: root)
  }

  /// Pure `jj diff` args for a per-file COMMIT diff. `from` is the commit's first parent; `nil` falls
  /// back to `-r <commitID>` (identical for a single-parent commit). Always `--ignore-working-copy`:
  /// a committed diff must never take the working-copy lock.
  static func commitDiffArgs(commitID: String, path: String, from: String? = nil) -> [String] {
    guard let from else {
      return [
        "diff", "--git", "-r", commitID, "--ignore-working-copy", "--color", "never", "--", path,
      ]
    }
    return [
      "diff", "--git", "--from", from, "--to", commitID, "--ignore-working-copy", "--color",
      "never",
      "--", path,
    ]
  }

  /// Working-copy per-file diff, as git-format text (the `jj diff --git` sanctioned CLI fallback — jj
  /// has no non-CLI git-format writer; same as `fileDiff`). `.workingCopy` diffs `@` and MUST snapshot
  /// (no `--ignore-working-copy`) so it reflects on-disk edits; `.parent` diffs `@-` with
  /// `--ignore-working-copy` so it reuses the snapshot and never contends on the working-copy lock.
  /// The `.workingCopy` case is only ever reached through `DiffResolver.resolveWorking`'s
  /// `JJSnapshotGate`-gated path — it's the diff-side counterpart of `WorkroomStatusResolver
  /// .resolveJJ`'s gated snapshot, and shares the same per-project-root serialization.
  /// When `@` is a **merge**, `jj diff -r @` diffs it against its *auto-merged parents*, so any file
  /// that differs only from the FIRST parent reads as unchanged and the viewer renders "No changes" —
  /// even though the Changes panel lists it. The panel's list comes from `jj_backend::changed_files`,
  /// a tree diff against the first parent, so the two must share that base or rows dead-end. Every
  /// conflicted file hits this (a conflict IS the auto-merge result, so the diff is always empty), and
  /// so does an ordinary file arriving from the other side of a clean merge.
  ///
  /// `--from @- --to @` can't express it: on a merge `@-` resolves to several revisions and jj errors
  /// out. So resolve the first parent's commit id and diff from that — identical to `-r @` when `@`
  /// has one parent, correct when it has more.
  func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
    let from = base == .workingCopy ? try? await Self.firstParentID(root: root) : nil
    return try await Self.run(
      "jj", Self.workingDiffArgs(path: path, base: base, from: from), cwd: root)
  }

  /// `rev`'s FIRST parent commit id, or `nil` when it can't be read / has none (the caller then falls
  /// back to `-r <rev>`, which is correct for the common single-parent case). Read-only:
  /// `--ignore-working-copy`, so it neither snapshots nor takes the working-copy lock — a snapshot
  /// rewrites `@` but never changes its parents, so reading this before a diff's own snapshot is safe.
  static func firstParentID(root: URL, rev: String = "@") async throws -> String? {
    let out = try await run(
      "jj",
      [
        "log", "-r", rev, "--no-graph", "--ignore-working-copy", "--color", "never",
        "-T", #"parents.map(|c| c.commit_id()).join(" ")"#,
      ],
      cwd: root)
    return out.split(whereSeparator: { $0 == " " || $0.isNewline }).first.map(String.init)
  }

  /// Pure `jj diff` args for a working-copy file diff (unit-tested — the invariants are which rev and
  /// whether `--ignore-working-copy` is present, since that governs the working-copy lock).
  ///
  /// `from` is `@`'s first parent (see `workingFileDiff`); `nil` falls back to `-r @`.
  static func workingDiffArgs(path: String, base: VCSWorkingDiffBase, from: String? = nil)
    -> [String]
  {
    switch base {
    case .workingCopy:
      guard let from else {
        return ["diff", "--git", "-r", "@", "--color", "never", "--", path]
      }
      return ["diff", "--git", "--from", from, "--to", "@", "--color", "never", "--", path]
    case .parent:
      // `@-` has the same merge ambiguity, but this axis is unreachable from the UI (the Changes
      // panel dropped the jj parent group) — fix it the same way if it ever comes back.
      return ["diff", "--git", "-r", "@-", "--ignore-working-copy", "--color", "never", "--", path]
    }
  }

  /// Run a VCS CLI (`jj`), returning stdout — routed through `StatusCommandRunner` so it inherits that
  /// runner's hardening rather than re-implementing it:
  ///   - a `timeout` enforced by SIGTERM→(2s grace)→SIGKILL `killTree`, so a wedged `jj` (lock
  ///     contention, a child blocked on a dead socket) can't spin the diff pane forever;
  ///   - task-cancellation kill, so a superseded/cancelled read doesn't leave a `jj` process running;
  ///   - a bounded read (`maxBytes`, 4 MB) so a pathological single-file diff can't blow memory before
  ///     `DiffResolver`'s size gate rejects it;
  ///   - the app's full `ShellEnvironment.path()` (GUI apps get a minimal PATH — the same helper the
  ///     rest of the app uses, so `jj` resolves identically everywhere).
  ///
  /// The runner drains stdout/stderr concurrently on GCD global-queue threads, so this blocking work
  /// never touches the fixed-width Swift cooperative pool (the pool-starvation class documented on
  /// `runBlocking`). Non-zero exit / timeout throw `VCSError.io`.
  /// `runner` is injectable (default the real `StatusCommandRunner`) purely so
  /// `RustJJProviderRunTests` can prove the `signaled` branch below without spawning real jj.
  static func run(
    _ exe: String, _ args: [String], cwd: URL, timeout: TimeInterval = 30,
    runner: StatusCommandRunning = StatusCommandRunner()
  ) async throws -> String {
    let result = await runner.run(exe, args, in: cwd.path, timeout: timeout)
    if result.timedOut { throw VCSError.io("\(exe) timed out after \(Int(timeout))s") }
    // Checked before the generic exit-code guard: `result.exitCode` on a signalled result is the
    // SIGNAL number, not a real CLI exit status — "jj exited 9" is exactly the nonsense class the
    // gh-flap fix ended elsewhere, and this call site never learned that lesson.
    if result.signaled { throw VCSError.io("\(exe) was interrupted") }
    guard result.exitCode == 0 else {
      throw VCSError.io("\(exe) exited \(result.exitCode): \(result.stderr)")
    }
    return result.stdout
  }

  private static func map(_ c: WrVcs.Commit) -> VCSCommit {
    VCSCommit(
      commitID: c.commitId,
      shortID: c.shortId,
      changeID: c.changeId,
      summary: c.summary,
      body: c.body,
      authors: c.authors.map { VCSAuthor(name: $0.name, email: $0.email) },
      timestamp: Date(timeIntervalSince1970: Double(c.timestampMs) / 1000),
      refs: c.refs,
      parentIDs: c.parentIds,
      isWorkingCopy: c.isWorkingCopy,
      changeOffset: c.changeOffset.map(Int.init),
      divergentSiblings: c.divergentSiblings.map(Self.map),
      pushState: map(c.pushState),
      isRoot: c.isRoot
    )
  }

  private static func map(_ s: WrVcs.PushState) -> VCSPushState {
    switch s {
    case .pushed: return .pushed
    case .unpushed: return .unpushed
    case .unknown: return .unknown
    }
  }

  private static func map(_ s: WrVcs.PushScope?) -> VCSPushScope? {
    s.map { VCSPushScope(refName: $0.refName, count: Int($0.count)) }
  }

  private static func map(_ f: WrVcs.ChangedFile) -> VCSChangedFile {
    VCSChangedFile(path: f.path, oldPath: f.oldPath, kind: map(f.kind))
  }

  private static func map(_ k: WrVcs.ChangeKind) -> VCSChangeKind {
    switch k {
    case .added: return .added
    case .modified: return .modified
    case .deleted: return .deleted
    case .renamed: return .renamed
    case .copied: return .copied
    case .conflicted: return .conflicted
    case .other: return .other
    }
  }

  private static func map(_ k: WrVcs.RefKind) -> VCSRefKind {
    switch k {
    case .branch: return .branch
    case .ancestor: return .ancestor
    case .detached: return .detached
    case .none: return .none
    }
  }

  // MARK: - Working-status mapping (WrVcs → app JJ status models)

  private static func jjCommitChanges(_ c: WrVcs.CommitChanges) -> JJCommitChanges {
    JJCommitChanges(
      changeID: c.changeId, commitID: c.commitId, refs: c.refs, description: c.description,
      files: c.files.map(changedFile))
  }

  private static func changedFile(_ f: WrVcs.ChangedFile) -> ChangedFile {
    ChangedFile(path: f.path, change: statusChange(f.kind), oldPath: f.oldPath)
  }

  /// WrVcs change kind → the app's working-tree change kind (jj commits have no `untracked`).
  private static func statusChange(_ k: WrVcs.ChangeKind) -> ChangedFile.Change {
    switch k {
    case .added: return .added
    case .modified: return .modified
    case .deleted: return .deleted
    case .renamed, .copied: return .renamed
    case .conflicted: return .conflicted
    case .other: return .other
    }
  }

  /// Map the UniFFI `WrVcs.VcsError` onto the app's typed `VCSError`, case by case, so each backend
  /// failure reaches a distinct UI state (e.g. `.partialData` → "Repository changed — retry" rather
  /// than a generic io string). A non-`WrVcs.VcsError` (shouldn't occur across this surface) falls
  /// back to `.io`.
  private static func mapError(_ error: Error) -> VCSError {
    guard let e = error as? WrVcs.VcsError else { return .io("\(error)") }
    switch e {
    case .UnsupportedRepo(let reason): return .unsupportedRepo(reason)
    case .NotFound(let what): return .notFound(what)
    case .LockContention: return .lockContention
    case .StaleSnapshot: return .staleSnapshot
    case .PartialData(let detail): return .partialData(detail)
    case .BackendVersion(let detail): return .backendVersion(detail)
    case .Io(let message): return .io(message)
    }
  }
}
