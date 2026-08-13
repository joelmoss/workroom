import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// The regression net for the WORKROOM-2B candidate flagged in TODOS.md for `Views/FilesPanel.swift`:
/// `FileTreeRowView` used to hold BOTH `@EnvironmentObject var store: AppStore` (read only inside
/// tap/menu closures, never in the rendered body) and `@ObservedObject var model: FileTreeModel`,
/// over an eager `VStack` capped at 4000 rows — the same shape that turned per-row avatar work into a
/// 2-second History-pane stall. Measured before changing anything (per the TODO's own instruction):
/// an unrelated `AppStore` publish rebuilt all 200 visible rows. Fixed the same way History/Changes
/// were — the row now observes nothing, `FilesPanel` hoists `isExpanded` + passes plain closures, and
/// the list is a `LazyVStack` (safe here: rows are fixed-height, unlike `DiffViewer`'s soft-wrapping
/// lines) inside the inspector's own `ScrollView`.
///
/// Harness mirrors `HistoryRowInvalidationTests` (offscreen `NSHostingView`, the shared `settle`
/// waiter for UI settling) — `FileTreeModel` is hosted standalone (not `store.fileTree`), fed by a
/// fake `StatusCommandRunning` so no real `git`/`jj` process is ever spawned. `awaitLoaded` uses a
/// real `Task.sleep` poll instead: `settle`'s `RunLoop.current` pump (built for AppKit/SwiftUI layout)
/// never gives `FileTreeModel.reload`'s unstructured `Task` a turn in this plain-XCTest context.
@MainActor
final class FilesPanelInvalidationTests: XCTestCase {

  // MARK: harness

  /// Returns a fixed `git ls-files -z` result for however many paths were configured; the `jj`
  /// branch is never reached because git always succeeds first.
  private final class FixedGitListRunner: StatusCommandRunning, @unchecked Sendable {
    var paths: [String] = []
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      CommandResult(
        stdout: paths.joined(separator: "\0") + "\0", stderr: "", exitCode: 0, timedOut: false)
    }
  }

  private var tempDirs: [String] = []

  override func tearDown() {
    for d in tempDirs { try? FileManager.default.removeItem(atPath: d) }
    tempDirs = []
    super.tearDown()
  }

  /// A real, empty throwaway directory — `FileTreeModel.activate` requires the path to exist on
  /// disk, but the listing itself is entirely faked, so nothing inside it is ever read.
  private func throwawayDir() -> String {
    let path = NSTemporaryDirectory() + "wr-filespanel-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    tempDirs.append(path)
    return path
  }

  private func awaitLoaded(_ model: FileTreeModel) async {
    for _ in 0..<200 {
      if model.state == .loaded { return }
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
  }

  /// A `FileTreeModel` activated against `count` FLAT (no subdirectories) synthetic files, so every
  /// one is a visible row with no expansion needed — directly exercising "does the list build every
  /// row of a large tree", not the (separately gated) directory-expansion path.
  private func activatedModel(fileCount count: Int) async -> FileTreeModel {
    let runner = FixedGitListRunner()
    runner.paths = (0..<count).map { "file-\($0).txt" }
    let model = FileTreeModel(runner: runner)
    model.activate(path: throwawayDir())
    await awaitLoaded(model)
    return model
  }

  /// A store with an active selection (so `FilesPanel` clears its "No open terminal" placeholder)
  /// but otherwise uninvolved with the file tree — the model under test is hosted standalone.
  private func makeStore() -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    let projectPath = "/files-invalidation"
    store.projects = [
      Project(
        path: projectPath, vcs: "git",
        workrooms: [
          Workroom(
            name: "solo", path: "\(projectPath)/solo", vcsName: "workroom/solo", warnings: [])
        ])
    ]
    let target = store.target(for: .workroom(project: projectPath, name: "solo"))!
    _ = store.terminals.addTab(for: target)
    store.selectedTargetID = .workroom(project: projectPath, name: "solo")
    // Not fired automatically by the above in this bare harness (no real window/focus event drives
    // it) — `FilesPanel`'s placeholder gate (`store.inspectorTargetID`) depends on it directly.
    store.refreshSelectionHasTabs()
    return store
  }

  /// Host the real `FilesPanel` offscreen, directly over the given model (not `store.fileTree`).
  private func host(_ store: AppStore, _ model: FileTreeModel) -> (NSWindow, NSView) {
    let root = FilesPanel(model: model)
      .environmentObject(store)
      .environmentObject(store.notifications)
      .frame(width: 280, height: 400)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    return (window, hosting)
  }

  // MARK: the hang itself

  /// The actual WORKROOM-2B mechanism: does a publish of `AppStore` that says NOTHING about the file
  /// tree still rebuild every row? `store` is no longer observed by the row at all — this must be
  /// zero, and fails on the pre-fix code (all 200 rows rebuilt).
  func testUnrelatedAppStorePublishRebuildsNoRows() async throws {
    let model = await activatedModel(fileCount: 200)
    let store = makeStore()
    let (window, view) = host(store, model)
    defer { window.close() }
    settle(view)
    XCTAssertGreaterThan(
      FileTreeRowView.bodyPasses, 0, "the fixture must actually render file rows")

    FileTreeRowView.bodyPasses = 0
    // Reassigning a `@Published` property fires `objectWillChange` regardless of value equality —
    // this says nothing whatsoever about the file tree.
    for _ in 0..<10 { store.isLoading.toggle() }
    settle(view)

    XCTAssertEqual(
      FileTreeRowView.bodyPasses, 0,
      "an AppStore publish unrelated to the file tree rebuilt \(FileTreeRowView.bodyPasses) row "
        + "passes — this is WORKROOM-2B: title/activity/notifications/status publishes, all far "
        + "higher-frequency than a file-tree reload, must not touch these rows at all")
  }

  /// The positive half: a real content change (a directory's OWN expansion flipping) must still
  /// rebuild THAT row. The equality gate that gives us zero above could just as easily freeze every
  /// row's contents if it compared the wrong fields.
  func testTogglingADirectoryRebuildsThatRow() async throws {
    let runner = FixedGitListRunner()
    runner.paths = ["dir/a.txt"] + (0..<50).map { "file-\($0).txt" }
    let model = FileTreeModel(runner: runner)
    model.activate(path: throwawayDir())
    await awaitLoaded(model)
    let store = makeStore()
    let (window, view) = host(store, model)
    defer { window.close() }
    settle(view)
    guard let dir = model.roots.first(where: { $0.isDirectory }) else {
      return XCTFail("fixture must include a directory row to toggle")
    }

    FileTreeRowView.bodyPasses = 0
    model.toggle(dir)
    settle(view)

    XCTAssertGreaterThan(
      FileTreeRowView.bodyPasses, 0,
      "toggling a directory's own expansion must rebuild at least that row — an equality gate that "
        + "swallowed this would trade the hang for a chevron that never rotates")
  }

  // MARK: scale

  func testLargeTreeDoesNotBuildEveryRow() async throws {
    let model = await activatedModel(fileCount: 1000)
    let store = makeStore()
    FileTreeRowView.bodyPasses = 0
    let (window, view) = host(store, model)
    defer { window.close() }
    settle(view)

    XCTAssertGreaterThan(FileTreeRowView.bodyPasses, 0, "the panel must render some rows")
    // Deliberately not an exact number — how far past the viewport SwiftUI realizes is its business.
    // "Far fewer than all of them" is the property that matters (mirrors
    // `HistoryRowInvalidationTests.testLargePageDoesNotBuildEveryRow`).
    XCTAssertLessThan(
      FileTreeRowView.bodyPasses, 1000,
      "a 280×400 panel shows ~15 rows, so building all 1000 confirms the list is still eager")
  }

  func testLargeTreeRendersUnderTimeCeiling() async throws {
    let model = await activatedModel(fileCount: 4000)
    let store = makeStore()
    let started = Date()
    let (window, view) = host(store, model)
    defer { window.close() }
    view.layoutSubtreeIfNeeded()
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(
      elapsed, 0.25,
      "first layout of a 4000-file (renderCap) tree took \(String(format: "%.3f", elapsed))s on the "
        + "main thread")
  }
}
