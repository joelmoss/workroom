import AppKit
import XCTest

@testable import Workroom

/// Making the New/Open Workroom dialogs actually blocking. Two halves are unit-testable:
///
/// - `AppDelegate.shortcutStore(for:in:)` — the AppDelegate key monitor routes every one of its
///   shortcut branches through this instead of `WindowRegistry.keyStore`. `keyStore` resolves
///   `store(for: NSApp.keyWindow) ?? lastActiveStore ?? allStores.first`, which is right for the
///   menu-bar item and notification routing but wrong for shortcuts: it falls back *past* a foreign key
///   window, firing ⌘R / ⌘1-9 / ⌥⌘S into a background workroom while a sheet, Settings, About,
///   Sparkle's updater or the quick terminal is key.
/// - `AppStore.hasModalPresentation` — ANDed into every menu-enablement boolean, because a menu key
///   equivalent fires straight through a dialog otherwise (verified live: ⌘T behind the Add Project
///   sheet really did open a second terminal tab).
///
/// A fresh `WindowRegistry()` throughout, never `.shared` — registering on the singleton leaks window
/// registrations into later tests. Hence the `in registry:` parameter on both helpers.
///
/// NOT covered here, deliberately: whether the monitor's call sites actually pass the event's window
/// rather than reaching for `keyStore` again. No unit test can see that — a regression there keeps
/// every assertion below green. It's covered by the two-window case in `NewWorkroomDialogUITests`.
@MainActor
final class ModalShortcutRoutingTests: XCTestCase {

  // MARK: shortcutStore

  func testRoutesToTheStoreOwningTheEventsWindow() {
    let registry = WindowRegistry()
    let shared = ProjectStore()
    let a = AppStore(projectStore: shared)
    let b = AppStore(projectStore: shared)
    let winA = NSWindow()
    let winB = NSWindow()
    registry.register(window: winA, store: a)
    registry.register(window: winB, store: b)

    XCTAssertTrue(
      AppDelegate.shortcutStore(for: winA, in: registry) === a,
      "a shortcut acts on the window it was aimed at")
    XCTAssertTrue(AppDelegate.shortcutStore(for: winB, in: registry) === b)
  }

  func testRejectsAnUnregisteredWindow() {
    let registry = WindowRegistry()
    let store = AppStore(projectStore: ProjectStore())
    registry.register(window: NSWindow(), store: store)

    // Sheets, Settings, About, the Sparkle updater and the quick terminal are all unregistered, so
    // this one branch covers every one of them: nil means each monitor branch no-ops, which is what
    // removes the need for a swallow-with-allowlist.
    XCTAssertNil(
      AppDelegate.shortcutStore(for: NSWindow(), in: registry),
      "a foreign key window gets no store — NOT a fallback to the last active one")
    XCTAssertNil(
      AppDelegate.shortcutStore(for: nil, in: registry),
      "nor does a nil window (no key window at all)")
  }

  func testRejectsAWindowShowingACommandPaletteDialog() {
    let registry = WindowRegistry()
    let store = AppStore(projectStore: ProjectStore())
    let win = NSWindow()
    registry.register(window: win, store: store)
    XCTAssertNotNil(AppDelegate.shortcutStore(for: win, in: registry), "baseline: routes normally")

    for picker in [ActivePicker.new, .open] {
      store.activePicker = picker
      XCTAssertNil(
        AppDelegate.shortcutStore(for: win, in: registry),
        "\(picker) is up, so shortcuts must not reach the window behind it")
    }

    store.activePicker = nil
    XCTAssertNotNil(
      AppDelegate.shortcutStore(for: win, in: registry),
      "dismissing the dialog restores routing — the block can't be sticky")
  }

  // MARK: hasModalPicker (the ⌘` branch, which consults no store)

  func testHasModalPickerOnlyForOurOwnWindowWithADialogUp() {
    let registry = WindowRegistry()
    let store = AppStore(projectStore: ProjectStore())
    let win = NSWindow()
    registry.register(window: win, store: store)

    XCTAssertFalse(AppDelegate.hasModalPicker(win, in: registry))
    store.activePicker = .new
    XCTAssertTrue(
      AppDelegate.hasModalPicker(win, in: registry),
      "⌘` must be swallowed rather than cycling windows out from under a dialog")
    XCTAssertFalse(
      AppDelegate.hasModalPicker(NSWindow(), in: registry),
      "…but a foreign key window still cycles: the dialog is per-window")
  }

  // MARK: hasModalPresentation

  /// One assertion per disjunct, so dropping a term in a later edit fails here rather than silently
  /// leaving menu shortcuts live behind that one presentation.
  func testEveryPresentationKindIsCountedIndependently() {
    let project = Project(path: "/p", vcs: "jj", workrooms: [])
    let workroom = Workroom(name: "w", path: "/p/w", vcsName: "jj", warnings: [])
    let target = TerminalTarget(
      id: TerminalTarget.rootID(project: "/p"), title: "p", path: "/p", isMissing: false)

    let mutations: [(String, (AppStore) -> Void)] = [
      ("activePicker", { $0.activePicker = .new }),
      ("auxSheetPresented", { $0.auxSheetPresented = true }),
      (
        "pendingDeletion",
        { $0.pendingDeletion = PendingWorkroomDeletion(workroom: workroom, project: project) }
      ),
      (
        "pendingWorkroomClose",
        { $0.pendingWorkroomClose = PendingWorkroomClose(target: target, name: "w") }
      ),
      ("pendingProjectDeletion", { $0.pendingProjectDeletion = .init(project: project) }),
      (
        "pendingWorkroomLabel",
        { $0.pendingWorkroomLabel = .init(workroom: workroom, project: project) }
      ),
      ("pendingProjectSettings", { $0.pendingProjectSettings = .init(project: project) }),
      ("errorMessage", { $0.errorMessage = "boom" }),
    ]

    for (name, mutate) in mutations {
      let store = AppStore(projectStore: ProjectStore())
      XCTAssertFalse(store.hasModalPresentation, "a fresh store has nothing up (\(name))")
      mutate(store)
      XCTAssertTrue(
        store.hasModalPresentation,
        "\(name) is a modal presentation — menu shortcuts must go inert behind it")
    }
  }
}
