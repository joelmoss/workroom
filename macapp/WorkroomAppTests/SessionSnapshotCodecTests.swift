import XCTest

@testable import Workroom

/// Pure codec + structural-validation tests for the saved-session schema (issue #46).
///
/// The golden-JSON tests are deliberate: the field names in `SessionSnapshot.swift` are a stored-data
/// contract, so a rename has to fail loudly here rather than silently invalidate every user's saved
/// session. No `Defaults`, no files, no `AppStore` — this whole class is pure values.
final class SessionSnapshotCodecTests: XCTestCase {
  private func decode(_ json: String) throws -> SessionFile {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(SessionFile.self, from: Data(json.utf8))
  }

  private func encode(_ file: SessionFile) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(file), as: UTF8.self)
  }

  /// A v1 document with all four tab kinds and a nested split.
  private let golden = """
    {
      "schemaVersion": 1,
      "savedAt": "2026-08-08T10:00:00Z",
      "appVersion": "2.0.0",
      "windows": [
        {
          "windowKey": "W1",
          "frame": "{{0, 0}, {1200, 780}}",
          "isKey": true,
          "selectedTargetID": "wr|/p|calm-otter",
          "expandedTargets": ["wr|/p|calm-otter"],
          "workroomSplits": [
            {
              "kind": "split", "orientation": "horizontal", "ratio": 0.5,
              "first": {"kind": "leaf", "leaf": "wr|/p|calm-otter"},
              "second": {"kind": "leaf", "leaf": "wr|/p|bold-heron"}
            }
          ],
          "targets": [
            {
              "targetID": "wr|/p|calm-otter",
              "focusedKey": "t2",
              "terminalCounter": 3,
              "split": {
                "kind": "split", "orientation": "vertical", "ratio": 0.6,
                "first": {"kind": "leaf", "leaf": "t1"},
                "second": {
                  "kind": "split", "orientation": "horizontal", "ratio": 0.4,
                  "first": {"kind": "leaf", "leaf": "t2"},
                  "second": {"kind": "leaf", "leaf": "t3"}
                }
              },
              "tabs": [
                {
                  "key": "t1", "kind": "terminal",
                  "terminal": {"defaultTitle": "Terminal 1", "cwd": "/p/calm-otter/src"}
                },
                {
                  "key": "t2", "kind": "diff",
                  "diff": {
                    "path": "a/b.swift", "change": "modified", "isPreview": false,
                    "viewMode": "sideBySide",
                    "source": {"kind": "commit", "commit": "abc123"}
                  }
                },
                {
                  "key": "t3", "kind": "file",
                  "file": {"path": "README.md", "isPreview": true, "markdownPreview": false}
                },
                {
                  "key": "t4", "kind": "changeset",
                  "changeset": {
                    "commitID": "def456", "title": "Fix the thing", "isPreview": false,
                    "selectedPath": "a/b.swift"
                  }
                }
              ]
            }
          ]
        }
      ]
    }
    """

  // MARK: Golden document

  func testGoldenDocumentDecodes() throws {
    let file = try decode(golden)
    XCTAssertEqual(file.schemaVersion, 1)
    XCTAssertEqual(file.compatibility, .current)
    XCTAssertEqual(file.windows.count, 1)

    let window = try XCTUnwrap(file.windows.first)
    XCTAssertEqual(window.windowKey, "W1")
    XCTAssertTrue(window.isKey)
    XCTAssertEqual(window.selectedTargetID, "wr|/p|calm-otter")
    XCTAssertEqual(window.expandedTargets, ["wr|/p|calm-otter"])
    XCTAssertEqual(window.workroomSplits.count, 1)
    XCTAssertEqual(
      window.workroomSplits.first?.leaves, ["wr|/p|calm-otter", "wr|/p|bold-heron"])

    let target = try XCTUnwrap(window.targets.first)
    XCTAssertEqual(target.tabs.map(\.key), ["t1", "t2", "t3", "t4"])
    XCTAssertEqual(target.tabs.map(\.kind), ["terminal", "diff", "file", "changeset"])
    XCTAssertEqual(target.focusedKey, "t2")
    XCTAssertEqual(target.terminalCounter, 3)
    XCTAssertEqual(target.split?.leaves, ["t1", "t2", "t3"])
    XCTAssertEqual(target.tabs[0].terminal?.cwd, "/p/calm-otter/src")
    XCTAssertEqual(target.tabs[1].diff?.source.source, .commit("abc123"))
    XCTAssertEqual(target.tabs[1].diff?.viewMode, "sideBySide")
    XCTAssertEqual(target.tabs[2].file?.markdownPreview, false)
    XCTAssertEqual(target.tabs[3].changeset?.selectedPath, "a/b.swift")
  }

  /// Re-encoding a decoded document must reproduce it. A key rename breaks this immediately.
  func testGoldenRoundTripIsStable() throws {
    let once = try encode(try decode(golden))
    let twice = try encode(try decode(once))
    XCTAssertEqual(once, twice)
    XCTAssertTrue(once.contains("\"windowKey\":\"W1\""))
    XCTAssertTrue(once.contains("\"terminalCounter\":3"))
  }

  // MARK: Lossy decoding

  /// The headline `@Lossy` guarantee: an unknown tab kind — what a NEWER build writes, since additive
  /// changes never bump `schemaVersion` — costs that one tab, not the session.
  func testUnknownTabKindDropsOnlyThatTab() throws {
    let json = """
      {
        "schemaVersion": 1, "savedAt": "2026-08-08T10:00:00Z",
        "windows": [{
          "windowKey": "W1", "isKey": true, "workroomSplits": [],
          "targets": [{
            "targetID": "root|/p",
            "tabs": [
              {"key": "t1", "kind": "terminal", "terminal": {"defaultTitle": "Terminal 1"}},
              {"key": "t2", "kind": "hologram", "hologram": {"whatever": true}},
              {"key": "t3", "kind": "file", "file": {"path": "x.txt", "isPreview": false}}
            ]
          }]
        }]
      }
      """
    let (sanitized, report) = try decode(json).sanitized()
    let target = try XCTUnwrap(sanitized.windows.first?.targets.first)
    XCTAssertEqual(target.tabs.map(\.key), ["t1", "t3"])
    XCTAssertEqual(report.droppedTabs, 1)
  }

  /// A structurally broken element is skipped without taking its siblings with it.
  func testMalformedElementDropsOnlyItself() throws {
    let json = """
      {
        "schemaVersion": 1, "savedAt": "2026-08-08T10:00:00Z",
        "windows": [
          {"windowKey": "W1", "isKey": false, "targets": [], "workroomSplits": []},
          {"nope": 1},
          {"windowKey": "W2", "isKey": true, "targets": [], "workroomSplits": []}
        ]
      }
      """
    let file = try decode(json)
    XCTAssertEqual(file.windows.map(\.windowKey), ["W1", "W2"])
  }

  /// A tab whose kind requires a payload it does not carry is not restorable.
  func testTabMissingItsPayloadIsDropped() throws {
    let json = """
      {
        "schemaVersion": 1, "savedAt": "2026-08-08T10:00:00Z",
        "windows": [{
          "windowKey": "W1", "isKey": true, "workroomSplits": [],
          "targets": [{
            "targetID": "root|/p",
            "tabs": [
              {"key": "t1", "kind": "diff"},
              {"key": "t2", "kind": "terminal", "terminal": {"defaultTitle": "Terminal 1"}}
            ]
          }]
        }]
      }
      """
    let (sanitized, report) = try decode(json).sanitized()
    XCTAssertEqual(sanitized.windows.first?.targets.first?.tabs.map(\.key), ["t2"])
    XCTAssertEqual(report.droppedTabs, 1)
  }

  // MARK: Versioning

  func testNewerSchemaIsReadOnly() throws {
    let file = try decode(
      golden.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 999"))
    XCTAssertEqual(file.compatibility, .newer)
  }

  func testOlderSchemaWithoutMigrationIsUnreadable() throws {
    let file = try decode(
      golden.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 0"))
    XCTAssertEqual(file.compatibility, .unreadable)
  }

  func testAbsentAndGarbageDocumentsFailToDecode() {
    XCTAssertThrowsError(try decode("{}"))
    XCTAssertThrowsError(try decode("not json at all"))
  }

  // MARK: LayoutNode

  private func node(_ leaf: String) -> LayoutNode<String> { .leaf(leaf) }

  private func split(
    _ first: LayoutNode<String>, _ second: LayoutNode<String>, ratio: Double = 0.5
  ) -> LayoutNode<String> {
    .split(orientation: LayoutNode<String>.horizontal, ratio: ratio, first: first, second: second)
  }

  func testMaterializeCollapsesAnUnresolvableLeaf() {
    let tree = split(node("a"), split(node("b"), node("c")))
    let live = tree.materialize { $0 == "b" ? nil : $0 }
    XCTAssertEqual(live?.tabIDs, ["a", "c"])
  }

  /// Fewer than two survivors is not a split — the caller must never be handed a one-leaf tree.
  func testMaterializeReturnsNilBelowTwoSurvivors() {
    let tree = split(node("a"), node("b"))
    XCTAssertNil(tree.materialize { $0 == "a" ? $0 : nil })
    XCTAssertNil(tree.materialize { _ -> String? in nil })
  }

  func testMaterializeRejectsUnknownOrientation() {
    let tree = LayoutNode<String>.split(
      orientation: "diagonal", ratio: 0.5, first: node("a"), second: node("b"))
    XCTAssertNil(tree.materialize { $0 })
  }

  /// A hand-edited 0 or 1 would model a fully collapsed pane; `PaneRatio.sanitize` is what stops it.
  func testMaterializeSanitizesRatio() throws {
    let collapsed = split(node("a"), node("b"), ratio: 0)
    let live = try XCTUnwrap(collapsed.materialize { $0 })
    guard case .split(_, _, let ratio, _, _) = live else {
      return XCTFail("expected a split")
    }
    XCTAssertGreaterThan(ratio, 0)
    XCTAssertLessThan(ratio, 1)
  }

  func testCaptureDropsUnaddressableLeafAndCollapses() {
    let runtime = PaneLayout.split(
      id: UUID(), orientation: .vertical, ratio: 0.5,
      first: .leaf("a"),
      second: .split(
        id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf("b"), second: .leaf("c")))
    let captured = LayoutNode<String>.capture(runtime) { $0 == "b" ? nil : $0 }
    XCTAssertEqual(captured?.leaves, ["a", "c"])
    XCTAssertNil(LayoutNode<String>.capture(runtime) { _ -> String? in nil })
  }

  func testCaptureRoundTripsThroughMaterialize() throws {
    let runtime = PaneLayout.split(
      id: UUID(), orientation: .vertical, ratio: 0.25,
      first: .leaf("a"), second: .leaf("b"))
    let captured = try XCTUnwrap(LayoutNode<String>.capture(runtime) { $0 })
    let live = try XCTUnwrap(captured.materialize { $0 })
    XCTAssertEqual(live.tabIDs, ["a", "b"])
    guard case .split(_, let orientation, let ratio, _, _) = live else {
      return XCTFail("expected a split")
    }
    XCTAssertEqual(orientation, .vertical)
    XCTAssertEqual(ratio, 0.25, accuracy: 0.0001)
  }

  // MARK: Structural validation

  /// Duplicate keys are the dangerous corruption: restore builds dictionaries from them, so a
  /// duplicate would silently point a split leaf or the focus at the wrong pane.
  func testDuplicateKeysAreDropped() {
    let tab = TabSession(
      key: "t1", kind: TabSession.terminalKind,
      terminal: TerminalPayload(defaultTitle: "Terminal 1", cwd: nil))
    var second = tab
    second.terminal?.defaultTitle = "Impostor"
    let window = WindowSession(
      windowKey: "W1",
      targets: [
        TargetSession(targetID: "root|/p", tabs: [tab, second]),
        TargetSession(targetID: "root|/p", tabs: [tab]),
      ])
    let file = SessionFile(savedAt: Date(timeIntervalSince1970: 0), windows: [window, window])

    let (sanitized, report) = file.sanitized()
    XCTAssertEqual(sanitized.windows.count, 1)
    XCTAssertEqual(report.droppedWindows, 1)
    XCTAssertEqual(sanitized.windows[0].targets.count, 1)
    XCTAssertEqual(report.droppedTargets, 1)
    XCTAssertEqual(sanitized.windows[0].targets[0].tabs.count, 1)
    XCTAssertEqual(sanitized.windows[0].targets[0].tabs[0].terminal?.defaultTitle, "Terminal 1")
    XCTAssertEqual(report.droppedTabs, 1)
  }

  func testCapsAreEnforcedAndReported() {
    let tabs = (0..<(SessionLimits.maxTabsPerTarget + 5)).map {
      TabSession(
        key: "t\($0)", kind: TabSession.terminalKind,
        terminal: TerminalPayload(defaultTitle: "Terminal \($0)", cwd: nil))
    }
    let targets = (0..<(SessionLimits.maxTargetsPerWindow + 3)).map {
      TargetSession(targetID: "wr|/p|w\($0)", tabs: tabs)
    }
    let windows = (0..<(SessionLimits.maxWindows + 2)).map {
      WindowSession(windowKey: "W\($0)", targets: targets)
    }
    let (sanitized, report) = SessionFile(
      savedAt: Date(timeIntervalSince1970: 0), windows: windows
    ).sanitized()

    XCTAssertEqual(sanitized.windows.count, SessionLimits.maxWindows)
    XCTAssertEqual(report.droppedWindows, 2)
    XCTAssertEqual(sanitized.windows[0].targets.count, SessionLimits.maxTargetsPerWindow)
    XCTAssertEqual(sanitized.windows[0].targets[0].tabs.count, SessionLimits.maxTabsPerTarget)
    XCTAssertGreaterThan(report.droppedTargets, 0)
    XCTAssertGreaterThan(report.droppedTabs, 0)
  }

  func testOverlongStringsAreClamped() {
    let long = String(repeating: "x", count: SessionLimits.maxStringLength + 500)
    let file = SessionFile(
      savedAt: Date(timeIntervalSince1970: 0),
      windows: [
        WindowSession(
          windowKey: "W1",
          targets: [
            TargetSession(
              targetID: "root|/p",
              tabs: [
                TabSession(
                  key: "t1", kind: TabSession.fileKind,
                  file: FilePayload(path: long, isPreview: false, markdownPreview: nil))
              ])
          ])
      ])
    let (sanitized, _) = file.sanitized()
    let path = sanitized.windows[0].targets[0].tabs[0].file?.path
    XCTAssertEqual(path?.count, SessionLimits.maxStringLength)
  }

  func testDeepSplitTreeIsRejectedButItsTabsSurvive() {
    var tree = LayoutNode<String>.leaf("t0")
    for index in 1...(SessionLimits.maxSplitDepth + 2) {
      tree = split(tree, node("t\(index)"))
    }
    let tabs = (0...(SessionLimits.maxSplitDepth + 2)).map {
      TabSession(
        key: "t\($0)", kind: TabSession.terminalKind,
        terminal: TerminalPayload(defaultTitle: "Terminal \($0)", cwd: nil))
    }
    let file = SessionFile(
      savedAt: Date(timeIntervalSince1970: 0),
      windows: [
        WindowSession(
          windowKey: "W1",
          targets: [TargetSession(targetID: "root|/p", tabs: tabs, split: tree)])
      ])
    let (sanitized, report) = file.sanitized()
    XCTAssertNil(sanitized.windows[0].targets[0].split)
    XCTAssertFalse(sanitized.windows[0].targets[0].tabs.isEmpty)
    XCTAssertEqual(report.droppedSplits, 1)
  }

  func testSplitLeafPointingAtADroppedTabCollapses() {
    let tabs = [
      TabSession(
        key: "t1", kind: TabSession.terminalKind,
        terminal: TerminalPayload(defaultTitle: "Terminal 1", cwd: nil)),
      TabSession(key: "t2", kind: "unknown-kind"),
    ]
    let file = SessionFile(
      savedAt: Date(timeIntervalSince1970: 0),
      windows: [
        WindowSession(
          windowKey: "W1",
          targets: [
            TargetSession(
              targetID: "root|/p", tabs: tabs, split: split(node("t1"), node("t2")),
              focusedKey: "t2")
          ])
      ])
    let (sanitized, _) = file.sanitized()
    let target = sanitized.windows[0].targets[0]
    XCTAssertEqual(target.tabs.map(\.key), ["t1"])
    XCTAssertNil(target.split, "a split with one live leaf is not a split")
    XCTAssertNil(target.focusedKey, "focus on a dropped tab must not survive")
  }

  func testTargetWithNoSurvivingTabsIsDropped() {
    let file = SessionFile(
      savedAt: Date(timeIntervalSince1970: 0),
      windows: [
        WindowSession(
          windowKey: "W1",
          targets: [
            TargetSession(targetID: "root|/p", tabs: [TabSession(key: "t1", kind: "unknown")])
          ])
      ])
    let (sanitized, report) = file.sanitized()
    XCTAssertTrue(sanitized.windows[0].targets.isEmpty)
    XCTAssertEqual(report.droppedTargets, 1)
  }

  /// One preview tab per target is an invariant of the live model; a second is demoted, not dropped.
  func testSecondPreviewTabIsPersistedRatherThanDropped() {
    let file = SessionFile(
      savedAt: Date(timeIntervalSince1970: 0),
      windows: [
        WindowSession(
          windowKey: "W1",
          targets: [
            TargetSession(
              targetID: "root|/p",
              tabs: [
                TabSession(
                  key: "t1", kind: TabSession.fileKind,
                  file: FilePayload(path: "a.txt", isPreview: true, markdownPreview: nil)),
                TabSession(
                  key: "t2", kind: TabSession.fileKind,
                  file: FilePayload(path: "b.txt", isPreview: true, markdownPreview: nil)),
              ])
          ])
      ])
    let (sanitized, _) = file.sanitized()
    let tabs = sanitized.windows[0].targets[0].tabs
    XCTAssertEqual(tabs.count, 2)
    XCTAssertEqual(tabs[0].file?.isPreview, true)
    XCTAssertEqual(tabs[1].file?.isPreview, false)
  }

  // MARK: DiffSource mapping

  func testDiffSourceRoundTripsEveryCase() {
    let sources: [DiffSource] = [.gitWorktree, .jjWorkingCopy, .jjParent, .commit("abc123")]
    for source in sources {
      XCTAssertEqual(DiffSourcePayload(source).source, source)
    }
    XCTAssertNil(DiffSourcePayload(kind: "telepathy", commit: nil).source)
    XCTAssertNil(
      DiffSourcePayload(kind: DiffSourcePayload.commitKind, commit: nil).source,
      "a commit source with no commit id addresses nothing")
  }
}
