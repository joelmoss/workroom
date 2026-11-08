import AppKit
import SwiftUI
import WorkroomDomain
import XCTest

@testable import Workroom

/// `RootView` is the window's composition root: a pass of its body re-evaluates the whole window's
/// view tree. It used to observe every Combine-published object the menus and the title-bar bar
/// read (the notification list, the Room menu's remote state, the updater, the waiting agents), so
/// each of their publishes re-ran it. Those now live in `MenuStateAdapter`, `AccessoryBarInjector`
/// and `WhatsNewLaunchCheck`, which re-run in its place.
///
/// The real `RootView`, hosted with `RootWindow`'s injection stack (and the app-level objects
/// `WorkroomApp` adds), over one project whose directory does not exist, so no terminal opens.
///
/// Each negative test publishes twice and measures the second, as `AdapterGateInvalidationTests`
/// does: the first update of a view type in the process can re-run its body whatever its inputs.
@MainActor
final class RootInvalidationTests: XCTestCase {
  private struct Fixture {
    let store: AppStore
    let updater: Updater
    let root: SidebarID
    let window: NSWindow
    let view: NSView
  }

  private struct NoReleases: ReleasesFetching {
    func releases() async throws -> [GitHubRelease] { [] }
  }

  private func fixture() -> Fixture {
    let store = AppStore()
    store.terminals.sessionService = isolatedPaneSessionService()
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    let path = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("root-invalidation-\(UUID().uuidString)").path
    store.projectStore.projects = [Project(path: path, vcs: "git", workrooms: [])]
    let updater = Updater()
    let (window, hosting) = hostInWindow(
      RootView()
        .themeTokensRoot()
        .environmentObject(store)
        .paneHost(store)
        .environmentObject(store.modals)
        .environmentObject(store.runCommand)
        .environmentObject(store.runCommands)
        .environmentObject(store.projectStore)
        .environmentObject(store.vcsStatus)
        .environmentObject(store.lifecycle)
        .environmentObject(store.notifications)
        .environmentObject(store.terminals.codingAgentManager)
        .environmentObject(store.remoteState)
        .environmentObject(updater)
        .environmentObject(WhatsNewService(fetcher: NoReleases(), currentVersion: nil))
        .environmentObject(CodingAgentUsageMonitor.shared)
        .environmentObject(ClaudeUsageBridge.shared)
        .frame(width: 1000, height: 640),
      size: NSSize(width: 1000, height: 640), styleMask: [.titled, .resizable])
    return Fixture(
      store: store, updater: updater, root: .root(project: path), window: window, view: hosting)
  }

  private func resetPasses() {
    RootView.bodyPasses = 0
    MenuStateAdapter.bodyPasses = 0
    AccessoryBarInjector.bodyPasses = 0
  }

  /// A notification for a pane in no window: the list publishes, and nothing `RootView` draws
  /// changes.
  private func recordNotification(_ store: AppStore) {
    store.notifications.record(
      targetID: .workroom(project: "/elsewhere", name: "foo"), tabID: UUID(),
      activity: .osc(title: "build finished", body: nil), focused: false)
  }

  private func hosted(_ f: Fixture) {
    settle(f.view)
    XCTAssertGreaterThan(RootView.bodyPasses, 0, "the fixture must actually render RootView")
    XCTAssertGreaterThan(MenuStateAdapter.bodyPasses, 0, "the fixture must render the menu state")
    XCTAssertGreaterThan(AccessoryBarInjector.bodyPasses, 0, "the fixture must host the bar")
  }

  func testANotificationReRunsTheMenuStateNotTheRoot() {
    let f = fixture()
    defer { f.window.close() }
    hosted(f)
    recordNotification(f.store)
    settle(f.view)

    resetPasses()
    recordNotification(f.store)
    // The full settle, not until the adapter runs: a root pass a slice later must still count.
    settle(f.view)

    XCTAssertEqual(f.store.notifications.items.count, 2, "both notifications landed")
    XCTAssertGreaterThan(
      MenuStateAdapter.bodyPasses, 0, "the menu state reads the list, so it must re-run")
    XCTAssertEqual(RootView.bodyPasses, 0, "a notification must not re-run the window's root")
  }

  func testARemoteStatePublishReRunsTheMenuStateNotTheRoot() {
    let f = fixture()
    defer { f.window.close() }
    hosted(f)
    f.store.remoteState.dismissFailureReport()
    settle(f.view)

    resetPasses()
    f.store.remoteState.dismissFailureReport()
    settle(f.view)

    XCTAssertGreaterThan(
      MenuStateAdapter.bodyPasses, 0, "the menu state reads Fetch/Push/Pull, so it must re-run")
    XCTAssertEqual(RootView.bodyPasses, 0, "a remote-state step must not re-run the window's root")
  }

  func testAnUpdaterPublishReRunsTheBarNotTheRoot() {
    let f = fixture()
    defer { f.window.close() }
    hosted(f)
    f.updater.canCheckForUpdates.toggle()
    settle(f.view)

    resetPasses()
    f.updater.canCheckForUpdates.toggle()
    settle(f.view)

    XCTAssertGreaterThan(
      AccessoryBarInjector.bodyPasses, 0,
      "the bar's injector observes the updater, so the accessory gets a fresh root")
    XCTAssertEqual(RootView.bodyPasses, 0, "an updater publish must not re-run the window's root")
  }

  /// The control: the selection is what `RootView` renders from, so it must still re-run, and the
  /// menu state with it.
  func testSelectionStillReRunsTheRoot() {
    let f = fixture()
    defer { f.window.close() }
    hosted(f)

    resetPasses()
    f.store.selectedTargetID = f.root
    settle(f.view, until: { RootView.bodyPasses > 0 && MenuStateAdapter.bodyPasses > 0 })

    XCTAssertGreaterThan(RootView.bodyPasses, 0, "the selection must re-run the window's root")
    XCTAssertGreaterThan(MenuStateAdapter.bodyPasses, 0, "and the menu state, which reads it too")
  }

  /// Pins the shape the tests above measure: the Combine-published objects stay out of `RootView`,
  /// where one publish re-runs the whole window body.
  func testRootViewObservesNoCombineObject() throws {
    let file = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WorkroomAppTests
        .deletingLastPathComponent()  // macapp
        .appendingPathComponent("WorkroomApp/Views/AppShell/RootView.swift"),
      encoding: .utf8)
    // Code only: the comments may name what RootView no longer holds.
    let source = file.components(separatedBy: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    XCTAssertTrue(
      source.contains("@EnvironmentObject var store: AppStore"),
      "parse looks wrong — RootView takes the store")
    for type in [
      "NotificationCenterStore", "RemoteStateModel", "Updater", "WhatsNewService",
      "ProgramStatusAlerts",
    ] {
      XCTAssertNil(
        source.range(
          of: #"\b(var|let)\s+\w+\s*(:\s*\#(type)\b|=\s*\#(type)\.)"#, options: .regularExpression),
        "RootView holds `\(type)`: observe it in the adapter that renders from it")
    }
    XCTAssertFalse(source.contains("@ObservedObject"), "RootView observes an ObservableObject")
    XCTAssertFalse(source.contains("@StateObject"), "RootView owns an ObservableObject")
  }
}
