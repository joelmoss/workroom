import XCTest

@testable import Workroom

/// A `VCSProviding` whose `currentRef` is a closure; the other reads are unused here. Lets
/// `BranchResolver` be tested without a real repo now that it reads through the provider seam.
private struct StubProvider: VCSProviding {
  let ref: @Sendable () async throws -> VCSRef
  func log(root: URL, limit: Int) throws -> VCSHistoryPage {
    .init(commits: [], reachedEnd: true)
  }
  func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
    throw VCSError.io("unused")
  }
  func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
    throw VCSError.io("unused")
  }
  func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
    throw VCSError.io("unused")
  }
  func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
  func currentRef(root: URL) async throws -> VCSRef { try await ref() }
}

/// `BranchResolver` now just maps the backend's `VCSRef` → the sidebar's `RootRef`, guards the
/// vcs kind, and bounds the read with a timeout — the git/jj specifics (symbolic-ref, bookmark
/// walk, name cleaning) moved into `GitProvider`/`RustJJProvider` (+ the Rust `current_ref`).
final class BranchResolverTests: XCTestCase {
  private func resolver(
    timeout: TimeInterval = 3, _ ref: @escaping @Sendable () async throws -> VCSRef
  ) -> BranchResolver {
    BranchResolver(timeout: timeout, makeProvider: { _ in StubProvider(ref: ref) })
  }

  // MARK: VCSRef → RootRef mapping (git branch/detached + jj bookmark/ancestor all funnel here)

  func testBranchMapsToBranch() async {
    let ref = await resolver { VCSRef(name: "main", kind: .branch) }.resolve(path: "/x", vcs: "git")
    XCTAssertEqual(ref.kind, .branch)
    XCTAssertEqual(ref.branch, "main")
  }

  func testAncestorMapsToAncestor() async {
    let ref = await resolver { VCSRef(name: "master", kind: .ancestor) }
      .resolve(path: "/x", vcs: "jj")
    XCTAssertEqual(ref.kind, .ancestor)
    XCTAssertEqual(ref.branch, "master")
  }

  func testDetachedMapsToDetached() async {
    let ref = await resolver { VCSRef(name: "a1b2c3d", kind: .detached) }
      .resolve(path: "/x", vcs: "git")
    XCTAssertEqual(ref.kind, .detached)
    XCTAssertEqual(ref.branch, "a1b2c3d")
  }

  func testNoneMapsToUnresolved() async {
    let ref = await resolver { VCSRef.none }.resolve(path: "/x", vcs: "jj")
    XCTAssertEqual(ref, .unresolved)
  }

  func testEmptyNameFallsBackToUnresolved() async {
    // Defensive: a kind that claims a branch but carries no name isn't a usable label.
    let ref = await resolver { VCSRef(name: "", kind: .branch) }.resolve(path: "/x", vcs: "git")
    XCTAssertEqual(ref, .unresolved)
  }

  // MARK: routing + failure modes

  func testUnknownVCSSkipsProvider() async {
    // A non-git/jj vcs resolves to .unresolved WITHOUT ever calling the provider.
    let r = BranchResolver(makeProvider: { _ in
      StubProvider {
        XCTFail("the provider must not be called for an unsupported vcs")
        return .none
      }
    })
    let ref = await r.resolve(path: "/x", vcs: "hg")
    XCTAssertEqual(ref, .unresolved)
  }

  func testProviderErrorYieldsUnresolved() async {
    let ref = await resolver { throw VCSError.io("boom") }.resolve(path: "/x", vcs: "git")
    XCTAssertEqual(ref, .unresolved)
  }

  func testTimeoutYieldsUnresolved() async {
    // A read that outruns the deadline is abandoned → .unresolved (one wedged repo, one row).
    let r = resolver(timeout: 0.1) {
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return VCSRef(name: "late", kind: .branch)
    }
    let ref = await r.resolve(path: "/x", vcs: "git")
    XCTAssertEqual(ref, .unresolved)
  }
}
