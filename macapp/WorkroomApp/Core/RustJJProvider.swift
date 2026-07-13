import Foundation
import WrVcs

/// jj-backed `VCSProviding`, over the Rust core (`wr-vcs-core` → UniFFI `WrVcs`). Maps the generated
/// `WrVcs.*` types into the app-native models.
struct RustJJProvider: VCSProviding {
  func log(root: URL, limit: Int) async throws -> VCSHistoryPage {
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
    return VCSChangeset(
      commit: Self.map(cs.commit),
      fullMessage: cs.fullMessage,
      files: cs.files.map(Self.map),
      isMerge: cs.isMerge
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

  /// Run a VCS CLI (via `/usr/bin/env` so PATH lookup works), returning stdout. GUI apps get a
  /// minimal PATH, so prepend the common Homebrew / local locations where `jj` lives.
  private static func run(_ exe: String, _ args: [String], cwd: URL) async throws -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = [exe] + args
    proc.currentDirectoryURL = cwd
    var env = ProcessInfo.processInfo.environment
    let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
    env["GIT_OPTIONAL_LOCKS"] = "0"
    proc.environment = env

    let out = Pipe()
    let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    do {
      try proc.run()
    } catch {
      throw VCSError.io("failed to spawn \(exe): \(error)")
    }
    // Single-file diffs are small, so reading stdout to EOF before waiting can't deadlock here.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
      let stderr =
        String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw VCSError.io("\(exe) exited \(proc.terminationStatus): \(stderr)")
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  private static func map(_ c: WrVcs.Commit) -> VCSCommit {
    VCSCommit(
      commitID: c.commitId,
      shortID: c.shortId,
      changeID: c.changeId,
      summary: c.summary,
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

  /// The UniFFI surface throws `WrVcs.VcsError`; stringify for now (a precise case-by-case mapping to
  /// `VCSError` lands with the error-taxonomy work).
  private static func mapError(_ error: Error) -> VCSError {
    .io("\(error)")
  }
}
