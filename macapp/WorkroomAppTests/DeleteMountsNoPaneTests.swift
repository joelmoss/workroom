import AppKit
import SwiftUI
import WorkroomDomain
import XCTest

@testable import Workroom

/// Deleting a workroom must not open a terminal in it: the pane would be freed moments later, with
/// its attach still arriving, which is the window of the #547 freeze.
///
/// Hosts the real pane views, because the terminal is opened by the leaving pane's `.task`, which a
/// test of the store alone never runs.
@MainActor
final class DeleteMountsNoPaneTests: XCTestCase {
  private let projectPath = "/private/var/tmp/wr-delete-pane"
  private var goneID: TerminalTarget.ID {
    TerminalTarget.workroomID(project: projectPath, name: "gone")
  }

  /// `RootView.workroomSplitBody`, without the window chrome.
  private struct Host: View {
    @ObservedObject var store: AppStore

    var body: some View {
      if let selected = store.selectedTargetID {
        WorkroomSplitView(
          store: store,
          layout: store.visibleWorkroomLayout(for: selected),
          resolve: { store.target(for: $0) },
          focusedID: selected,
          externalDrag: .constant(nil),
          localize: { _ in nil },
          dropTarget: { _ in nil },
          onFocus: { _ in },
          onSetRatio: { _, _ in },
          onClose: { _ in },
          onMove: { _, _, _, _ in }
        )
      }
    }
  }

  private struct Fixture {
    let store: AppStore
    let project: Project
    let cli: FakeWorkroomCLI
    let window: NSWindow
    let opened: () -> [String]
  }

  /// `gone`'s create failed, so its terminal is withheld behind the create's pane, and it is selected.
  private func makeFixture() async -> Fixture {
    let workrooms = ["gone", "stays"].map {
      Workroom(name: $0, path: "\(projectPath)/.workrooms/\($0)", vcsName: "git", warnings: [])
    }
    let project = Project(path: projectPath, vcs: "git", workrooms: workrooms)
    let cli = FakeWorkroomCLI(canonical: projectPath, projects: [project])
    let store = AppStore(cli: cli)
    var opened: [String] = []
    store.terminals.makeView = { target, cwd, _ in
      opened.append(target.id)
      return GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    store.terminals.recency = SwitcherRecency()
    store.projects = [project]
    store.terminals.addTab(for: workrooms[1].target(inProject: projectPath))

    let run = CreationRun(
      project: Project(path: projectPath, vcs: "git", workrooms: []), kind: .local,
      splitAnchor: nil, previousSelection: nil)
    run.setName("gone")
    run.fail(.setupScriptFailed(message: "exit 1"))
    store.creationRuns[run.id] = run
    store.creationRunForTarget[goneID] = run.id
    store.selectedTargetID = .workroom(project: projectPath, name: "gone")

    let hosting = NSHostingView(
      rootView: Host(store: store)
        .detachedPaneEnvironment(store: store, sessions: store.terminals))
    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFront(nil)
    await settle()
    XCTAssertFalse(opened.contains(goneID), "precondition: withheld behind its create")
    return Fixture(store: store, project: project, cli: cli, window: window, opened: { opened })
  }

  private func settle() async {
    try? await Task.sleep(for: .seconds(0.6))
  }

  /// Value: protects=a delete never opens a terminal in the workroom it is removing, which would be
  /// freed mid-attach (#547); fails_when=the leaving pane's `.task` opens one; no_claim=whether a
  /// surface freed that way hangs
  func testDeletingAFailedCreateOpensNoTerminal() async {
    let fixture = await makeFixture()
    defer { fixture.window.close() }
    fixture.cli.projectsToList = [
      Project(
        path: projectPath, vcs: "git",
        workrooms: fixture.project.workrooms.filter { $0.name != "gone" })
    ]

    fixture.store.deleteWorkroom(fixture.project.workrooms[0], in: fixture.project)
    await settle()

    XCTAssertFalse(fixture.opened().contains(goneID), "opened: \(fixture.opened())")
  }

  /// Value: protects=a project delete opens no terminal either, its targets dropped the same way;
  /// fails_when=the guard reads a tombstone of the workroom alone; no_claim=the project's teardown
  func testDeletingTheProjectOfAFailedCreateOpensNoTerminal() async {
    let fixture = await makeFixture()
    defer { fixture.window.close() }
    fixture.cli.projectsToList = []

    fixture.store.deleteProject(fixture.project, scope: .configOnly)
    await settle()

    XCTAssertFalse(fixture.opened().contains(goneID), "opened: \(fixture.opened())")
  }
}
