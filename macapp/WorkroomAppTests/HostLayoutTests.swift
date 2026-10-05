import XCTest

@testable import Workroom

/// A remote workroom's layout as its host keeps it (#255): what goes up, what comes back, and how
/// this Mac's own focus and frames are put back on a layout another Mac wrote.
final class HostLayoutTests: XCTestCase {
  private let session = "4C0F5F2E-2B49-4C4D-9C1E-6A1B2B3C4D5E"

  private func terminal(_ key: String, session: String?, frame: String? = nil) -> TabSession {
    var tab = TabSession(
      key: key, kind: TabSession.terminalKind,
      terminal: TerminalPayload(defaultTitle: "Terminal", cwd: "/w", sessionID: session))
    tab.detachedFrame = frame
    return tab
  }

  private func file(_ key: String, path: String) -> TabSession {
    TabSession(
      key: key, kind: TabSession.fileKind, file: FilePayload(path: path, isPreview: false))
  }

  private func local() -> TargetSession {
    var target = TargetSession(
      targetID: "wr|/Users/me/app|cyan",
      tabs: [
        terminal("a", session: session, frame: "{{1, 2}, {300, 200}}"),
        file("b", path: "README.md"),
      ],
      splits: [
        .split(orientation: "horizontal", ratio: 0.5, first: .leaf("a"), second: .leaf("b"))
      ],
      focusedKey: "b", terminalCounter: 3)
    target.hostRevision = 4
    target.hostLayoutStale = true
    return target
  }

  /// What goes up carries the workroom's own key and nothing of this Mac's: no project path, no
  /// focus, no frames, no revision or stale mark.
  func testWhatAHostKeepsHasNothingOfThisMacs() throws {
    let blob = try HostLayout.encode(local(), key: "WORKROOM-ID")
    XCTAssertFalse(blob.contains("/Users/me/app"), blob)
    XCTAssertFalse(blob.contains("focusedKey"), blob)
    XCTAssertFalse(blob.contains("detachedFrame"), blob)
    XCTAssertFalse(blob.contains("hostRevision"), blob)
    XCTAssertFalse(blob.contains("hostLayoutStale"), blob)
    XCTAssertTrue(blob.contains("WORKROOM-ID"), blob)
  }

  /// Read back on another Mac, it is that Mac's target, with the tabs, split and counter intact.
  func testALayoutReadBackIsThisMacsTarget() throws {
    let blob = try HostLayout.encode(local(), key: "WORKROOM-ID")
    guard case .layout(let read) = HostLayout.decode(blob, targetID: "wr|/Volumes/other|cyan")
    else { return XCTFail("not a layout") }
    XCTAssertEqual(read.targetID, "wr|/Volumes/other|cyan")
    XCTAssertEqual(read.tabs.map(\.key), ["a", "b"])
    XCTAssertEqual(read.splits, local().splits)
    XCTAssertEqual(read.terminalCounter, 3)
    XCTAssertNil(read.focusedKey)
    XCTAssertNil(read.tabs[0].detachedFrame)
  }

  /// The last tab closed is a layout of its own (D11), not "nothing written yet".
  func testAWorkroomWithNoTabsIsAnEmptyLayout() throws {
    let blob = try HostLayout.encode(TargetSession(targetID: "x", tabs: []), key: "WORKROOM-ID")
    XCTAssertEqual(HostLayout.decode(blob, targetID: "x"), .empty)
  }

  /// A layout from a newer schema is read-only to this build; garbage is unreadable, never a crash.
  func testANewerOrBrokenLayoutIsNotRestored() {
    XCTAssertEqual(
      HostLayout.decode(#"{"schemaVersion": 99, "target": {}}"#, targetID: "x"), .newer)
    XCTAssertEqual(HostLayout.decode("not json", targetID: "x"), .unreadable)
    XCTAssertEqual(HostLayout.decode(#"{"schemaVersion": 1}"#, targetID: "x"), .unreadable)
  }

  /// A tab kind this build does not know costs that tab only (D5), and a hostile shape is
  /// sanitized as a session.json is: duplicate keys keep the first.
  func testALayoutIsSanitizedOnTheWayIn() {
    let blob = """
      {"schemaVersion": 1, "target": {"targetID": "k", "tabs": [
        {"key": "t1", "kind": "terminal", "terminal": {"defaultTitle": "Terminal 1"}},
        {"key": "t2", "kind": "hologram"},
        {"key": "t1", "kind": "file", "file": {"path": "x", "isPreview": false}}
      ], "splits": []}}
      """
    guard case .layout(let read) = HostLayout.decode(blob, targetID: "mine") else {
      return XCTFail("not a layout")
    }
    XCTAssertEqual(read.tabs.map(\.kind), [TabSession.terminalKind])
  }

  /// Keys are re-minted on every restore, so this Mac finds its focus and its popped-out frame
  /// again by what the tabs show (D12).
  func testThisMacsFocusAndFramesComeBackByWhatTheTabsShow() throws {
    let blob = try HostLayout.encode(local(), key: "WORKROOM-ID")
    guard case .layout(var other) = HostLayout.decode(blob, targetID: "mine") else {
      return XCTFail("not a layout")
    }
    // Another Mac restored and saved: every key is new.
    other.tabs = other.tabs.enumerated().map { index, tab in
      var tab = tab
      tab.key = "new-\(index)"
      return tab
    }
    let refilled = HostLayout.refilled(other, from: local())
    XCTAssertEqual(refilled.focusedKey, "new-1", "focus was on the README tab")
    XCTAssertEqual(refilled.tabs[0].detachedFrame, "{{1, 2}, {300, 200}}")
    XCTAssertNil(refilled.tabs[1].detachedFrame)
    XCTAssertEqual(HostLayout.refilled(other, from: nil), other)
  }
}
