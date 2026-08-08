import XCTest

@testable import Workroom

/// What a target contributes to a saved session (issue #46).
///
/// Uses the same factory seam as `TerminalSessionsTests`: a `GhosttySurfaceView` only creates its PTY
/// when it enters a window, so constructing one here spawns nothing.
@MainActor
final class SessionCaptureTests: XCTestCase {
  private let target = TerminalTarget(
    id: "wr|/p|foo", title: "foo", path: "/tmp", isMissing: false)

  private func makeSessions() -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command)
    }
    return sessions
  }

  /// Mirrors what `AppStore.captureWindowSession` does, without needing a window or a store.
  private func capture(_ sessions: TerminalSessions) -> TargetSession? {
    guard let captured = sessions.sessionCapture(forTargetID: target.id) else { return nil }
    var keys: [TerminalTab.ID: String] = [:]
    var tabs: [TabSession] = []
    for tab in captured.tabs {
      let key = tab.id.uuidString
      guard let session = TabSession(key: key, tab: tab) else { continue }
      keys[tab.id] = key
      tabs.append(session)
    }
    guard !tabs.isEmpty else { return nil }
    return TargetSession(
      targetID: target.id, tabs: tabs,
      split: captured.split.flatMap { LayoutNode<String>.capture($0) { keys[$0] } },
      focusedKey: captured.focused.flatMap { keys[$0] },
      terminalCounter: captured.counter)
  }

  // MARK: Shape

  func testCapturesTabsInStripOrderWithTheCounter() throws {
    let sessions = makeSessions()
    sessions.addTab(for: target)
    sessions.addTab(for: target)
    sessions.addTab(for: target)

    let captured = try XCTUnwrap(capture(sessions))
    XCTAssertEqual(captured.tabs.count, 3)
    XCTAssertEqual(captured.tabs.map(\.kind), Array(repeating: TabSession.terminalKind, count: 3))
    XCTAssertEqual(
      captured.tabs.compactMap { $0.terminal?.defaultTitle },
      ["Terminal 1", "Terminal 2", "Terminal 3"])
    XCTAssertEqual(captured.terminalCounter, 3, "so the next ⌘T is Terminal 4, not Terminal 1")
    XCTAssertEqual(captured.tabs.map(\.key), sessions.tabs(for: target).map(\.id.uuidString))
  }

  func testCapturedSplitAddressesTheCapturedTabs() throws {
    let sessions = makeSessions()
    sessions.addTab(for: target)
    sessions.splitFocusedPane(for: target, orientation: .horizontal)

    let captured = try XCTUnwrap(capture(sessions))
    let split = try XCTUnwrap(captured.split)
    let keys = Set(captured.tabs.map(\.key))
    XCTAssertEqual(split.leaves.count, 2)
    XCTAssertTrue(
      split.leaves.allSatisfy { keys.contains($0) },
      "every split leaf must address a tab that was actually written")
    XCTAssertEqual(captured.focusedKey.map { keys.contains($0) }, true)
  }

  func testCapturesContentTabsWithTheirOverrides() throws {
    let sessions = makeSessions()
    let diff = sessions.openContentPersistent(
      DiffDescriptor(
        path: "a/b.swift", change: .modified, source: .commit("abc123"), isPreview: false),
      for: target)
    sessions.setDiffViewMode(.sideBySide, forTab: diff, in: target)
    let file = sessions.openContentPersistent(
      FileDescriptor(path: "README.md", isPreview: false), for: target)
    sessions.setMarkdownPreview(false, forTab: file, in: target)
    _ = sessions.openContentPersistent(
      ChangesetDescriptor(commitID: "def456", title: "Fix it", isPreview: false), for: target)

    let captured = try XCTUnwrap(capture(sessions))
    let diffPayload = try XCTUnwrap(captured.tabs.compactMap(\.diff).first)
    XCTAssertEqual(diffPayload.path, "a/b.swift")
    XCTAssertEqual(diffPayload.change, ChangedFile.Change.modified.rawValue)
    XCTAssertEqual(diffPayload.source.source, .commit("abc123"))
    XCTAssertEqual(diffPayload.viewMode, DiffViewMode.sideBySide.rawValue)

    let filePayload = try XCTUnwrap(captured.tabs.compactMap(\.file).first)
    XCTAssertEqual(filePayload.path, "README.md")
    XCTAssertEqual(filePayload.markdownPreview, false)

    let changeset = try XCTUnwrap(captured.tabs.compactMap(\.changeset).first)
    XCTAssertEqual(changeset.commitID, "def456")
    XCTAssertEqual(changeset.title, "Fix it")
  }

  func testCapturesThePreviewFlag() throws {
    let sessions = makeSessions()
    _ = sessions.openContentPreview(
      FileDescriptor(path: "preview.txt", isPreview: true), for: target)

    let captured = try XCTUnwrap(capture(sessions))
    XCTAssertEqual(captured.tabs.compactMap(\.file).first?.isPreview, true)
  }

  // MARK: Run tabs

  /// A restored run tab would resurrect a dev server with no `RunState` behind it — an untracked
  /// process orphaned on its port. It must never reach the file.
  ///
  /// `splitTab` spawns a fresh shell beside the anchor, so this leaves three tabs — a plain terminal,
  /// the run tab, and the new pane — of which exactly one is unpersistable.
  func testRunTabIsExcludedAndItsSplitLeafCollapses() throws {
    let sessions = makeSessions()
    sessions.addTab(for: target)
    let runTab = sessions.addRunTab(
      for: target, command: "npm run dev", cwd: target.path, focus: false)
    sessions.splitTab(runTab.id, on: .right, for: target)
    XCTAssertEqual(sessions.tabs(for: target).count, 3)
    XCTAssertEqual(sessions.split(for: target)?.tabIDs.count, 2, "the run tab is in the split")

    let captured = try XCTUnwrap(capture(sessions))
    XCTAssertEqual(captured.tabs.count, 2, "the run tab is not persisted")
    XCTAssertFalse(
      captured.tabs.contains { $0.terminal?.defaultTitle == "Run" },
      "no run tab reaches the file")
    XCTAssertNil(
      captured.split,
      "the split had two leaves and one was the run tab — a lone leaf is not a split")
  }

  /// A target whose only tab was a run tab contributes nothing rather than an empty entry — an empty
  /// entry would make `ensureTab`'s "has this target been seeded?" check lie on restore.
  func testTargetWithOnlyARunTabIsDropped() {
    let sessions = makeSessions()
    _ = sessions.addRunTab(for: target, command: "npm run dev", cwd: target.path, focus: false)
    XCTAssertNil(capture(sessions))
  }

  func testNoTabsCapturesNothing() {
    XCTAssertNil(capture(makeSessions()))
  }
}
