import Foundation

/// What `CLIVCSWriter`'s failure classifier reads from a repository's disk: whether a path exists,
/// whether it is a directory, when it was modified, and the text of a small file (a worktree's
/// `.git`). Every decision stays in the classifier; only where these facts come from changes. For a
/// local repository they are this Mac's (`LocalDisk`); for one on a remote host, what that host's
/// agent reported (`DiskSnapshot`, from `AgentVCSConnection.stat`), since reading this disk for a
/// path on another machine answers nothing, or worse, the wrong thing.
protocol RepositoryDisk: Sendable {
  func entry(_ path: String) -> DiskEntry?
  func text(_ path: String) -> String?
}

struct DiskEntry: Equatable, Sendable {
  let isDirectory: Bool
  let modifiedAt: Date?
}

/// This Mac's disk, read live, exactly as the classifier always read it.
struct LocalDisk: RepositoryDisk {
  func entry(_ path: String) -> DiskEntry? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
      return nil
    }
    let modified =
      (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    return DiskEntry(isDirectory: isDirectory.boolValue, modifiedAt: modified)
  }

  func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
}

/// Facts a remote host reported for a fixed set of paths, read after the command they explain.
///
/// A path the snapshot was not asked about is a bug in `CLIVCSWriter.classificationPaths`, not a
/// missing file, so it traps in debug builds rather than quietly reading as absent.
struct DiskSnapshot: RepositoryDisk {
  let entries: [String: DiskEntry?]
  let texts: [String: String]

  /// For a host that could not be asked: every path reads as absent, which is the classifier's
  /// "no evidence" answer (no parked rebase, no lock file to name).
  static let unknown = DiskSnapshot(entries: [:], texts: [:], complete: false)

  private let complete: Bool

  init(entries: [String: DiskEntry?], texts: [String: String], complete: Bool = true) {
    self.entries = entries
    self.texts = texts
    self.complete = complete
  }

  func entry(_ path: String) -> DiskEntry? {
    guard let known = entries[path] else {
      assert(!complete, "\(path) was not in the snapshot")
      return nil
    }
    return known
  }

  func text(_ path: String) -> String? { texts[path] }
}
