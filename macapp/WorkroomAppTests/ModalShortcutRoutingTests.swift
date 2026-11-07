import AppKit
import HostDrivers
import Observation
import WorkroomDomain
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
/// - `ModalState.hasModalPresentation` — ANDed into every menu-enablement boolean, because a menu key
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
      store.modals.activePicker = picker
      XCTAssertNil(
        AppDelegate.shortcutStore(for: win, in: registry),
        "\(picker) is up, so shortcuts must not reach the window behind it")
    }

    store.modals.activePicker = nil
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
    store.modals.activePicker = .new
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
    let project = Project(path: "/p", vcs: "git", workrooms: [])
    let workroom = Workroom(name: "w", path: "/p/w", vcsName: "git", warnings: [])
    let target = TerminalTarget(
      id: TargetID.root(project: "/p"), title: "p", path: "/p", isMissing: false)

    let mutations: [(String, (AppStore) -> Void)] = [
      ("activePicker", { $0.modals.activePicker = .new }),
      ("auxSheetPresented", { $0.modals.auxSheetPresented = true }),
      (
        "pendingDeletion",
        {
          $0.modals.pendingDeletion = PendingWorkroomDeletion(workroom: workroom, project: project)
        }
      ),
      (
        "pendingWorkroomClose",
        { $0.modals.pendingWorkroomClose = PendingWorkroomClose(target: target, name: "w") }
      ),
      ("pendingProjectDeletion", { $0.modals.pendingProjectDeletion = .init(project: project) }),
      (
        "pendingWorkroomLabel",
        { $0.modals.pendingWorkroomLabel = .init(workroom: workroom, project: project) }
      ),
      (
        "pendingRemoteSetup",
        {
          $0.modals.pendingRemoteSetup = PendingRemoteSetup(
            place: .exeDev,
            setup: ExeDevSetup(
              driver: ExeDevHostDriver(
                configuration: .init(hostSetup: .bundled),
                directory: FileManager.default.temporaryDirectory)))
        }
      ),
      (
        // The Configure… panel (#575), so menu shortcuts can't reach a surface hidden behind it.
        "pendingHostOptions",
        { $0.modals.pendingHostOptions = PendingHostOptions(project: project, place: .boxd) }
      ),
      (
        // Value: protects=menu shortcuts go inert while the start choice is up; fails_when=
        // `|| pendingStartChoice != nil` is dropped from hasModalPresentation; why_new=no other
        // row sets it; seam=none; no_claim=the choice sheet itself
        "pendingStartChoice",
        {
          $0.modals.pendingStartChoice = PendingStartChoice(
            run: CreationRun(
              project: project, kind: nil, splitAnchor: nil, previousSelection: nil),
            work: LocalWork(
              branch: "main", remote: "origin", ahead: 1, uncommitted: false, summary: "s"))
        }
      ),
      ("errorMessage", { $0.modals.errorMessage = "boom" }),
    ]

    for (name, mutate) in mutations {
      let store = AppStore(projectStore: ProjectStore())
      XCTAssertFalse(store.modals.hasModalPresentation, "a fresh store has nothing up (\(name))")
      mutate(store)
      XCTAssertTrue(
        store.modals.hasModalPresentation,
        "\(name) is a modal presentation — menu shortcuts must go inert behind it")
    }
  }

  /// The modal state lives on the store's `ModalState`. A view or menu reading it through the store
  /// must be invalidated by a write, or every sheet and the inert-shortcut gate stop updating.
  func testAReadThroughTheStoreIsInvalidatedByAModalWrite() {
    let store = AppStore()
    let invalidated = observeChange { _ = store.modals.hasModalPresentation }
    store.modals.activePicker = .open
    XCTAssertTrue(invalidated.happened, "a forwarded read must track ModalState")
  }

  /// Value: protects=an error (or a provider's setup sheet, or a start choice) that arrives when its
  /// work finishes leaves up whatever the user opened meanwhile, so an open commit sheet keeps its
  /// draft; fails_when=`ModalState` holds one modal in all and a new one replaces the last;
  /// why_new=no test raised two modals at once; seam=none; no_claim=which sheet SwiftUI draws first
  func testAModalRaisedOverAnotherLeavesItUp() {
    let modals = ModalState()
    let commit = PendingCommit(sid: .workroom(project: "/p", name: "w"))
    modals.pendingCommit = commit
    modals.errorMessage = "the push failed"

    XCTAssertEqual(modals.pendingCommit, commit, "the error must not take the commit sheet down")
    XCTAssertEqual(modals.errorMessage, "the push failed")

    modals.clearError()
    XCTAssertEqual(modals.pendingCommit, commit, "dismissing the error leaves the commit sheet up")
    XCTAssertTrue(modals.hasModalPresentation, "the commit sheet still holds the window")

    modals.pendingCommit = nil
    XCTAssertFalse(modals.hasModalPresentation, "nothing is left up")
  }

  /// Value: protects=raising the dialog already up, or dismissing what isn't up, redraws no reader of
  /// the modal state (the dedupe an equal write to a stored optional had, docs/macapp-perf-facts.md);
  /// fails_when=a `ModalState` setter writes its collection unguarded; why_new=the modals were stored
  /// optionals until 2.2 and got this from `@Observable`; seam=none; no_claim=writes that change a value
  func testAModalWriteThatChangesNothingNotifiesNoOne() {
    let modals = ModalState()
    modals.activePicker = .new
    modals.errorMessage = "boom"
    let invalidated = observeChange { _ = modals.hasModalPresentation }

    modals.activePicker = .new
    modals.errorMessage = "boom"
    modals.auxSheetPresented = false
    modals.pendingDeletion = nil
    XCTAssertFalse(invalidated.happened, "nothing changed, so nothing redraws")
  }
}
