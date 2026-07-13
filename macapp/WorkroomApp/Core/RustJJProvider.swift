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

  func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
    // jj per-file diff needs jj-lib's git-format diff writer in wr-vcs-core (next task). Until then
    // the changeset file list works but the diff column is unavailable for jj.
    throw VCSError.io("jj per-file diff not yet implemented (Phase 1)")
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

  /// The UniFFI surface throws `WrVcs.VcsError`; stringify for now (a precise case-by-case mapping to
  /// `VCSError` lands with the error-taxonomy work).
  private static func mapError(_ error: Error) -> VCSError {
    .io("\(error)")
  }
}
