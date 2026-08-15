import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// The quick switcher (issue #132): the pure keystroke classifier, the step arithmetic, the item
/// collection across windows, and the tap-commit behaviour.
@MainActor
final class QuickSwitcherTests: XCTestCase {

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "jj",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "jj", warnings: [])
      })
  }

  /// A store with live terminals in each of `workrooms` — `displayedWorkroomTargets` only lists targets
  /// that actually have tabs, so a switcher test needs them.
  private func makeStore(
    _ shared: ProjectStore, project path: String, workrooms: [String]
  ) -> AppStore {
    let store = AppStore(projectStore: shared)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    for name in workrooms {
      let sid = SidebarID.workroom(project: path, name: name)
      guard let target = store.target(for: sid) else { continue }
      store.terminals.addTab(for: target)
    }
    return store
  }

  // MARK: classify

  func testClassifyMapsTheTwoDefaultTriggers() {
    XCTAssertEqual(
      QuickSwitcherKey.classify(keyCode: 48, flags: [.option])?.kind, .workrooms, "⌥Tab")
    XCTAssertEqual(QuickSwitcherKey.classify(keyCode: 48, flags: [.control])?.kind, .panes, "⌃Tab")
    XCTAssertEqual(
      QuickSwitcherKey.classify(keyCode: 48, flags: [.option, .shift])?.reverse, true, "⇧⌥Tab")
    XCTAssertEqual(
      QuickSwitcherKey.classify(keyCode: 48, flags: [.control, .shift])?.reverse, true, "⇧⌃Tab")
  }

  /// Bare Tab must reach the terminal (shell completion), and ⌘Tab belongs to the OS app switcher.
  func testClassifyRejectsBareTabAndCommandCombinations() {
    XCTAssertNil(QuickSwitcherKey.classify(keyCode: 48, flags: []), "bare Tab is the terminal's")
    XCTAssertNil(QuickSwitcherKey.classify(keyCode: 48, flags: [.shift]), "⇧Tab likewise")
    XCTAssertNil(QuickSwitcherKey.classify(keyCode: 48, flags: [.command]), "⌘Tab is the OS")
    XCTAssertNil(QuickSwitcherKey.classify(keyCode: 48, flags: [.command, .shift]))
    XCTAssertNil(
      QuickSwitcherKey.classify(keyCode: 48, flags: [.option, .control]),
      "a combination matching neither configured modifier isn't ours")
  }

  func testClassifyRejectsOtherKeys() {
    for code: UInt16 in [0, 36, 50, 53, 123, 124] {
      XCTAssertNil(QuickSwitcherKey.classify(keyCode: code, flags: [.option]), "keyCode \(code)")
    }
  }

  /// The trigger is a preference because a global-hotkey grabber (AltTab et al.) beats a local monitor.
  func testClassifyHonoursConfiguredModifiers() {
    let hit = QuickSwitcherKey.classify(
      keyCode: 48, flags: [.command, .option],
      workroomModifier: .commandOption, paneModifier: .commandControl)
    XCTAssertEqual(hit?.kind, .workrooms)
    XCTAssertNil(
      QuickSwitcherKey.classify(
        keyCode: 48, flags: [.option], workroomModifier: .commandOption,
        paneModifier: .commandControl),
      "the default ⌥Tab stops matching once retuned")
    XCTAssertEqual(
      QuickSwitcherKey.classify(
        keyCode: 48, flags: [.command, .control], workroomModifier: .commandOption,
        paneModifier: .commandControl)?.kind, .panes)
  }

  /// Both modifiers set the same is user error; ⌥Tab keeps working rather than becoming ambiguous.
  func testClassifyPrefersWorkroomsOnATie() {
    XCTAssertEqual(
      QuickSwitcherKey.classify(
        keyCode: 48, flags: [.option], workroomModifier: .option, paneModifier: .option)?.kind,
      .workrooms)
  }

  // MARK: step arithmetic

  func testWrappedStepsAndWraps() {
    XCTAssertEqual(AppStore.wrapped(index: 0, by: 1, count: 3), 1)
    XCTAssertEqual(AppStore.wrapped(index: 2, by: 1, count: 3), 0, "wraps forward")
    XCTAssertEqual(AppStore.wrapped(index: 0, by: -1, count: 3), 2, "wraps backward")
    XCTAssertEqual(AppStore.wrapped(index: 0, by: 1, count: 1), 0, "a single item stays put")
    XCTAssertEqual(AppStore.wrapped(index: 5, by: 1, count: 0), 5, "no items ⇒ unchanged, no crash")
    XCTAssertEqual(AppStore.wrapped(index: 1, by: -4, count: 3), 0, "any magnitude, either sign")
  }

  /// From the head of an MRU list, a forward tap lands on "the one before this".
  func testDestinationFromMRUHead() {
    XCTAssertEqual(QuickSwitcher.destination(from: 0, count: 4, reverse: false), 1)
    XCTAssertEqual(
      QuickSwitcher.destination(from: 0, count: 4, reverse: true), 3, "⇧ = least recent")
    XCTAssertEqual(
      QuickSwitcher.destination(from: nil, count: 4, reverse: false), 0,
      "not in the list (a root with no terminals) ⇒ enter at the most recent")
    XCTAssertEqual(QuickSwitcher.destination(from: nil, count: 4, reverse: true), 3)
  }

  // MARK: item collection

  func testWorkroomSlotsSpanEveryWindowInMRUOrder() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w1", "w2"])]
    let a = makeStore(shared, project: "/p", workrooms: ["w1"])
    let b = makeStore(shared, project: "/p", workrooms: ["w2"])
    let registry = WindowRegistry()
    registry.register(window: NSWindow(), store: a)
    registry.register(window: NSWindow(), store: b)

    let recency = SwitcherRecency()
    recency.recordWorkroom(store: b, sid: .workroom(project: "/p", name: "w2"))

    let slots = QuickSwitcher.workroomSlots(registry: registry, recency: recency)
    XCTAssertEqual(slots.count, 2, "both windows contribute")
    XCTAssertTrue(slots.first?.store === b, "the most recently used slot leads")
  }

  /// A window with a sheet up is not a switchable destination: raising it and moving its selection would
  /// leave its own dialog (e.g. the commit sheet) acting on a workroom the user never chose.
  func testWorkroomSlotsExcludeWindowsWithAModalUp() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w1", "w2"])]
    let a = makeStore(shared, project: "/p", workrooms: ["w1"])
    let b = makeStore(shared, project: "/p", workrooms: ["w2"])
    b.activePicker = .open
    let registry = WindowRegistry()
    registry.register(window: NSWindow(), store: a)
    registry.register(window: NSWindow(), store: b)

    let slots = QuickSwitcher.workroomSlots(registry: registry, recency: SwitcherRecency())
    XCTAssertEqual(slots.count, 1)
    XCTAssertTrue(slots.first?.store === a)
    XCTAssertTrue(
      b.hasModalPresentation, "…and the exclusion is driven by the full modal predicate")
  }

  // MARK: monitor gating

  /// The three-way gate the key monitor routes through. A fresh `WindowRegistry()` throughout, never
  /// `.shared` — registering on the singleton leaks window registrations into later tests (the reason
  /// both this and `shortcutStore` take an injectable registry).
  func testGatePassesTheKeyThroughForAWindowThatIsNotOurs() {
    let registry = WindowRegistry()
    guard case .passThrough = AppDelegate.switcherGate(for: NSWindow(), in: registry) else {
      return XCTFail("an unregistered window (Settings, About, the quick terminal) keeps its key")
    }
    guard case .passThrough = AppDelegate.switcherGate(for: nil, in: registry) else {
      return XCTFail("no window at all ⇒ nothing to switch in")
    }
  }

  func testGateSwallowsWhileAnyModalIsUp() {
    let registry = WindowRegistry()
    let store = AppStore(projectStore: ProjectStore())
    let window = NSWindow()
    registry.register(window: window, store: store)

    guard case .act = AppDelegate.switcherGate(for: window, in: registry) else {
      return XCTFail("a plain workroom window is switchable")
    }

    // Not `activePicker` — the *full* predicate, so a commit sheet counts too.
    store.pendingCommit = PendingCommit(sid: .workroom(project: "/p", name: "w"), vcs: .git)
    guard case .swallow = AppDelegate.switcherGate(for: window, in: registry) else {
      return XCTFail("⌥Tab must not retarget the selection under a live commit sheet")
    }
  }

  // MARK: the Go-menu path (D11)

  /// The menu item resolves its store from the KEY window through the same gate, not from the menu's
  /// own focused store: a `focusedSceneValue` survives an aux window or the quick terminal becoming key,
  /// so reading the focused store would let a menu-fired switch retarget a background window.
  func testTheMenuPathRefusesAnyWindowTheKeyMonitorWouldNotActOn() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w1", "w2"])]
    let store = makeStore(shared, project: "/p", workrooms: ["w1", "w2"])
    store.selectedTargetID = .workroom(project: "/p", name: "w1")
    let window = NSWindow()
    let registry = WindowRegistry()
    registry.register(window: window, store: store)

    XCTAssertFalse(
      QuickSwitcher.stepFromKeyWindow(
        .workrooms, window: NSWindow(), registry: registry, recency: SwitcherRecency()),
      "an unregistered key window (Settings, the quick terminal) is not ours to switch in")
    XCTAssertFalse(
      QuickSwitcher.stepFromKeyWindow(
        .workrooms, window: nil, registry: registry, recency: SwitcherRecency()),
      "no key window at all ⇒ nothing to switch in")

    store.pendingCommit = PendingCommit(sid: .workroom(project: "/p", name: "w1"), vcs: .git)
    XCTAssertFalse(
      QuickSwitcher.stepFromKeyWindow(
        .workrooms, window: window, registry: registry, recency: SwitcherRecency()),
      "and a modal is swallowed here too, not just in the monitor")
    XCTAssertEqual(
      store.selectedTargetID, .workroom(project: "/p", name: "w1"), "the selection never moved")
  }

  func testTheMenuPathSwitchesOnTheKeyWindow() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w1", "w2"])]
    let store = makeStore(shared, project: "/p", workrooms: ["w1", "w2"])
    store.selectedTargetID = .workroom(project: "/p", name: "w1")
    let window = NSWindow()
    let registry = WindowRegistry()
    registry.register(window: window, store: store)

    XCTAssertTrue(
      QuickSwitcher.stepFromKeyWindow(
        .workrooms, window: window, registry: registry, recency: SwitcherRecency()))
    XCTAssertEqual(
      store.selectedTargetID, .workroom(project: "/p", name: "w2"),
      "the menu item performs the same immediate flip a tap does — no session, no rail")
  }

  /// `canSwitchWorkrooms` gates the menu item's key equivalent, and a disabled item drops it — so this
  /// answering true when nothing is switchable is what would eat a pass-through Tab.
  func testCanSwitchWorkroomsCountsAcrossWindowsAndSkipsModalOnes() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w1", "w2"])]
    let a = makeStore(shared, project: "/p", workrooms: ["w1"])
    let registry = WindowRegistry()
    registry.register(window: NSWindow(), store: a)
    XCTAssertFalse(
      QuickSwitcher.canSwitchWorkrooms(registry: registry), "one workroom is nowhere to go")

    let b = makeStore(shared, project: "/p", workrooms: ["w2"])
    registry.register(window: NSWindow(), store: b)
    XCTAssertTrue(
      QuickSwitcher.canSwitchWorkrooms(registry: registry),
      "the second window's workroom counts — the switcher's scope is the whole app")

    b.activePicker = .open
    XCTAssertFalse(
      QuickSwitcher.canSwitchWorkrooms(registry: registry),
      "…and a window with a dialog up isn't a destination, exactly as `workroomSlots` has it")
  }

  /// The chords the Go items render. Wrong glyphs here and macOS teaches the user the wrong shortcut.
  func testEveryTriggerModifierHasAMatchingSwiftUIChord() {
    XCTAssertEqual(SwitcherModifier.option.eventModifiers, [.option])
    XCTAssertEqual(SwitcherModifier.control.eventModifiers, [.control])
    XCTAssertEqual(SwitcherModifier.commandOption.eventModifiers, [.command, .option])
    XCTAssertEqual(SwitcherModifier.commandControl.eventModifiers, [.command, .control])
  }

  // MARK: pane stepping (the ⌃Tab commit path)

  func testPaneStepFlipsToThePreviouslyUsedPaneAndBack() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w"])]
    let store = makeStore(shared, project: "/p", workrooms: [])
    let sid = SidebarID.workroom(project: "/p", name: "w")
    guard let target = store.target(for: sid) else { return XCTFail("no target") }
    store.selectedTargetID = sid
    let first = store.terminals.addTab(for: target).id
    let second = store.terminals.addTab(for: target).id
    let third = store.terminals.addTab(for: target).id
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, third, "the newest tab is focused")

    let recency = SwitcherRecency()
    for id in [first, second, third] { recency.recordPane(id) }  // third is most recent

    XCTAssertTrue(QuickSwitcher.step(.panes, reverse: false, in: store, recency: recency))
    XCTAssertEqual(
      store.terminals.activeTab(for: target)?.id, second, "a tap lands on the previously used pane")

    // The commit re-orders MRU through `onFocusChange`, so the next tap comes back — the ⌘Tab feel.
    XCTAssertEqual(
      SwitcherRecency.shared.panes.ids.first, second, "the real hook recorded the commit")
    recency.recordPane(second)
    XCTAssertTrue(QuickSwitcher.step(.panes, reverse: false, in: store, recency: recency))
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, third)
  }

  func testPaneStepReverseGoesToTheLeastRecentlyUsed() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w"])]
    let store = makeStore(shared, project: "/p", workrooms: [])
    let sid = SidebarID.workroom(project: "/p", name: "w")
    guard let target = store.target(for: sid) else { return XCTFail("no target") }
    store.selectedTargetID = sid
    let first = store.terminals.addTab(for: target).id
    let second = store.terminals.addTab(for: target).id
    let third = store.terminals.addTab(for: target).id

    let recency = SwitcherRecency()
    for id in [first, second, third] { recency.recordPane(id) }

    XCTAssertTrue(QuickSwitcher.step(.panes, reverse: true, in: store, recency: recency))
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, first)
    XCTAssertNotEqual(second, third)  // silence unused-warning noise while keeping the ids named
  }

  /// Nothing to switch to ⇒ `step` returns false, which is what makes the monitor pass ⌃Tab through to
  /// a TUI in a single-pane workroom instead of swallowing it.
  func testPaneStepDoesNothingWithFewerThanTwoPanes() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w"])]
    let store = makeStore(shared, project: "/p", workrooms: [])
    let sid = SidebarID.workroom(project: "/p", name: "w")
    guard let target = store.target(for: sid) else { return XCTFail("no target") }
    store.selectedTargetID = sid

    XCTAssertFalse(
      QuickSwitcher.step(.panes, reverse: false, in: store, recency: SwitcherRecency()),
      "no panes at all")

    store.terminals.addTab(for: target)
    XCTAssertFalse(
      QuickSwitcher.step(.panes, reverse: false, in: store, recency: SwitcherRecency()),
      "one pane: nowhere to go, so the key stays the terminal's")
  }

  func testWorkroomStepDoesNothingWithFewerThanTwoSlots() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w"])]
    let store = makeStore(shared, project: "/p", workrooms: ["w"])
    let registry = WindowRegistry()
    registry.register(window: NSWindow(), store: store)

    XCTAssertFalse(
      QuickSwitcher.step(
        .workrooms, reverse: false, in: store, registry: registry, recency: SwitcherRecency()))
  }

  // MARK: recency recording (the hooks)

  /// **The regression this feature turns on.** `applyLocation` raises `isNavigatingHistory` for its
  /// whole body, and the switcher commits through it — so recency must be recorded ABOVE that guard or
  /// ⌥Tab flips to the same place forever.
  func testRecencyIsRecordedEvenWhileHistoryIsSuppressed() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w1", "w2"])]
    let store = makeStore(shared, project: "/p", workrooms: ["w1", "w2"])
    let sid2 = SidebarID.workroom(project: "/p", name: "w2")
    guard let target2 = store.target(for: sid2),
      let tab = store.terminals.tabs(for: target2).first
    else { return XCTFail("no target/tab") }

    let before = SwitcherRecency.shared.workrooms.ids.first
    // Routes through `applyLocation(recordHistory:)` — i.e. under `isNavigatingHistory`.
    store.revealTerminal(tab.id, at: sid2)

    XCTAssertEqual(
      SwitcherRecency.shared.workrooms.ids.first,
      WorkroomSlotID(window: store.windowToken, sid: sid2),
      "a history-suppressed navigation still updates the switcher's order")
    XCTAssertNotEqual(SwitcherRecency.shared.workrooms.ids.first, before)
    XCTAssertEqual(
      SwitcherRecency.shared.panes.ids.first, tab.id, "and the focused pane is recorded too")
  }

  func testClosingPanesPrunesRecency() {
    let shared = ProjectStore()
    shared.projects = [project("/p", workrooms: ["w"])]
    let store = makeStore(shared, project: "/p", workrooms: [])
    let sid = SidebarID.workroom(project: "/p", name: "w")
    guard let target = store.target(for: sid) else { return XCTFail("no target") }
    let tab = store.terminals.addTab(for: target).id
    XCTAssertEqual(SwitcherRecency.shared.panes.ids.first, tab, "adding focuses it, so it records")

    store.terminals.closeTab(tab, for: target)
    XCTAssertFalse(
      SwitcherRecency.shared.panes.ids.contains(tab), "a closed pane leaves the ⌃Tab order")
  }
}
