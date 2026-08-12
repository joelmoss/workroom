import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// The Changes panel's half of the WORKROOM-2B fix.
///
/// `ChangedFileRow` had the identical defect the History rows did — `@ObservedObject TerminalSessions`
/// held purely to compute `isSelected` — just bounded at `renderCap` (200) instead of the whole commit
/// log, which is why it never crossed the 2-second app-hang threshold on its own. Hoisting the lookup
/// into the panel is NOT sufficient here: the panel then observes `TerminalSessions` itself, and the
/// file list is an eager `VStack`, so without an equality gate on the row every pulse would still
/// rebuild all 200 bodies. This suite is what proves the gate is doing that work.
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

  func testTerminalPulseBurstRebuildsNoChangedFileRows() throws {
    let store = makeStore(changedFiles: files(60))
    let (window, view) = host(store)
    defer {
      store.terminals.reapAll()
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

    XCTAssertEqual(
      ChangedFileRow.bodyPasses, 0,
      "a terminal activity pulse says nothing about any changed file, so it must rebuild no rows — "
        + "hoisting the selection lookup alone would not achieve this behind an eager VStack")
  }

  /// A theme change must repaint the rows — the same gate check the History suite makes.
  ///
  /// These rows read their hover/selection tints inside ternaries, so an unselected, unhovered row
  /// registers no Observation dependency on the theme; before the fix they repainted only because
  /// applying a theme also republished `TerminalSessions`, which every row observed. The explicit
  /// `themeGeneration` input is what replaces that accident.
  func testThemeChangeRebuildsChangedFileRows() throws {
    let store = makeStore(changedFiles: files(20))
    let (window, view) = host(store)
    defer {
      store.terminals.reapAll()
      window.close()
    }
    // Let the selection's status probe land and then restore the fixture list, as in the selection test
    // — otherwise the panel is showing its empty state by measurement time and "no rows rebuilt" says
    // nothing about the theme.
    settle(view, seconds: 1.2)
    store.workroomStatuses[.workroom(project: projectPath, name: workroomName)] = WorkroomStatus(
      dirty: true, changedFiles: files(20), lastChecked: Date())
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
  /// Selection is moved by re-focusing an existing tab, not by opening a new one, deliberately. Opening
  /// a tab changes the target's tab count, which trips a real status refresh — and against this
  /// fixture's non-existent repo path that probe lands a status with `changedFiles == nil`, so the panel
  /// renders its empty state and the row count drops to zero. That made an earlier version of this test
  /// fail for a reason that had nothing to do with the equality gate. Re-focusing publishes
  /// `focusedTabByTarget` only, so the fixture status stays put and the ONLY thing that changes is which
  /// row is selected — which is exactly the property under test.
  func testSelectionChangeRebuildsChangedFileRows() throws {
    let store = makeStore(changedFiles: files(20))
    let target = store.target(for: .workroom(project: projectPath, name: workroomName))!
    let terminalTab = store.terminals.focusedTab(for: target)!
    // Open the diff BEFORE hosting, so the status settles once and the first render already has a
    // selected row.
    store.openDiffPreview(
      ChangedFile(path: "src/file0.swift", change: .modified), source: .gitWorktree)
    store.workroomStatuses[.workroom(project: projectPath, name: workroomName)] = WorkroomStatus(
      dirty: true, changedFiles: files(20), lastChecked: Date())

    let (window, view) = host(store)
    defer {
      store.terminals.reapAll()
      window.close()
    }
    // Let the tab-open status probe land and be overwritten BEFORE the measurement window opens. That
    // probe runs `git status` against a path that doesn't exist, and its result (no `changedFiles`)
    // makes the panel render its empty state — which is not a fact about the equality gate.
    settle(view, seconds: 1.2)
    store.workroomStatuses[.workroom(project: projectPath, name: workroomName)] = WorkroomStatus(
      dirty: true, changedFiles: files(20), lastChecked: Date())
    settle(view)

    XCTAssertEqual(
      FocusedTabSelection.current(store: store, sessions: store.terminals),
      .diff(path: "src/file0.swift", source: .gitWorktree), "file0's diff must be the focused tab")
    ChangedFileRow.bodyPasses = 0
    store.workroomStatuses[.workroom(project: projectPath, name: workroomName)]?.dirty = true
    settle(view, until: { ChangedFileRow.bodyPasses > 0 })
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
