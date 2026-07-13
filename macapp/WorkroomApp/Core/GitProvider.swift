import Foundation
import SwiftGitX

/// git-backed `VCSProviding`, over SwiftGitX (libgit2). Maps `SwiftGitX.*` types into the app-native
/// models. Pure Swift — no Rust involved for git.
struct GitProvider: VCSProviding {
  func log(root: URL, limit: Int) async throws -> VCSHistoryPage {
    do {
      let repo = try Repository.open(at: root)
      // A repo with no commits yet (unborn HEAD) is an empty history, not a failure.
      if repo.isHEADUnborn { return VCSHistoryPage(commits: [], reachedEnd: true) }

      // Take one extra to learn whether more history exists beyond the page.
      let window = Array(try repo.log().prefix(max(0, limit) + 1))
      let reachedEnd = window.count <= limit
      let commits = window.prefix(limit).map(Self.map)
      return VCSHistoryPage(commits: Array(commits), reachedEnd: reachedEnd)
    } catch {
      // Untyped catch on purpose: binding SwiftGitX's typed-throws error (`catch let e as
      // SwiftGitXError`) trips a Swift 6 SIL ownership error across the async boundary.
      throw VCSError.io("\(error)")
    }
  }

  func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
    // File list + per-file diff via SwiftGitX diff/patch — Phase-1 task (needs the diff→hunk map).
    throw VCSError.io("git changeset detail not yet implemented (Phase 1)")
  }

  private static func map(_ c: Commit) -> VCSCommit {
    VCSCommit(
      commitID: c.id.hex,
      shortID: c.id.abbreviated,
      changeID: nil,  // git has no change-id
      summary: c.summary,
      authors: [VCSAuthor(name: c.author.name, email: c.author.email)],
      timestamp: c.date,
      refs: [],  // branch/tag decoration: a later increment
      parentIDs: (try? c.parents)?.map { $0.id.hex } ?? [],
      isWorkingCopy: false  // git has no jj-style working-copy commit
    )
  }
}
