import AppKit
import SwiftUI
import WorkroomDomain
import XCTest

@testable import Workroom

/// Two adapters and the store-free views they build. Each adapter re-runs on every publish of an
/// `ObservableObject` it takes from the environment (`NotificationCenterStore` for the toasts;
/// `TerminalCodingAgentManager` and `DetachedSessionList` for a pane's status bar), whether or not
/// anything it shows changed. The view's own body must not re-run with it, and must still re-run
/// when what it shows changes.
///
/// The status bar needs its equality gate for that (the diagnosis test fails without it). The
/// toast stack does not: measured with the gate removed, SwiftUI already skips it, so it has none.
///
/// Each negative test publishes twice and measures the second: measured in this harness, the
/// first update of a view type in the process re-runs its body whatever its inputs, and every
/// later one is compared. A one-time pass per type costs nothing; a pass per publish is what these
/// tests stop.
@MainActor
final class AdapterGateInvalidationTests: XCTestCase {

  private func host(_ root: some View) -> (NSWindow, NSView) {
    let hosting = NSHostingView(rootView: root.frame(width: 600, height: 300))
    hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    // A programmatic NSWindow defaults `isReleasedWhenClosed` to true, which would over-release on
    // top of ARC — same reasoning as `PaneRenderingTests.host`.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFront(nil)
    return (window, hosting)
  }

  // MARK: Toasts

  private func hostToasts(_ store: AppStore) -> (NSWindow, NSView) {
    host(
      ToastStackAdapter()
        .themeTokensRoot()
        .environmentObject(store)
        .environmentObject(store.runCommand)
        .environmentObject(store.notifications))
  }

  /// A notification the user is not shown a toast for: the adapter re-runs (it observes the whole
  /// notification list), and the stack's model is unchanged.
  @discardableResult
  private func recordNotification(_ store: AppStore) -> WorkroomNotification? {
    store.notifications.record(
      targetID: .workroom(project: "/a", name: "foo"), tabID: UUID(),
      activity: .osc(title: "build finished", body: nil), focused: false)
  }

  func testANotificationWithNoToastDoesNotReRunTheStack() throws {
    let store = AppStore()
    let (window, view) = hostToasts(store)
    defer { window.close() }
    // A toast showing, so the model holds arrays a re-built model would not share storage with:
    // with nothing showing, the stack's inputs compare equal with or without the gate.
    store.enqueueToast(try XCTUnwrap(recordNotification(store)))
    settle(view)
    XCTAssertGreaterThan(ToastStack.bodyPasses, 0, "the fixture must actually render the stack")
    recordNotification(store)
    settle(view)

    ToastStack.bodyPasses = 0
    recordNotification(store)
    settle(view)

    XCTAssertEqual(store.notifications.items.count, 3, "every notification landed")
    XCTAssertEqual(store.toasts.count, 1, "the toast is still showing")
    XCTAssertEqual(
      ToastStack.bodyPasses, 0, "a notification that changes no toast must not re-run the stack")
  }

  func testAToastArrivingReRunsTheStack() {
    let store = AppStore()
    let (window, view) = hostToasts(store)
    defer { window.close() }
    settle(view)

    ToastStack.bodyPasses = 0
    store.enqueueToast(
      WorkroomNotification(
        id: UUID(), targetID: .workroom(project: "/a", name: "foo"), tabID: UUID(),
        source: "a / foo", title: "build finished", body: nil,
        date: Date(timeIntervalSince1970: 0), count: 1))
    settle(view, until: { ToastStack.bodyPasses > 0 })

    XCTAssertGreaterThan(
      ToastStack.bodyPasses, 0, "a new toast changes the model, so the gate must let it through")
  }

  // MARK: A pane's status bar

  private struct StatusBarFixture {
    let store: AppStore
    let window: NSWindow
    let view: NSView
  }

  private func hostStatusBar() throws -> StatusBarFixture {
    let store = AppStore()
    let path = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("status-bar-gate-\(UUID().uuidString)").path
    store.projectStore.projects = [Project(path: path, vcs: "git", workrooms: [])]
    let target = try XCTUnwrap(store.target(for: .root(project: path)))
    let (window, view) = host(
      TerminalStatusBarAdapter(target: target, tabID: UUID(), state: nil)
        .themeTokensRoot()
        .environmentObject(store)
        .environmentObject(store.runCommand)
        .environmentObject(store.terminals.codingAgentManager))
    return StatusBarFixture(store: store, window: window, view: view)
  }

  /// Another pane's failed command: the manager publishes, so every pane's adapter re-runs, and
  /// this pane's bar shows nothing of it.
  private func diagnoseAnotherTab(_ store: AppStore) {
    let failure = FailedCommand(
      command: "npm test", cwd: nil, exitCode: 1, shell: "zsh", output: "1 failing",
      isRunTab: false, isRemote: false)
    store.terminals.codingAgentManager.adopt(
      UUID(), banner: .awaitingDiagnose(failure), failure: failure)
  }

  func testAnotherTabsDiagnosisDoesNotReRunThisPanesBar() throws {
    let f = try hostStatusBar()
    defer { f.window.close() }
    settle(f.view)
    XCTAssertGreaterThan(StatusBarPasses.count, 0, "the fixture must actually render the bar")
    diagnoseAnotherTab(f.store)
    settle(f.view)

    StatusBarPasses.count = 0
    diagnoseAnotherTab(f.store)
    settle(f.view)

    XCTAssertEqual(f.store.terminals.codingAgentManager.banners.count, 2, "both diagnoses landed")
    XCTAssertEqual(
      StatusBarPasses.count, 0, "another tab's diagnosis must not re-run this pane's status bar")
  }

  func testAThemeChangeStillRepaintsTheBar() throws {
    let f = try hostStatusBar()
    defer { f.window.close() }
    settle(f.view)

    StatusBarPasses.count = 0
    ThemeService.shared.applyActiveTheme(force: true)
    settle(f.view, until: { StatusBarPasses.count > 0 })

    XCTAssertGreaterThan(
      StatusBarPasses.count, 0,
      "the bar reads the theme from the environment, which invalidates it past the gate")
  }
}
