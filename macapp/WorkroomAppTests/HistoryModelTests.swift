import XCTest

@testable import Workroom

@MainActor
final class HistoryModelTests: XCTestCase {
  private let url = URL(fileURLWithPath: "/tmp/wr-history-test")

  private func commit(_ id: String) -> VCSCommit {
    VCSCommit(
      commitID: id, shortID: String(id.prefix(8)), changeID: nil, summary: "c \(id)",
      authors: [], timestamp: Date(timeIntervalSince1970: 0), refs: [], parentIDs: [],
      isWorkingCopy: false)
  }

  /// A provider returning `prefix(limit)` of a fixed list, so a growing limit yields more commits —
  /// exactly the growing-prefix pagination `HistoryModel` uses.
  private struct FakeProvider: VCSProviding {
    let all: [VCSCommit]
    func log(root: URL, limit: Int) async throws -> VCSHistoryPage {
      let slice = Array(all.prefix(limit))
      return VCSHistoryPage(commits: slice, reachedEnd: slice.count >= all.count)
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
    func currentRef(root: URL) async throws -> VCSRef { .none }
  }

  private struct FailProvider: VCSProviding {
    func log(root: URL, limit: Int) async throws -> VCSHistoryPage {
      throw VCSError.io("boom")
    }
    func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
      throw VCSError.io("boom")
    }
    func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
      throw VCSError.io("boom")
    }
    func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
      throw VCSError.io("boom")
    }
    func currentRef(root: URL) async throws -> VCSRef { throw VCSError.io("boom") }
  }

  private func model(_ provider: some VCSProviding, pageSize: Int) -> HistoryModel {
    HistoryModel(pageSize: pageSize, resolve: { _ in provider })
  }

  func testFocusLoadsFirstPage() async {
    let m = model(FakeProvider(all: (1...5).map { commit("\($0)") }), pageSize: 2)
    m.focus(url)
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.commits.count, 2)
    XCTAssertFalse(m.reachedEnd)
    XCTAssertEqual(m.state, .loaded)
  }

  func testLoadMoreGrowsThenReachesEnd() async {
    let m = model(FakeProvider(all: (1...5).map { commit("\($0)") }), pageSize: 2)
    m.focus(url)
    await m.awaitCurrentLoad()

    m.loadMore()
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.commits.count, 4)
    XCTAssertFalse(m.reachedEnd)

    m.loadMore()
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.commits.count, 5)
    XCTAssertTrue(m.reachedEnd, "all commits loaded ⇒ reachedEnd")
  }

  func testFailurePropagatesToState() async {
    let m = model(FailProvider(), pageSize: 10)
    m.focus(url)
    await m.awaitCurrentLoad()
    XCTAssertTrue(m.commits.isEmpty)
    if case .failed = m.state {} else { XCTFail("expected .failed, got \(m.state)") }
  }

  func testFocusNilClears() async {
    let m = model(FakeProvider(all: [commit("1")]), pageSize: 10)
    m.focus(url)
    await m.awaitCurrentLoad()
    XCTAssertFalse(m.commits.isEmpty)

    m.focus(nil)
    XCTAssertTrue(m.commits.isEmpty)
    XCTAssertEqual(m.state, .idle)
  }
}
