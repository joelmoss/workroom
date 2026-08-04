import XCTest

@testable import Workroom

@MainActor
final class HistoryModelTests: XCTestCase {
  private let url = URL(fileURLWithPath: "/tmp/wr-history-test")

  private func commit(_ id: String) -> VCSCommit {
    VCSCommit(
      commitID: id, shortID: String(id.prefix(8)), changeID: nil, summary: "c \(id)",
      body: "", authors: [], timestamp: Date(timeIntervalSince1970: 0), refs: [], parentIDs: [],
      isWorkingCopy: false)
  }

  /// A provider returning `prefix(limit)` of a fixed list, so a growing limit yields more commits —
  /// exactly the growing-prefix pagination `HistoryModel` uses.
  private struct FakeProvider: VCSProviding {
    let all: [VCSCommit]
    func log(root: URL, limit: Int) throws -> VCSHistoryPage {
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
    func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
    func currentRef(root: URL) async throws -> VCSRef { .none }
  }

  private struct FailProvider: VCSProviding {
    func log(root: URL, limit: Int) throws -> VCSHistoryPage {
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
    func fileContent(root: URL, rev: String, path: String) async throws -> String? {
      throw VCSError.io("boom")
    }
    func currentRef(root: URL) async throws -> VCSRef { throw VCSError.io("boom") }
  }

  /// A provider that counts `log` calls and can be toggled to fail — so `activate`'s branch behaviour
  /// (does it reload? how many times?) is observable, and its failure-retry can be driven. Lock-guarded
  /// + `@unchecked Sendable` because `log` runs off-main via `runBlocking`; the tests serialize access
  /// with `awaitCurrentLoad`, so there's no real contention.
  private final class CountingProvider: VCSProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _all: [VCSCommit]
    private var _fail = false
    var logCount: Int { lock.withLock { _count } }
    init(_ all: [VCSCommit]) { _all = all }
    func setFail(_ f: Bool) { lock.withLock { _fail = f } }
    func log(root: URL, limit: Int) throws -> VCSHistoryPage {
      try lock.withLock {
        _count += 1
        if _fail { throw VCSError.io("boom") }
        let slice = Array(_all.prefix(limit))
        return VCSHistoryPage(commits: slice, reachedEnd: slice.count >= _all.count)
      }
    }
    func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
      throw VCSError.io("x")
    }
    func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
      throw VCSError.io("x")
    }
    func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
      throw VCSError.io("x")
    }
    func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
    func currentRef(root: URL) async throws -> VCSRef { .none }
  }

  private func countingModel(_ provider: CountingProvider, pageSize: Int = 10) -> HistoryModel {
    HistoryModel(pageSize: pageSize, resolve: { _ in provider })
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

  // MARK: window cap (bounds the per-refresh read, not the drawing — WORKROOM-2B)

  private func capped(_ provider: some VCSProviding, pageSize: Int, maxWindow: Int) -> HistoryModel
  {
    HistoryModel(pageSize: pageSize, maxWindow: maxWindow, resolve: { _ in provider })
  }

  func testLoadMoreStopsAtWindowCap() async {
    let m = capped(FakeProvider(all: (1...20).map { commit("\($0)") }), pageSize: 2, maxWindow: 4)
    m.focus(url)
    await m.awaitCurrentLoad()
    XCTAssertFalse(m.atWindowCap)

    m.loadMore()
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.commits.count, 4)
    XCTAssertTrue(m.atWindowCap, "the window is full")

    m.loadMore()
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.commits.count, 4, "loadMore at the cap must be a no-op")
  }

  func testWindowCapDoesNotClaimTheHistoryEnded() async {
    let m = capped(FakeProvider(all: (1...20).map { commit("\($0)") }), pageSize: 4, maxWindow: 4)
    m.focus(url)
    await m.awaitCurrentLoad()

    XCTAssertTrue(m.atWindowCap)
    XCTAssertFalse(
      m.reachedEnd,
      "`reachedEnd` means no OLDER commits exist; conflating it with the cap would make the model lie "
        + "to every caller (and hide the cap notice the pane shows instead of `Load more`)")
  }

  func testRefreshDoesNotReinflatePastTheCap() async {
    let m = capped(FakeProvider(all: (1...20).map { commit("\($0)") }), pageSize: 2, maxWindow: 4)
    m.focus(url)
    await m.awaitCurrentLoad()
    m.loadMore()
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.commits.count, 4)

    // Refresh re-reads a growing PREFIX, and it fires per ref write from the metadata watcher — so an
    // unclamped refresh is the path that would keep re-walking an oversized window forever.
    m.refresh()
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.commits.count, 4)
  }

  func testWindowCapNeverBelowOnePage() async {
    // A caller asking for a cap under one page gets one page, not an empty list.
    let m = capped(FakeProvider(all: (1...20).map { commit("\($0)") }), pageSize: 10, maxWindow: 3)
    m.focus(url)
    await m.awaitCurrentLoad()
    XCTAssertEqual(m.commits.count, 10)
    XCTAssertEqual(m.windowCap, 10)
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

  // MARK: activate (section (re)activation — the live-refresh entry point)

  func testActivateNewRootLoadsOnce() async {
    let p = CountingProvider((1...3).map { commit("\($0)") })
    let m = countingModel(p)
    m.activate(url)
    await m.awaitCurrentLoad()
    XCTAssertEqual(p.logCount, 1)
    XCTAssertEqual(m.commits.count, 3)
    XCTAssertEqual(m.state, .loaded)
  }

  func testActivateReentryOnLoadedRootRefreshes() async {
    let p = CountingProvider((1...3).map { commit("\($0)") })
    let m = countingModel(p)
    m.activate(url)
    await m.awaitCurrentLoad()
    XCTAssertEqual(p.logCount, 1)

    // Same root, already `.loaded` → a genuine re-entry pulls fresh.
    m.activate(url)
    await m.awaitCurrentLoad()
    XCTAssertEqual(p.logCount, 2, "re-entry on a loaded root must reload")
    XCTAssertEqual(m.state, .loaded)
  }

  func testActivateWhileLoadingDoesNotDoubleLoad() async {
    let p = CountingProvider((1...3).map { commit("\($0)") })
    let m = countingModel(p)
    m.activate(url)  // starts the load; state → .loading synchronously
    m.activate(url)  // same root, NOT settled → focus no-ops; must not fork a 2nd load
    await m.awaitCurrentLoad()
    XCTAssertEqual(p.logCount, 1, "a fresh point-at already loading must not double-load")
  }

  func testActivateReentryOnFailedRootRetries() async {
    let p = CountingProvider((1...3).map { commit("\($0)") })
    p.setFail(true)
    let m = countingModel(p)
    m.activate(url)
    await m.awaitCurrentLoad()
    XCTAssertEqual(p.logCount, 1)
    if case .failed = m.state {} else { XCTFail("expected .failed, got \(m.state)") }

    // Transient failure cleared; re-entering History must RETRY (focus would no-op on the same root).
    p.setFail(false)
    m.activate(url)
    await m.awaitCurrentLoad()
    XCTAssertEqual(p.logCount, 2, "re-entry on a failed root must retry the load")
    XCTAssertEqual(m.state, .loaded)
    XCTAssertEqual(m.commits.count, 3)
  }

  func testActivateNilClears() async {
    let p = CountingProvider([commit("1")])
    let m = countingModel(p)
    m.activate(url)
    await m.awaitCurrentLoad()
    XCTAssertFalse(m.commits.isEmpty)

    m.activate(nil)
    XCTAssertTrue(m.commits.isEmpty)
    XCTAssertEqual(m.state, .idle)
  }
}
