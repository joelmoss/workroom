import Foundation
import WorkroomDomain

/// The Quick Terminal's tabs, each a split of panes over the same `PaneLayout` tree workroom panes
/// use. A pane is a surface and the status its footer shows. Closing the last pane of a tab closes
/// the tab; closing the last tab asks the window to close (`onEmpty`).
@MainActor
final class QuickTerminalWorkspace: ObservableObject {
  struct Pane {
    let surface: GhosttySurfaceView
    let status: QuickTerminalStatus
  }

  struct Tab: Identifiable, Equatable {
    let id: UUID
    var layout: PaneLayout<UUID>
    /// The pane keys go to, and a new split opens beside.
    var focused: UUID
  }

  @Published private(set) var tabs: [Tab] = []
  @Published private(set) var selectedTabID: UUID?
  private(set) var panes: [UUID: Pane] = [:]

  private let makeSurface: @MainActor (String) -> GhosttySurfaceView
  private let onEmpty: @MainActor () -> Void

  init(
    makeSurface: @escaping @MainActor (String) -> GhosttySurfaceView,
    onEmpty: @escaping @MainActor () -> Void
  ) {
    self.makeSurface = makeSurface
    self.onEmpty = onEmpty
  }

  var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }
  var focusedPane: Pane? { selectedTab.flatMap { panes[$0.focused] } }
  var allSurfaces: [GhosttySurfaceView] { panes.values.map(\.surface) }

  /// A new tab with one shell in `directory`, selected.
  func newTab(in directory: String) {
    let id = makePane(in: directory)
    let tab = Tab(id: UUID(), layout: .leaf(id), focused: id)
    tabs.append(tab)
    selectedTabID = tab.id
  }

  /// Split the focused pane: a new shell beside it (`.horizontal` right, `.vertical` below), in the
  /// focused shell's folder, and focused.
  func split(_ orientation: SplitOrientation) {
    guard let index = selectedIndex, let directory = focusedPane?.status.cwd else { return }
    let id = makePane(in: directory)
    tabs[index].layout = tabs[index].layout.inserting(
      id, beside: tabs[index].focused, orientation: orientation, newLeafFirst: false, ratio: 0.5)
    tabs[index].focused = id
  }

  func closeFocusedPane() {
    if let id = selectedTab?.focused { closePane(id) }
  }

  /// End pane `id`'s shell and take it out of its tab; a tab left empty goes, and with it the
  /// window when it was the last.
  func closePane(_ id: UUID) {
    guard let pane = panes.removeValue(forKey: id),
      let index = tabs.firstIndex(where: { $0.layout.contains(id) })
    else { return }
    pane.surface.tearDown()
    if let layout = tabs[index].layout.removingLeaf(id) {
      tabs[index].layout = layout
      if tabs[index].focused == id { tabs[index].focused = layout.firstTabID }
      return
    }
    let closedSelected = tabs[index].id == selectedTabID
    tabs.remove(at: index)
    guard !tabs.isEmpty else {
      selectedTabID = nil
      return onEmpty()
    }
    // The tab that slid into its place, else the one before it.
    if closedSelected { selectedTabID = tabs[min(index, tabs.count - 1)].id }
  }

  /// Select the tab at `index` (0-based); out of range does nothing.
  func selectTab(at index: Int) {
    guard tabs.indices.contains(index) else { return }
    selectedTabID = tabs[index].id
  }

  func selectTab(_ id: UUID) {
    if tabs.contains(where: { $0.id == id }) { selectedTabID = id }
  }

  /// Pane `id` took keyboard focus (a click in it): keys and new splits go there.
  func focus(_ id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.layout.contains(id) }),
      tabs[index].focused != id
    else { return }
    tabs[index].focused = id
  }

  func setRatio(_ ratio: CGFloat, forSplit splitID: UUID, inTab tabID: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
    tabs[index].layout = tabs[index].layout.settingRatio(ratio, forSplit: splitID)
  }

  /// End every shell: the window is going.
  func tearDownAll() {
    for pane in panes.values { pane.surface.tearDown() }
    panes = [:]
    tabs = []
    selectedTabID = nil
  }

  private var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedTabID } }

  private func makePane(in directory: String) -> UUID {
    let id = UUID()
    let surface = makeSurface(directory)
    surface.wantsFocus = true
    // Shell exit (`exit`, or the shell dying) closes its pane. This fires from a libghostty action
    // callback, so defer the teardown off that stack: freeing a surface synchronously inside a
    // libghostty callback races its IO and crashes (see GhosttySurfaceView /
    // AppDelegate.applicationWillTerminate). The async hop lands on the same main run loop a
    // moment later.
    surface.onChildExited = { [weak self] _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.closePane(id) } }
    }
    surface.onFocused = { [weak self] in self?.focus(id) }
    let status = QuickTerminalStatus(cwd: surface.workingDirectory)
    status.follow(surface)
    panes[id] = Pane(surface: surface, status: status)
    return id
  }
}
