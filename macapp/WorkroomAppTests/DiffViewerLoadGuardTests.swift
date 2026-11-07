import XCTest

@testable import Workroom

/// Regression tests for `DiffLoader.loadIfNeeded`'s load-once-per-file guard behind the diff pane's
/// keyed load `.task`. It exists because a spurious body re-render (SwiftUI re-firing the task on
/// the same view instance after `applyHighlight` populates highlight lines, with the fetch key
/// UNCHANGED) used to re-enter `load()`, reset `state = .loading`, re-render, re-highlight… a ~150ms
/// feedback loop that left the pane stuck on its loader forever (issue #59). The guard must treat a
/// same-key re-fire as a no-op while still reloading on a real file switch.
@MainActor
final class DiffViewerLoadGuardTests: XCTestCase {

  /// A request for `path` at `source`, served an empty diff without touching a repository.
  private func request(_ path: String, _ source: DiffSource) -> DiffLoader.Request {
    DiffLoader.Request(
      descriptor: DiffDescriptor(path: path, change: .modified, source: source, isPreview: false),
      directory: "/diff-load-guard", repositoryLocation: nil, cannedDiffs: nil,
      resolveDiff: { _, _ in .empty })
  }

  func testFirstEverLoadRuns() async {
    // No prior load → the initial load must run.
    let loaded = await DiffLoader().loadIfNeeded(request("user.rb", .commit("abc")))
    XCTAssertTrue(loaded)
  }

  func testSameKeyReFireIsSkipped() async {
    // The regression: the task re-fires with the SAME fetch key after a highlight-driven re-render.
    // This MUST be a no-op — otherwise load() re-enters and the loader spins forever.
    let loader = DiffLoader()
    _ = await loader.loadIfNeeded(request("user.rb", .commit("abc")))
    let reloaded = await loader.loadIfNeeded(request("user.rb", .commit("abc")))
    XCTAssertFalse(reloaded, "a re-fire with an unchanged fetchKey must not reload")
  }

  func testChangedFileReloads() async {
    // A genuine file/revision switch changes the fetch key → reload.
    let loader = DiffLoader()
    _ = await loader.loadIfNeeded(request("user.rb", .commit("abc")))
    let otherFile = await loader.loadIfNeeded(request("post.rb", .commit("abc")))
    XCTAssertTrue(otherFile, "a different file must reload")
    let otherRevision = await loader.loadIfNeeded(request("post.rb", .commit("def")))
    XCTAssertTrue(otherRevision, "the same file at a different revision must reload")
  }
}
