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
    // The full changeset (file list + per-file diff) isn't exposed over UniFFI yet — it needs the
    // jj-lib async diff_stream in wr-vcs-core (Phase-1 task). Metadata-only until then.
    throw VCSError.io("jj changeset detail not yet implemented (Phase 1)")
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

  /// The UniFFI surface throws `WrVcs.VcsError`; stringify for now (a precise case-by-case mapping to
  /// `VCSError` lands with the error-taxonomy work once the changeset surface exists).
  private static func mapError(_ error: Error) -> VCSError {
    .io("\(error)")
  }
}
