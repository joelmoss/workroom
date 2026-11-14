import AppKit
import SwiftUI
import WorkroomDomain
import XCTest

@testable import Workroom

/// What each workroom menu shows, in order, for each state a workroom is in. The rows were written
/// from the menus as they were built before they became a model (the tab chip's and split title
/// bar's shared builder, the sidebar row's inline list and the inspector header's actions menu),
/// so these pin that behaviour: any change to an item, its order, its divider or
/// its enabled state shows up here.
@MainActor
final class WorkroomMenuModelTests: XCTestCase {
  private typealias Entry = WorkroomMenuModel.Entry

  /// Run configured and not running, as a workroom with a run command and no run yet.
  private let idle = RunMenuState(available: true, configured: true, running: false)
  private let running = RunMenuState(available: true, configured: true, running: true)
  /// A create still setting the workroom up: every run item off (`isRunBlocked`).
  private let blocked = RunMenuState(available: false, configured: true, running: false)

  /// A sidebar row's entries for `model`'s workroom: the full menu, as its row builds it, with no
  /// Close and no Remove from Split (`SidebarWorkroomRow`'s `WorkroomMenuAdapter`).
  private func sidebarRowEntries(_ model: WorkroomMenuModel) -> [Entry] {
    var row = model
    row.closeName = nil
    row.removableFromSplit = false
    return row.entries(for: .full)
  }

  private func runItems(_ state: RunMenuState) -> [Entry] {
    [
      .run(enabled: state.available && state.configured),
      .restart(enabled: state.available && state.running),
      .stop(enabled: state.available && state.running),
    ]
  }

  // MARK: A gone host

  /// Value: protects=a workroom whose host its provider no longer has offers Remove Workroom and
  /// nothing else, on every menu (#623 story 26, #629); fails_when=a run, label, split, close or
  /// move item still shows for it; seam=WorkroomMenuModel.entries
  func testAWorkroomWhoseHostIsGoneOffersOnlyRemove() {
    let model = WorkroomMenuModel(
      run: idle, closeName: "fix-auth", removableFromSplit: true, canOpenInSplit: true,
      showsMoveToNewWindow: true, canMoveWorkroom: true,
      workroom: .init(hasLabel: true, hostGone: true))
    XCTAssertEqual(model.entries(for: .full), [.remove])
    XCTAssertEqual(model.entries(for: .inspectorHeader), [.remove])
  }

  // MARK: A root

  /// A project root on its tab chip: Close names the project, and there is nothing to label or
  /// delete. The divider after the run items is always there.
  func testARoot() {
    let model = WorkroomMenuModel(
      run: idle, closeName: "proj", showsMoveToNewWindow: true, canMoveWorkroom: true)
    XCTAssertEqual(
      model.entries(for: .full),
      runItems(idle) + [.divider, .close, .moveToNewWindow(enabled: true)])
    XCTAssertEqual(model.entries(for: .inspectorHeader), [.moveToNewWindow(enabled: true)])
  }

  /// A root with no terminals in this window and no split to open: only its run items and the
  /// divider after them, on a chip whose Close a create withholds; the inspector's menu is empty.
  func testARootWithNothingElseToOffer() {
    let model = WorkroomMenuModel(run: idle)
    XCTAssertEqual(model.entries(for: .full), runItems(idle) + [.divider])
    XCTAssertEqual(model.entries(for: .inspectorHeader), [])
  }

  // MARK: A workroom

  func testAWorkroom() {
    let model = WorkroomMenuModel(
      run: idle, closeName: "feature", canOpenInSplit: true, showsMoveToNewWindow: true,
      canMoveWorkroom: true, workroom: .init())
    XCTAssertEqual(
      model.entries(for: .full),
      runItems(idle) + [
        .divider, .close, .openInSplit, .moveToNewWindow(enabled: true),
        .divider, .label(exists: false), .divider, .delete(enabled: true),
      ])
    // The sidebar row has no Close and no Remove from Split, in the same order otherwise.
    XCTAssertEqual(
      sidebarRowEntries(model),
      runItems(idle) + [
        .divider, .openInSplit, .moveToNewWindow(enabled: true),
        .divider, .label(exists: false), .divider, .delete(enabled: true),
      ])
    // The inspector has no run or split items, and no Close.
    XCTAssertEqual(
      model.entries(for: .inspectorHeader),
      [
        .moveToNewWindow(enabled: true), .divider, .label(exists: false), .divider,
        .delete(enabled: true),
      ])
  }

  /// The divider above the label items shows only when an item showed above it, on the chip and
  /// the row; the inspector's is always there, so its menu then starts with one.
  func testAWorkroomWithNothingAboveItsLabel() {
    let model = WorkroomMenuModel(run: idle, workroom: .init())
    let tail: [Entry] = [.label(exists: false), .divider, .delete(enabled: true)]
    XCTAssertEqual(model.entries(for: .full), runItems(idle) + [.divider] + tail)
    XCTAssertEqual(sidebarRowEntries(model), runItems(idle) + [.divider] + tail)
    XCTAssertEqual(model.entries(for: .inspectorHeader), [.divider] + tail)
  }

  // MARK: While creating

  /// A workroom whose create is still setting it up: the chip withholds Close, the run items and
  /// Move to New Window are off, and so is Delete.
  func testWhileCreating() {
    let model = WorkroomMenuModel(
      run: blocked, showsMoveToNewWindow: true, workroom: .init(isCreating: true))
    let tail: [Entry] = [
      .moveToNewWindow(enabled: false), .divider, .label(exists: false), .divider,
      .delete(enabled: false),
    ]
    XCTAssertEqual(model.entries(for: .full), runItems(blocked) + [.divider] + tail)
    XCTAssertEqual(sidebarRowEntries(model), runItems(blocked) + [.divider] + tail)
    XCTAssertEqual(model.entries(for: .inspectorHeader), tail)
  }

  // MARK: A split member

  /// A split's member on its title bar, its run going: Remove from Split after Open (split right),
  /// and Restart and Stop on.
  func testASplitMember() {
    let model = WorkroomMenuModel(
      run: running, closeName: "feature", removableFromSplit: true, canOpenInSplit: true,
      showsMoveToNewWindow: true, canMoveWorkroom: true, workroom: .init())
    XCTAssertEqual(
      model.entries(for: .full),
      runItems(running) + [
        .divider, .close, .openInSplit, .removeFromSplit,
        .moveToNewWindow(enabled: true), .divider, .label(exists: false), .divider,
        .delete(enabled: true),
      ])
    // Its sidebar row builds the model with no Remove from Split, so none shows.
    XCTAssertFalse(sidebarRowEntries(model).contains(.removeFromSplit))
    XCTAssertFalse(model.entries(for: .inspectorHeader).contains(.removeFromSplit))
  }

  /// A root in a split: Remove from Split, and still nothing to label or delete.
  func testARootSplitMember() {
    let model = WorkroomMenuModel(
      run: idle, closeName: "proj", removableFromSplit: true, showsMoveToNewWindow: true,
      canMoveWorkroom: true)
    XCTAssertEqual(
      model.entries(for: .full),
      runItems(idle) + [
        .divider, .close, .removeFromSplit, .moveToNewWindow(enabled: true),
      ])
  }

  // MARK: Labelled

  func testALabelledWorkroom() {
    let model = WorkroomMenuModel(
      run: idle, closeName: "Login", showsMoveToNewWindow: true, canMoveWorkroom: true,
      workroom: .init(hasLabel: true))
    let tail: [Entry] = [
      .moveToNewWindow(enabled: true), .divider, .label(exists: true), .removeLabel, .divider,
      .delete(enabled: true),
    ]
    XCTAssertEqual(
      model.entries(for: .full), runItems(idle) + [.divider, .close] + tail)
    XCTAssertEqual(sidebarRowEntries(model), runItems(idle) + [.divider] + tail)
    XCTAssertEqual(model.entries(for: .inspectorHeader), tail)
  }

  // MARK: A single-workroom window

  /// A window's only workroom: Move to New Window shows, since it has terminals here, but is off,
  /// as the move would leave the window empty; and there is no other workroom to split beside.
  func testASingleWorkroomWindow() {
    let model = WorkroomMenuModel(
      run: idle, closeName: "feature", showsMoveToNewWindow: true, workroom: .init())
    let tail: [Entry] = [
      .moveToNewWindow(enabled: false), .divider, .label(exists: false), .divider,
      .delete(enabled: true),
    ]
    XCTAssertEqual(
      model.entries(for: .full), runItems(idle) + [.divider, .close] + tail)
    XCTAssertEqual(sidebarRowEntries(model), runItems(idle) + [.divider] + tail)
    XCTAssertEqual(model.entries(for: .inspectorHeader), tail)
  }

  // MARK: Run items

  func testTheRunItemsFollowTheirState() {
    let unconfigured = RunMenuState(available: true, configured: false, running: false)
    XCTAssertEqual(
      Array(WorkroomMenuModel(run: unconfigured).entries(for: .full).prefix(3)),
      [.run(enabled: false), .restart(enabled: false), .stop(enabled: false)])
    XCTAssertEqual(
      Array(sidebarRowEntries(WorkroomMenuModel(run: running)).prefix(3)),
      [.run(enabled: true), .restart(enabled: true), .stop(enabled: true)])
  }

  // MARK: From the store

  private let projectPath = "/menu-model/p"
  private var rootSID: SidebarID { .root(project: projectPath) }
  private var featureSID: SidebarID { .workroom(project: projectPath, name: "feature") }
  private var otherSID: SidebarID { .workroom(project: projectPath, name: "other") }

  private func makeStore(label: String? = nil) -> AppStore {
    let store = AppStore()
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    var feature = Workroom(
      name: "feature", path: "\(projectPath)/feature", vcsName: "feature", warnings: [])
    feature.label = label
    let other = Workroom(
      name: "other", path: "\(projectPath)/other", vcsName: "other", warnings: [])
    store.projectStore.projects = [
      Project(path: projectPath, vcs: "git", workrooms: [feature, other])
    ]
    return store
  }

  private func model(
    _ store: AppStore, _ sid: SidebarID, closeName: String? = nil, removable: Bool = false
  ) throws -> WorkroomMenuModel {
    let target = try XCTUnwrap(store.target(for: sid))
    return WorkroomMenuModel(
      store: store, lifecycle: store.lifecycle, sid: sid, target: target, closeName: closeName,
      removableFromSplit: removable)
  }

  func testTheStoreGivesARootNothingToLabelOrDelete() throws {
    let store = makeStore()
    let model = try model(store, rootSID, closeName: "p", removable: true)
    XCTAssertNil(model.workroom)
    XCTAssertEqual(model.closeName, "p")
    XCTAssertTrue(model.removableFromSplit)
    XCTAssertFalse(model.showsMoveToNewWindow, "no terminals here to move")
    XCTAssertFalse(model.canOpenInSplit, "nothing selected to split beside")
  }

  func testTheStoreGivesAWorkroomItsLabel() throws {
    XCTAssertEqual(try model(makeStore(), featureSID).workroom, .init())
    XCTAssertEqual(
      try model(makeStore(label: "Login"), featureSID).workroom, .init(hasLabel: true))
  }

  func testTheStoreSaysWhenAWorkroomIsTheWindowsOnlyOne() throws {
    let store = makeStore()
    _ = store.terminals.addTab(for: try XCTUnwrap(store.target(for: featureSID)))
    var model = try model(store, featureSID)
    XCTAssertTrue(model.showsMoveToNewWindow)
    XCTAssertFalse(model.canMoveWorkroom, "a window's only workroom does not move")
    _ = store.terminals.addTab(for: try XCTUnwrap(store.target(for: otherSID)))
    model = try self.model(store, featureSID)
    XCTAssertTrue(model.canMoveWorkroom)
  }

  func testTheStoreSaysWhileAWorkroomIsBeingCreated() throws {
    let store = makeStore()
    let target = try XCTUnwrap(store.target(for: featureSID))
    store.lifecycle.creatingWorkrooms.insert(target.id)
    defer { store.lifecycle.creatingWorkrooms.remove(target.id) }
    let model = try model(store, featureSID)
    XCTAssertEqual(model.workroom, .init(isCreating: true))
    XCTAssertFalse(model.run.available, "no run while its setup is running")
  }

  // MARK: When the menu is built

  /// A row's `.contextMenu` content is built when the menu opens, not with the row: drawing the
  /// sidebar and re-rendering a workroom row (its hover) run neither the adapter nor the items. So
  /// the menu's store reads are not in any row's body, and the items need no equality gate.
  func testASidebarRowDoesNotBuildItsMenuWhenItRenders() throws {
    let store = makeStore()
    store.collapsedProjects = []
    var hover: Binding<Bool>?
    ProjectSidebar.didRenderHover = { [featureSID] rowID, binding in
      if rowID == featureSID { hover = binding }
    }
    defer { ProjectSidebar.didRenderHover = nil }
    WorkroomMenuAdapter.bodyPasses = 0
    WorkroomMenuItems.bodyPasses = 0
    ProjectSidebar.rowEvaluations = 0
    let hosting = NSHostingView(
      rootView: ProjectSidebar()
        .environmentObject(store)
        .environmentObject(store.runCommand)
        .environmentObject(store.projectStore)
        .environmentObject(store.vcsStatus)
        .environmentObject(store.lifecycle)
        .environmentObject(store.notifications)
        .themeTokensRoot()
        .frame(width: 300, height: 400))
    hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    settle(hosting)
    hosting.displayIfNeeded()
    let binding = try XCTUnwrap(hover, "the workroom row must register its hover binding")
    XCTAssertGreaterThan(ProjectSidebar.rowEvaluations, 0, "must render actual rows")
    for _ in 0..<2 {
      ProjectSidebar.rowEvaluations = 0
      binding.wrappedValue.toggle()
      settle(hosting)
      hosting.displayIfNeeded()
      XCTAssertGreaterThan(ProjectSidebar.rowEvaluations, 0, "the hover must re-render its row")
    }
    XCTAssertEqual(WorkroomMenuAdapter.bodyPasses, 0, "no menu is built while it is closed")
    XCTAssertEqual(WorkroomMenuItems.bodyPasses, 0)

    // Control: the counters do count, drawn outside a menu.
    window.contentView = NSHostingView(
      rootView: VStack {
        WorkroomMenuAdapter(sid: featureSID, target: store.target(for: featureSID), style: .full)
      }
      .environmentObject(store)
      .environmentObject(store.lifecycle))
    settle(try XCTUnwrap(window.contentView))
    window.contentView?.displayIfNeeded()
    XCTAssertGreaterThan(WorkroomMenuAdapter.bodyPasses, 0)
    XCTAssertGreaterThan(WorkroomMenuItems.bodyPasses, 0)
  }
}
