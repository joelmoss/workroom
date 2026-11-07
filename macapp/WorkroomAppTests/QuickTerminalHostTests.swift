import AppKit
import DaemonConnection
import WorkroomDomain
import XCTest

@testable import Workroom

/// What hosts the Quick Terminal's panes without a window's store: its tabs, Investigate sessions,
/// notifications and toasts, answered by its own owners.
@MainActor
final class QuickTerminalHostTests: XCTestCase {
  private let registry = WindowRegistry()
  private let notifier = SilentNotifier()
  private let target = QuickTerminalController.target()

  /// A host whose panes never spawn a shell or open a background session, wired as the controller
  /// wires it.
  private func makeHost() -> QuickTerminalHost {
    let host = QuickTerminalHost(notifications: registry.notifications)
    host.services.notifier = notifier
    host.closeFlow.confirmOnCloseOverride = false
    host.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    host.terminals.recordUnrecognizedTool = { _ in }
    host.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned })
    host.terminals.allowsDetach = false
    host.pinnedTarget = target
    return host
  }

  /// Value: protects=the pane views' "open the first terminal" opening none here, where the
  /// controller opened its own first tab; fails_when=it opens a tab, so every summon would start
  /// with two; why_new=AppStore's no-project guard did this for the Quick Terminal; seam=none;
  /// no_claim=WorkroomTerminalsView calling it.
  func testEnsuringAnInitialTerminalOpensNoSecondTab() {
    let host = makeHost()
    _ = host.terminals.addTab(for: target)

    host.ensureInitialTerminal(for: target)

    XCTAssertEqual(host.terminals.tabCount(forTargetID: target.id), 1)
  }

  /// Value: protects=Investigate opening an Investigate session tab here, and that tab's exit
  /// ending the session, so a later close or quit does not treat it as one; fails_when=the tab is
  /// not marked, or `.childExited` is ignored; why_new=the host handles its own events; seam=none;
  /// no_claim=the agent's command line (RunCommandTests).
  func testInvestigateOpensASessionAndItsExitEndsIt() {
    let host = makeHost()
    _ = host.terminals.addTab(for: target)
    let banner = CodingAgentBannerState.awaitingDiagnose(
      FailedCommand(
        command: "npm test", cwd: target.path, exitCode: 1, shell: nil, output: "",
        isRunTab: false, isRemote: false))

    let tab = host.investigate(banner, in: target, surface: nil)

    XCTAssertEqual(host.terminals.tabCount(forTargetID: target.id), 2)
    XCTAssertEqual(host.runCommand.investigateTabs[tab.id], target.id)
    host.terminals.surface(tab)?.onEvent?(.childExited(0))
    XCTAssertNil(host.runCommand.investigateTabs[tab.id], "its exit ends the session")
  }

  /// Value: protects=closing the last tab telling the controller, which closes the window;
  /// fails_when=`.tabsRemoved` stops calling onTargetEmptied, or calls it with a tab left;
  /// why_new=the host handles its own events; seam=none; no_claim=the window closing.
  func testClosingTheLastTabEmptiesTheTarget() {
    let host = makeHost()
    let first = host.terminals.addTab(for: target)
    let second = host.terminals.addTab(for: target)
    var emptied: [TerminalTarget.ID] = []
    host.onTargetEmptied = { emptied.append($0) }

    host.requestCloseTerminalTab(second.id, for: target)
    XCTAssertTrue(emptied.isEmpty, "a tab is left")
    host.requestCloseTerminalTab(first.id, for: target)

    XCTAssertEqual(emptied, [target.id])
  }

  /// Value: protects=every notification the host raises carrying the host's own identity, never its
  /// notifier's, so closing the Quick Terminal drops each one (risk 1 of the QuickTerminalHost
  /// plan); fails_when=any raise path stamps another identity; why_new=the host replaced a store;
  /// seam=none; no_claim=UNUserNotificationCenter.
  func testItsNotificationsCarryItsIdentityAndGoWhenItDropsThem() {
    let host = makeHost()
    let other = makeHost()
    let tab = host.terminals.addTab(for: target)
    // Every raise path a host has: a terminal's own notification, a request and a finish.
    host.terminals.onEvent?(.activity(target.id, UUID(), .osc(title: "Build done", body: nil)))
    host.raiseNeedsYou(
      targetID: target.id, tabID: tab.id, episode: "boot/s/r/1",
      record: .init(id: "", state: .blocked, kind: .permission, message: "Apply?", episode: 1),
      stillWanted: { true })
    host.raiseFinished(targetID: target.id, tabID: UUID(), record: .init(id: "", state: .idle))
    other.raiseFinished(targetID: target.id, tabID: UUID(), record: .init(id: "", state: .idle))
    XCTAssertEqual(registry.notifications.items.count, 4, "fixture: every path recorded")
    let origins = registry.notifications.items.map(\.origin)
    XCTAssertEqual(origins.filter { $0 == ObjectIdentifier(host) }.count, 3)
    XCTAssertFalse(origins.contains(ObjectIdentifier(host.paneNotifier)), "never the notifier's")
    XCTAssertEqual(
      registry.notifications.items.first { $0.episode != nil }?.source, "Quick Terminal")

    registry.dropNotifications(raisedBy: host)

    XCTAssertEqual(registry.notifications.items.map(\.origin), [ObjectIdentifier(other)])
  }

  /// Value: protects=the Quick Terminal's toast stack re-rendering as toasts come and go, read the
  /// way `ToastStackAdapter` reads them, through the pane host (risk 5); fails_when=the notifier
  /// stops being observable or the host reads a copy; why_new=the host replaced a store;
  /// seam=none; no_claim=rendering.
  func testReadingToastsThroughThePaneHostObservesTheQueue() throws {
    let host = makeHost()
    host.isAppActive = { true }
    let paneHost: any PaneHost = host
    let arrived = observeChange { _ = paneHost.toasts }
    host.raiseFinished(targetID: target.id, tabID: UUID(), record: .init(id: "", state: .idle))
    XCTAssertTrue(arrived.happened, "a toast arriving")

    let toast = try XCTUnwrap(paneHost.toasts.first)
    let went = observeChange { _ = paneHost.toasts }
    paneHost.dismissToast(toast.id)
    XCTAssertTrue(went.happened, "a toast going")
  }
}

/// Posts nothing.
private final class SilentNotifier: SystemNotifying, @unchecked Sendable {
  func ensureAuthorized() async -> Bool { false }
  func post(_ notification: WorkroomNotification) {}
  func withdraw(tabIDs: [TerminalTab.ID]) {}
  func withdraw(identifiers: [String]) {}
}
