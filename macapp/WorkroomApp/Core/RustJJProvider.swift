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
    return VCSHistoryPage(commits: page.commits.map(Self.map), reachedEnd: page.reachedEnd)
  }

  func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
    let cs: WrVcs.Changeset
    do {
      cs = try WrVcs.changeset(root: root.path, commitId: commitID)
    } catch {
      throw Self.mapError(error)
    }
    // Line counts for the detail header: the native changeset read omits the diffstat (a line count
    // would materialize every file), so — jayjay-style, like `WorkroomStatusResolver.resolveJJ` — one
    // read-only `jj diff --stat` fills it. `--ignore-working-copy` never locks `@`. Best-effort: a
    // failure leaves the counts nil and the header just omits the summary.
    var insertions: Int?
    var deletions: Int?
    if let stat = try? await Self.run(
      "jj",
      ["diff", "-r", commitID, "--ignore-working-copy", "--stat", "--color", "never"],
      cwd: root
    ) {
      let parsed = WorkroomStatusResolver.parseDiffStat(stat)
      (insertions, deletions) = (parsed.insertions, parsed.deletions)
    }
    return VCSChangeset(
      commit: Self.map(cs.commit),
      fullMessage: cs.fullMessage,
      files: cs.files.map(Self.map),
      isMerge: cs.isMerge,
      insertions: insertions,
      deletions: deletions
    )
  }

  func currentRef(root: URL) async throws -> VCSRef {
    let ref: WrVcs.Ref
    do {
      ref = try WrVcs.currentRef(root: root.path)
    } catch {
      throw Self.mapError(error)
    }
    return VCSRef(name: ref.name, kind: Self.map(ref.kind))
  }

  /// The jj working-copy status via the native Rust core (jj-lib): snapshots `@` (so it reflects
  /// disk), then reads its change set and the CI branch — mapped to the app's `WorkroomStatus`. (The
  /// core also returns the parent `@-` state, no longer surfaced app-side.) `insertions`/`deletions`
  /// are left nil here; `WorkroomStatusResolver.resolveJJ`
  /// fills them from one `jj diff --stat` (jayjay-style — a native line count would materialize every
  /// file). Synchronous (blocking jj-lib work); the resolver runs it off-main under a timeout.
  func workingStatus(root: URL) throws -> WorkroomStatus {
    let w: WrVcs.WorkingStatus
    do {
      w = try WrVcs.workingStatus(root: root.path)
    } catch {
      throw Self.mapError(error)
    }
    let workingCopy = Self.jjCommitChanges(w.workingCopy)
    return WorkroomStatus(
      dirty: w.dirty, conflicted: w.conflicted, changedFiles: workingCopy.files,
      branchForCI: w.branchForCi, jjWorkingCopy: workingCopy)
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

  /// Old-side content at the commit's parent (`<commitID>-`), for highlighting deleted lines. A
  /// merge (`X-` resolves to >1 revision) makes `jj file show` error → `fileContent` returns nil.
  func commitParentFileContent(root: URL, commitID: String, path: String) async throws -> String? {
    try await fileContent(root: root, rev: "\(commitID)-", path: path)
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
    try await Self.run(
      "jj",
      ["diff", "--git", "-r", commitID, "--ignore-working-copy", "--color", "never", "--", path],
      cwd: root
    )
  }

  /// Working-copy per-file diff, as git-format text (the `jj diff --git` sanctioned CLI fallback — jj
  /// has no non-CLI git-format writer; same as `fileDiff`). `.workingCopy` diffs `@` and MUST snapshot
  /// (no `--ignore-working-copy`) so it reflects on-disk edits; `.parent` diffs `@-` with
  /// `--ignore-working-copy` so it reuses the snapshot and never contends on the working-copy lock.
  func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
    try await Self.run("jj", Self.workingDiffArgs(path: path, base: base), cwd: root)
  }

  /// Pure `jj diff` args for a working-copy file diff (unit-tested — the invariant is which rev and
  /// whether `--ignore-working-copy` is present, since that governs the working-copy lock).
  static func workingDiffArgs(path: String, base: VCSWorkingDiffBase) -> [String] {
    switch base {
    case .workingCopy:
      return ["diff", "--git", "-r", "@", "--color", "never", "--", path]
    case .parent:
      return ["diff", "--git", "-r", "@-", "--ignore-working-copy", "--color", "never", "--", path]
    }
  }

  /// Run a VCS CLI (via `/usr/bin/env` so PATH lookup works), returning stdout. GUI apps get a
  /// minimal PATH, so prepend the common Homebrew / local locations where `jj` lives.
  ///
  /// The entire blocking `Process` lifecycle (`run` + the pipe reads + `waitUntilExit`) runs on a
  /// GCD global-queue thread, NEVER on the Swift cooperative thread pool. `readDataToEndOfFile()` and
  /// `waitUntilExit()` park their thread until the child exits; parking a cooperative-pool thread
  /// (what a bare `Task.detached` uses) starves the pool. With a few concurrent VCS reads in flight
  /// (several windows polling status/branch + a diff load *and* its syntax-highlight `fileContent`
  /// fetch), every cooperative thread ends up parked in a read, this call's own reads can't be
  /// scheduled, its `jj` child fills its >64 KB stdout pipe with no reader, blocks on the write, and
  /// never exits — the read never reaches EOF and the diff pane spins forever. GCD global-queue
  /// threads exist precisely to be blocked, so the work goes there and the cooperative pool stays free.
  private static func run(_ exe: String, _ args: [String], cwd: URL) async throws -> String {
    var env = ProcessInfo.processInfo.environment
    let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
    env["GIT_OPTIONAL_LOCKS"] = "0"
    let fullArgs = [exe] + args
    let cwdURL = cwd

    return try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<String, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        // Build the process here (off the cooperative pool) so nothing non-Sendable crosses the
        // continuation boundary.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = fullArgs
        proc.currentDirectoryURL = cwdURL
        proc.environment = env
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
          try proc.run()
        } catch {
          cont.resume(throwing: VCSError.io("failed to spawn \(exe): \(error)"))
          return
        }
        // Drain stdout AND stderr concurrently before waiting. Each pipe has a bounded OS buffer
        // (~64 KB); reading only stdout while the child fills stderr (a verbose `jj` warning, an
        // error dump) blocks the child on its stderr write while we block on stdout → deadlock.
        // Two GCD reads can't deadlock, and — unlike detached Tasks — don't touch the cooperative pool.
        let box = OutputBox()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
          box.out = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
          box.err = err.fileHandleForReading.readDataToEndOfFile()
        }
        group.wait()  // both pipes drained to EOF (barrier: box is safe to read after this)
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
          let stderr = String(data: box.err, encoding: .utf8) ?? ""
          cont.resume(throwing: VCSError.io("\(exe) exited \(proc.terminationStatus): \(stderr)"))
          return
        }
        cont.resume(returning: String(data: box.out, encoding: .utf8) ?? "")
      }
    }
  }

  /// Mutable capture for the two concurrent pipe reads. `@unchecked Sendable` because the
  /// `DispatchGroup` barrier (`group.wait()`) establishes the happens-before that makes the writes
  /// visible before either field is read.
  private final class OutputBox: @unchecked Sendable {
    var out = Data()
    var err = Data()
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
      isWorkingCopy: c.isWorkingCopy
    )
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
    ChangedFile(path: f.path, change: statusChange(f.kind))
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

  /// The UniFFI surface throws `WrVcs.VcsError`; stringify for now (a precise case-by-case mapping to
  /// `VCSError` lands with the error-taxonomy work).
  private static func mapError(_ error: Error) -> VCSError {
    .io("\(error)")
  }
}
