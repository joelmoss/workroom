import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// Routing + banner-gating + native-request mapping for notifications (issue #10). These are the
/// pure pieces of the click loop; the SwiftUI/window glue is verified manually (decision 3.1).
final class NotificationRoutingTests: XCTestCase {

  // MARK: Stored target id → listed SidebarID (TargetID(encoded:) + AppStore.validatedSelection)

  private func listedSidebarID(_ encoded: String, in projects: [Project]) -> SidebarID? {
    AppStore.validatedSelection(TargetID(encoded: encoded)?.sidebarID, in: projects)
  }

  func testReverseLookupRoot() {
    let p = Project(path: "/a", vcs: "git", workrooms: [])
    XCTAssertEqual(listedSidebarID("root|/a", in: [p]), .root(project: "/a"))
  }

  func testReverseLookupWorkroom() {
    let w = Workroom(name: "foo", path: "/a/foo", vcsName: "git", warnings: [])
    let p = Project(path: "/a", vcs: "git", workrooms: [w])
    XCTAssertEqual(listedSidebarID("wr|/a|foo", in: [p]), .workroom(project: "/a", name: "foo"))
  }

  func testReverseLookupMissingIsNil() {
    let p = Project(path: "/a", vcs: "git", workrooms: [])
    XCTAssertNil(listedSidebarID("wr|/a|gone", in: [p]))
    XCTAssertNil(listedSidebarID("root|/gone", in: [p]))
  }

  // MARK: Banner gating (NotificationGate)

  func testBannerOnlyWhenBackgrounded() {
    XCTAssertTrue(NotificationGate.shouldPostBanner(recorded: true, appActive: false))
    XCTAssertFalse(NotificationGate.shouldPostBanner(recorded: true, appActive: true))
    XCTAssertFalse(NotificationGate.shouldPostBanner(recorded: false, appActive: false))
  }

  func testInAppOnlyWhenForegrounded() {
    XCTAssertTrue(NotificationGate.shouldPresentInApp(recorded: true, appActive: true))
    XCTAssertFalse(NotificationGate.shouldPresentInApp(recorded: true, appActive: false))
    XCTAssertFalse(NotificationGate.shouldPresentInApp(recorded: false, appActive: true))
  }

  // MARK: Native request mapping (SystemNotifier.payload)

  func testPayloadIdentifierIsTabAndCarriesIDs() {
    let tab = UUID()
    let notifID = UUID()
    let n = WorkroomNotification(
      id: notifID, targetID: .workroom(project: "/a", name: "foo"), tabID: tab, source: "a / foo",
      title: "T", body: "B", date: Date(timeIntervalSince1970: 0), count: 1)
    let p = SystemNotifier.payload(for: n)
    XCTAssertEqual(p.identifier, tab.uuidString)  // one banner per tab → re-post replaces
    XCTAssertEqual(p.title, "T")
    XCTAssertEqual(p.subtitle, "a / foo")  // project/workroom shown as the banner subtitle
    XCTAssertEqual(p.body, "B")
    XCTAssertEqual(p.userInfo["targetID"], "wr|/a|foo")
    XCTAssertEqual(p.userInfo["tabID"], tab.uuidString)
    XCTAssertEqual(p.userInfo["notifID"], notifID.uuidString)
  }

  // MARK: Opening a notification (WindowRegistry.open, #607)

  private let sid = SidebarID.workroom(project: "/p", name: "a")

  /// A window showing workroom `a` with two terminals, the second in front, registered with a fresh
  /// registry (never `.shared`) whose notification list the window shares.
  @MainActor
  private func makeWindow() -> (WindowRegistry, AppStore, TerminalTarget, TerminalTab, TerminalTab)
  {
    let registry = WindowRegistry()
    let projects = ProjectStore()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
    let store = AppStore(projectStore: projects, notifications: registry.notifications)
    store.services.notifier = SilentNotifier()
    store.confirmOnCloseOverrideForTesting = false
    isolate(store.terminals, service: isolatedPaneSessionService())
    registry.register(window: NSWindow(), store: store)
    store.selectedTargetID = sid
    let t = store.target(for: sid)!
    let first = store.terminals.addTab(for: t)
    let second = store.terminals.addTab(for: t)
    return (registry, store, t, first, second)
  }

  /// Value: protects=opening a notification from a background tab of the workroom in front selects
  /// that tab, though the workroom is already selected (#607); fails_when=the pane that was in front
  /// takes focus back as the bell's popover closes, which hands the window's first responder back
  /// to it; why_new=only cross-workroom opens were pinned, where the workroom switch alone shows the
  /// routing worked; seam=the `.focused` a surface's becomeFirstResponder raises, sent with no window
  /// (as `RunCommandTests` does for #598); no_claim=the popover close itself
  /// (`WorkroomWorkflowUITests` clicks the bell's row).
  @MainActor
  func testOpeningANotificationSelectsTheBackgroundTabThatRaisedIt() throws {
    let (registry, store, t, first, second) = makeWindow()
    XCTAssertEqual(store.terminals.focusedTab(for: t)?.id, second.id)
    let note = try XCTUnwrap(
      registry.notifications.record(
        targetID: t.id, tabID: first.id, activity: .osc(title: "done", body: nil), focused: false))

    registry.open(note)
    XCTAssertEqual(store.terminals.focusedTab(for: t)?.id, first.id, "the tab that raised it")
    // The popover closing gives the window's first responder back to the pane that was in front.
    try XCTUnwrap(store.terminals.surface(second)).onEvent?(.focused)

    XCTAssertEqual(store.selectedTargetID, sid)
    XCTAssertEqual(
      store.terminals.focusedTab(for: t)?.id, first.id,
      "the tab that raised it keeps focus while it is still being shown")
    XCTAssertTrue(registry.notifications.items.isEmpty, "opening dismisses it")
  }

  /// Value: protects=a notification whose tab has since closed still opens its workroom, on the tab
  /// in front there (#607's fallback); fails_when=open does nothing, or leaves the row; why_new=the
  /// existing fallback test opens a workroom with no tabs; seam=none; no_claim=window raise.
  @MainActor
  func testANotificationWhoseTabClosedOpensItsWorkroomOnTheTabInFront() throws {
    let (registry, store, t, first, second) = makeWindow()
    let note = try XCTUnwrap(
      registry.notifications.record(
        targetID: t.id, tabID: second.id, activity: .osc(title: "done", body: nil), focused: false))
    store.terminals.focus(first.id, for: t)
    store.terminals.closeTab(second.id, for: t)
    store.selectedTargetID = nil

    registry.open(note)

    XCTAssertEqual(store.selectedTargetID, sid, "its workroom opens")
    XCTAssertEqual(store.terminals.focusedTab(for: t)?.id, first.id)
    XCTAssertTrue(registry.notifications.items.isEmpty, "opening dismisses it")
  }
}
