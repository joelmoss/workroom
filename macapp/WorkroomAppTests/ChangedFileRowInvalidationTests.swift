import AppKit
import SwiftUI
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// The Changes panel's half of the WORKROOM-2B fix.
///
/// `ChangedFileRow` had the identical defect the History rows did — `@ObservedObject TerminalSessions`
/// held purely to compute `isSelected` — just bounded at `renderCap` (200) instead of the whole commit
/// log, which is why it never crossed the 2-second app-hang threshold on its own. The lookup now lives
/// in the panel, and the file list is an eager `VStack`, so the row's equality gate is what keeps a
/// status change from rebuilding all 200 bodies. This suite proves both: pulses rebuild no row, and
/// the gate elides the rows a change did not touch.
@MainActor
final class ChangedFileRowInvalidationTests: XCTestCase {
  private let projectPath = "/changes-invalidation"
  private let workroomName = "solo"

  private func makeStore(changedFiles: [ChangedFile]) -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = [
      Project(
        path: projectPath, vcs: "git",
        workrooms: [
          Workroom(
            name: workroomName, path: "\(projectPath)/\(workroomName)",
            vcsName: "workroom/\(workroomName)", warnings: [])
        ])
    ]
    store.inspectorVisibleOverrideForTesting = true
    store.isolatesInspectorSectionForTesting = true
    store.isolatesInspectorLayoutForTesting = true
    store.activeInspectorSection = .changes
    let target = store.target(for: .workroom(project: projectPath, name: workroomName))!
    _ = store.terminals.addTab(for: target)
    store.selectedTargetID = .workroom(project: projectPath, name: workroomName)
    // Selecting a workroom schedules a real status probe (debounced 0.3 s). Against this fixture's
    // non-existent path it lands a status with no changed files, emptying the panel, at a time set by
    // the runner's load: about 0.35 s warm, 0.8 s cold, later on CI. Left running, it emptied the panel
    // mid-measurement, so the selection test saw no rows rebuild, and a warm pulse burst measured no
    // rows at all. The tests measure rows, not the probe, so none runs.
    XCTAssertNotNil(
      store.selectionStatusTask,
      "selecting no longer schedules the probe here, so this cancels nothing")
    store.selectionStatusTask?.cancel()
    // `lastChecked` is load-bearing, not decoration: `ChangesPanel.content(for:)` renders "Checking…"
    // (and therefore NO rows) while it is nil, which would make every assertion here vacuously true.
    store.workroomStatuses[.workroom(project: projectPath, name: workroomName)] = WorkroomStatus(
      dirty: true, changedFiles: changedFiles, lastChecked: Date())
    return store
  }

  private func files(_ count: Int) -> [ChangedFile] {
    (0..<count).map { ChangedFile(path: "src/file\($0).swift", change: .modified) }
  }

  private func host(_ store: AppStore) -> (NSWindow, NSView) {
    let root = ChangesPanel(sessions: store.terminals)
      .environmentObject(store)
      .environmentObject(store.notifications)
      .frame(width: 320, height: 420)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false  // ARC is the sole owner (see PaneRenderingTests.host)
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    return (window, hosting)
  }

  /// What the equality gate is for. When a status sweep changes the list, the panel rebuilds every row
  /// from the new status and SwiftUI asks each row's `==`. Only the new row may get a body; without
  /// the gate, one more changed file rebuilds all `renderCap` rows.
  func testStatusChangeRebuildsOnlyTheChangedFileRow() throws {
    let store = makeStore(changedFiles: files(60))
    let (window, view) = host(store)
    defer {
      Task { await store.terminals.reapAll() }
      window.close()
    }
    settle(view)
    XCTAssertGreaterThan(
      ChangedFileRow.bodyPasses, 0, "the fixture must actually render changed-file rows")

    ChangedFileRow.bodyPasses = 0
    store.mergeLocalStatus(
      WorkroomStatus(dirty: true, changedFiles: files(61)),
      into: .workroom(project: projectPath, name: workroomName))
    settle(view)

    // Exactly one, not "at most one": zero would mean the panel never re-rendered, which would let a
    // broken gate pass unseen.
    XCTAssertEqual(
      ChangedFileRow.bodyPasses, 1,
      "one file joined the list, so only its row may rebuild; the other 60 are equal to what they "
        + "were and the equality gate must elide them")
  }

  /// A terminal pulse rebuilds no row by any route. It does not reach the equality gate: the panel
  /// re-renders once per burst, yet SwiftUI never asks a row's `==` (measured for #538: zero calls,
  /// and no rebuilds with `==` forced false). The gate is pinned by
  /// `testStatusChangeRebuildsOnlyTheChangedFileRow`; this test pins the original WORKROOM-2B defect,
  /// a row that observes `TerminalSessions` itself and so rebuilds on every pulse, gate or not.
  func testTerminalPulseBurstRebuildsNoChangedFileRows() throws {
    let store = makeStore(changedFiles: files(60))
    let (window, view) = host(store)
    defer {
      Task { await store.terminals.reapAll() }
      window.close()
    }
    // No early-exit condition here: this settle must fully drain the initial render's transient
    // extra passes, or stray late renders leak into the pulse-burst measurement window below and
    // spuriously fail the "must rebuild NOTHING" assertion (found by running the mutation check).
    settle(view)
    let target = store.target(for: .workroom(project: projectPath, name: workroomName))!
    guard let tab = store.terminals.focusedTab(for: target) else {
      return XCTFail("the fixture workroom must have a focused tab")
    }
    // Anti-vacuity guard: "0 rebuilds" only means anything if rows rendered in the first place. A
    // fixture missing `lastChecked` renders "Checking…" and would pass this test having drawn nothing.
    XCTAssertGreaterThan(
      ChangedFileRow.bodyPasses, 0, "the fixture must actually render changed-file rows")

    ChangedFileRow.bodyPasses = 0
    for _ in 0..<25 { store.terminals.pulsePaneActivity(tab.id) }
    settle(view)

    // Still listed after the burst: a status that emptied the panel before or during it would turn
    // "0 rebuilds" into "there were no rows".
    XCTAssertNotNil(
      store.workroomStatuses[.workroom(project: projectPath, name: workroomName)]?.changedFiles,
      "the fixture's changed files must still be listed through the pulse burst")

    XCTAssertEqual(
      ChangedFileRow.bodyPasses, 0,
      "a terminal activity pulse says nothing about any changed file, so it must rebuild no rows")
  }

  /// A theme change must repaint the rows, every one of them, selected or not.
  ///
  /// Unlike `HistoryRow`, this row needs no theme input to its equality gate: its change letter's
  /// colour reads `theme.tokens` outside any ternary, so each row repaints by Observation. This test
  /// pins that read: a row whose only theme reads sat inside its hover/selection ternaries would keep
  /// the old theme's colours.
  func testThemeChangeRebuildsChangedFileRows() throws {
    let store = makeStore(changedFiles: files(20))
    let (window, view) = host(store)
    defer {
      Task { await store.terminals.reapAll() }
      window.close()
    }
    settle(view, until: { ChangedFileRow.bodyPasses > 0 })
    XCTAssertGreaterThan(
      ChangedFileRow.bodyPasses, 0, "the fixture must actually render changed-file rows")

    ChangedFileRow.bodyPasses = 0
    ThemeService.shared.applyActiveTheme(force: true)
    settle(view, until: { ChangedFileRow.bodyPasses > 0 })

    XCTAssertGreaterThan(
      ChangedFileRow.bodyPasses, 0, "a theme change must repaint the changed-file rows")
  }

  /// The positive half: a selection change MUST still reach the rows.
  ///
  /// Selection is moved by re-focusing an existing tab, not by opening a new one, deliberately.
  /// Re-focusing publishes `focusedTabByTarget` only, so the ONLY thing that changes is which row is
  /// selected — which is exactly the property under test.
  func testSelectionChangeRebuildsChangedFileRows() throws {
    let store = makeStore(changedFiles: files(20))
    let target = store.target(for: .workroom(project: projectPath, name: workroomName))!
    let terminalTab = store.terminals.focusedTab(for: target)!
    // Open the diff BEFORE hosting, so the first render already has a selected row.
    store.openDiffPreview(
      ChangedFile(path: "src/file0.swift", change: .modified), source: .gitWorktree)

    ChangedFileRow.bodyPasses = 0
    let (window, view) = host(store)
    defer {
      Task { await store.terminals.reapAll() }
      window.close()
    }
    settle(view)

    XCTAssertEqual(
      FocusedTabSelection.current(store: store, sessions: store.terminals),
      .diff(path: "src/file0.swift", source: .gitWorktree), "file0's diff must be the focused tab")
    // Counted from the first render: a row no longer rebuilds on an unrelated `AppStore` change, so
    // nudging the store can't show the rows are there.
    XCTAssertGreaterThan(
      ChangedFileRow.bodyPasses, 0,
      "rows must be on screen when the measurement window opens — otherwise 'the rows rebuilt' and "
        + "'there were no rows' are indistinguishable")

    ChangedFileRow.bodyPasses = 0
    // Focusing the terminal tab clears the selection (a terminal selects no inspector row).
    store.terminals.focus(terminalTab.id, for: target)
    settle(view, until: { ChangedFileRow.bodyPasses > 0 })

    XCTAssertNil(FocusedTabSelection.current(store: store, sessions: store.terminals))
    XCTAssertGreaterThan(
      ChangedFileRow.bodyPasses, 0,
      "moving focus off the diff clears file0's selected state, so the affected rows MUST rebuild — "
        + "the positive half of the equality gate, and what stops it from freezing the highlight")
  }
}
