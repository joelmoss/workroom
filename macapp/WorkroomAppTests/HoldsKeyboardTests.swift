import AppKit
import Defaults
import SwiftUI
import WorkroomDomain
import XCTest

@testable import Workroom

/// Who holds a window's keyboard, decided from its live selection as each first-responder claim or
/// resign runs (`AppStore.holdsKeyboard`, through `WindowRegistry.holdsKeyboard`), never from the render
/// that queued it. A render can be stale by then: a busy Claude Code pane re-rendered as focused just
/// after ⌥⌘N moved the selection to the create's checklist, took the keyboard back, and the new
/// workroom mounted dimmed beside it.
// Value: protects=the reported bug's model and its three claim sites (the host's claim and resign,
// the surface's own claim on entering a window), each of which defers to the live selection in a
// window with a store and to its render in one without; fails_when=a site trusts its render in a
// window with a store, refuses a store-less window's pane, or the check ignores a picker, a content
// tab or a split; no_claim=the SwiftUI render order that made the claim stale (a real Claude Code
// session is the only known way to produce it)
@MainActor
final class HoldsKeyboardTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let root = SidebarID.root(project: "/p")
  private let workroom = SidebarID.workroom(project: "/p", name: "a")
  private var registered: [NSWindow] = []

  /// The process's persisted selection as this test found it. A store with no active window
  /// persists every selection it makes (`AppStore.persistsSidebarPrefs`), so selecting `/p` here
  /// left `StandaloneTerminalTests`, in the same process, reloading into `/p`'s root.
  private var savedSelection: String?

  override func setUp() async throws {
    try await super.setUp()
    savedSelection = Defaults[.sidebarSelection]
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
  }

  override func tearDown() async throws {
    for window in registered { WindowRegistry.shared.unregister(window: window) }
    registered = []
    Defaults[.sidebarSelection] = savedSelection
    try await super.tearDown()
  }

  /// A store showing the project's root (the caller, with a terminal) selected, and the workroom a
  /// create makes beside it (with a terminal of its own).
  private func makeStore() throws -> (
    store: AppStore, caller: GhosttySurfaceView, created: GhosttySurfaceView
  ) {
    let store = AppStore(projectStore: projects, terminalsSection: section)
    store.confirmOnCloseOverrideForTesting = false
    isolate(store.terminals, service: isolatedPaneSessionService())
    let callerTab = store.terminals.addTab(for: try XCTUnwrap(store.target(for: root)))
    let createdTab = store.terminals.addTab(for: try XCTUnwrap(store.target(for: workroom)))
    let caller = try XCTUnwrap(store.terminals.surface(of: callerTab.id))
    let created = try XCTUnwrap(store.terminals.surface(of: createdTab.id))
    store.selectedTargetID = root
    return (store, caller, created)
  }

  /// A surface of no store's, as a popped-out pane's window or the Quick Terminal's holds.
  private func bareSurface() -> GhosttySurfaceView {
    GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: nil, spawnsSurface: false)
  }

  /// A window holding `surfaces`, registered with `store` when one is given (a main window), else
  /// unregistered (a popped-out pane's, the Quick Terminal's).
  private func window(holding surfaces: [NSView], store: AppStore?) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    if let store {
      WindowRegistry.shared.register(window: window, store: store)
      registered.append(window)
    }
    for surface in surfaces {
      surface.frame = window.contentView!.bounds
      window.contentView!.addSubview(surface)
    }
    return window
  }

  // MARK: The live check

  func testTheSelectionsFocusedTerminalHoldsTheKeyboard() throws {
    let (store, caller, created) = try makeStore()
    XCTAssertTrue(store.holdsKeyboard(caller))
    XCTAssertFalse(store.holdsKeyboard(created), "a terminal of a workroom not selected")
  }

  func testAPaneLeftBehindByTheSelectionIsRefusedTheKeyboard() throws {
    let (store, caller, created) = try makeStore()
    // ⌥⌘N: the selection moves to the create's checklist, then to the workroom it makes.
    store.selectedTargetID = .creation(project: "/p", id: UUID())
    XCTAssertFalse(store.holdsKeyboard(caller), "a stale claim from the caller's pane would stand")
    store.selectedTargetID = workroom
    XCTAssertFalse(store.holdsKeyboard(caller))
    XCTAssertTrue(store.holdsKeyboard(created))
  }

  func testNoTerminalHoldsTheKeyboardWhileAPickerIsUp() throws {
    let (store, caller, _) = try makeStore()
    store.modals.activePicker = .new
    XCTAssertFalse(store.holdsKeyboard(caller), "the picker's search field holds it")
  }

  func testNoTerminalHoldsTheKeyboardWhileAContentTabIsFocused() throws {
    let (store, caller, _) = try makeStore()
    let target = try XCTUnwrap(store.target(for: root))
    let file = store.terminals.openFilePreview(
      FileDescriptor(path: "README.md", isPreview: true), for: target)
    store.terminals.focus(file, for: target)
    XCTAssertEqual(store.terminals.focusedTab(for: target)?.id, file)
    XCTAssertFalse(store.holdsKeyboard(caller), "a diff or file pane claims no AppKit responder")
  }

  func testOnlyTheFocusedPaneOfASplitInsideOneWorkroomHoldsTheKeyboard() throws {
    let (store, caller, _) = try makeStore()
    let target = try XCTUnwrap(store.target(for: root))
    store.terminals.splitFocusedPane(for: target, orientation: .horizontal)
    let split = try XCTUnwrap(store.terminals.focusedSurface(for: target))
    XCTAssertFalse(split === caller, "the split's new pane takes focus")
    XCTAssertTrue(store.holdsKeyboard(split))
    XCTAssertFalse(store.holdsKeyboard(caller), "the pane beside it in the same workroom")
  }

  // MARK: The host's claim and resign (`TerminalContainerView.applyFocus`)

  func testTheHostRefusesAStaleClaimAndLetsTheLiveFocusedPaneHaveIt() throws {
    let (store, caller, created) = try makeStore()
    let window = window(holding: [caller, created], store: store)
    store.selectedTargetID = workroom
    XCTAssertTrue(window.makeFirstResponder(created))
    // The caller's pane rendered as focused before the selection moved.
    TerminalContainerView.syncFirstResponder(of: caller, in: window, rendered: true)
    XCTAssertTrue(window.firstResponder === created, "the stale claim took the keyboard back")
  }

  func testTheHostClaimsForTheLiveFocusedPaneWhateverItsRenderSaid() throws {
    let (store, caller, created) = try makeStore()
    let window = window(holding: [caller, created], store: store)
    store.selectedTargetID = workroom
    TerminalContainerView.syncFirstResponder(of: created, in: window, rendered: false)
    XCTAssertTrue(window.firstResponder === created)
  }

  func testTheHostKeepsTheLiveFocusedPanesKeyboardFromAStaleResign() throws {
    let (store, caller, _) = try makeStore()
    let window = window(holding: [caller], store: store)
    XCTAssertTrue(window.makeFirstResponder(caller))
    // Queued while a picker was up, run once it had gone and the caller was focused again.
    TerminalContainerView.syncFirstResponder(of: caller, in: window, rendered: false)
    XCTAssertTrue(window.firstResponder === caller, "a stale resign dropped the keyboard")
  }

  func testTheHostResignsAPaneThatNoLongerHoldsTheKeyboard() throws {
    let (store, caller, _) = try makeStore()
    let window = window(holding: [caller], store: store)
    XCTAssertTrue(window.makeFirstResponder(caller))
    store.modals.activePicker = .new
    TerminalContainerView.syncFirstResponder(of: caller, in: window, rendered: true)
    XCTAssertFalse(window.firstResponder === caller, "the picker's field couldn't take it")
  }

  func testTheHostOfAWindowWithNoStoreStillClaimsForItsPane() {
    let surface = bareSurface()
    let window = window(holding: [surface], store: nil)
    TerminalContainerView.syncFirstResponder(of: surface, in: window, rendered: true)
    XCTAssertTrue(window.firstResponder === surface)
  }

  // MARK: The surface's own claim on entering a window (`viewDidMoveToWindow`)

  func testASurfaceEnteringAWindowWithAStoreClaimsOnlyIfItHoldsTheKeyboard() throws {
    let (store, caller, created) = try makeStore()
    let window = window(holding: [], store: store)
    store.selectedTargetID = workroom
    caller.wantsFocus = true  // its last render, before the selection moved
    window.contentView!.addSubview(caller)
    XCTAssertFalse(window.firstResponder === caller, "the stale render's claim stood")
    created.wantsFocus = false
    window.contentView!.addSubview(created)
    XCTAssertTrue(window.firstResponder === created, "the live focused pane didn't claim")
  }

  func testASurfaceEnteringAWindowWithNoStoreClaimsAsItsRenderSaid() {
    let surface = bareSurface()
    let window = window(holding: [], store: nil)
    surface.wantsFocus = true
    window.contentView!.addSubview(surface)
    XCTAssertTrue(window.firstResponder === surface)
  }

  // MARK: A refused claim is made once the live state allows it

  /// `caller`'s pane hosted as the pane tree hosts it, in a window registered with `store`: focused
  /// while its workroom is selected and no picker is up (`PaneTreeView`'s fold), re-rendered when
  /// either changes.
  private func hostCallerPane(_ store: AppStore, _ caller: GhosttySurfaceView) -> NSWindow {
    let (window, _) = hostInWindow(
      CallerPane(store: store, modals: store.modals, surface: caller, sid: root),
      size: NSSize(width: 400, height: 300))
    WindowRegistry.shared.register(window: window, store: store)
    registered.append(window)
    return window
  }

  private func waitForKeyboard(_ surface: NSView, in window: NSWindow) -> Bool {
    settle(3, until: { window.firstResponder === surface })
    return window.firstResponder === surface
  }

  // Value: protects=the review's question, whether a pane refused the keyboard while a picker was
  // up takes it once the picker goes; fails_when=nothing re-runs the claim after the refusal, so the
  // terminal is left without first responder; no_claim=a real picker sheet
  func testAPaneRefusedWhileAPickerIsUpTakesTheKeyboardWhenItCloses() throws {
    let (store, caller, _) = try makeStore()
    store.modals.activePicker = .new
    let window = hostCallerPane(store, caller)
    settle(0.5)
    XCTAssertFalse(window.firstResponder === caller, "it claimed under the picker")
    store.modals.activePicker = nil
    XCTAssertTrue(waitForKeyboard(caller, in: window), "within 3 s of the picker closing")
  }

  // Value: protects=the review's question, whether a pane that mounts before its window's
  // selection lands (a session restore) takes the keyboard once it does; fails_when=nothing re-runs
  // the claim when the selection arrives; no_claim=the restore itself (`SavedLayout`)
  func testAPaneMountedBeforeItsSelectionLandsTakesTheKeyboardWhenItDoes() throws {
    let (store, caller, _) = try makeStore()
    store.selectedTargetID = nil
    let window = hostCallerPane(store, caller)
    settle(0.5)
    XCTAssertFalse(window.firstResponder === caller, "it claimed with nothing selected")
    store.selectedTargetID = root
    XCTAssertTrue(waitForKeyboard(caller, in: window), "within 3 s of the selection landing")
  }
}

/// One pane of `PaneTreeView`, reduced to its focus: the terminal is the focused pane while its
/// workroom is the selection and no New or Open Workroom picker is up.
private struct CallerPane: View {
  let store: AppStore
  @ObservedObject var modals: ModalState
  let surface: GhosttySurfaceView
  let sid: SidebarID

  var body: some View {
    TerminalContainerView(
      view: surface, isFocusedPane: store.selectedTargetID == sid && modals.activePicker == nil)
  }
}
