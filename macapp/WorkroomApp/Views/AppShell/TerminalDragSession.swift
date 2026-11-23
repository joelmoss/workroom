import AppKit
import WorkroomDomain

/// The one drag of terminals a window has at a time (#652), whichever surface it started on: a
/// sidebar row (`SidebarRowDrag`), a title-bar tab (`WorkroomTabBar`), a pane tab
/// (`TerminalTabStrip`) or a pane's own title bar (`PaneTreeView`), both through
/// `AppStore.paneDragMoved`, or a group's title bar in a split (`WorkroomPaneTitleBar`). Each reports its pointer here and, when its own drag ends, asks
/// `ended` first; what a drop does is `AppStore.terminalDrop`'s, so every surface has one rule set.
///
/// The Quick Terminal's panel, another window, takes a drag from any window on its pane tabs while
/// it shows: its zones are measured with the window's, and its own tabs show the highlight.
///
/// The drop zones are measured once, when the drag starts: the List opens a gap for a dragged row
/// and the strips slide their tabs aside, and judged against where those have moved to, the
/// pointer would leave the row it was let go over while it rests there (#652, a pause before the
/// release).
@MainActor
final class TerminalDragSession {
  /// Where a drag started, which decides what an item's edges mean: on the sidebar a row's edges
  /// are the List's gaps (a reorder), on the title bar a tab's are its reorder.
  enum Surface: Equatable {
    case sidebar, titleBar, paneTabs, groupTitleBar
  }

  /// A zone and where it was on screen when the drag started.
  struct Zone {
    let zone: PaneDropZone
    let rect: CGRect
    /// The zone is a pane tab, whose halves are before and after it.
    var isPaneTab = false
    /// The zone is a title-bar tab.
    var isTitleBarTab = false
    /// The zone is a folded group's sidebar row.
    var isFoldedGroup = false
    /// The zone is the title bar's tab row, its empty space past the last tab included: these are
    /// its tabs, left to right, in whose gaps a terminal let go becomes standalone.
    var titleBarTabs: [(sid: SidebarID, rect: CGRect)]? = nil
    /// Whose zone it is when not the dragging window's: the Quick Terminal's panel, whose tabs
    /// show the highlight.
    weak var host: (any PaneDropZoneHost)? = nil
    /// Where a window over this one hides it: a point in here does not reach the zone.
    var covered: CGRect = .null
  }

  private weak var store: AppStore?
  private(set) var source: TerminalDragSource?
  private var surface: Surface = .sidebar
  private var zones: [Zone] = []
  /// Another window's host whose zones the drag measured: the Quick Terminal's panel.
  private weak var otherHost: (any PaneDropZoneHost)?
  private let measure: @MainActor (AppStore) -> [Zone]

  /// `measure` reads the zones off the screen as a drag starts: tests give their own.
  init(
    store: AppStore,
    measure: @escaping @MainActor (AppStore) -> [Zone] = { $0.terminalDropZones() }
  ) {
    self.store = store
    self.measure = measure
  }

  /// `source`'s drag from `surface` is at `screenPoint`: starts the session if it is a new drag,
  /// and highlights the destination under it when it takes the drop. Whether one does.
  @discardableResult
  func moved(_ source: TerminalDragSource, from surface: Surface, to screenPoint: CGPoint) -> Bool {
    guard let store else { return false }
    if self.source != source || self.surface != surface {
      // The Quick Terminal's panel comes in front first, so its tabs are measured as on top.
      WindowRegistry.shared.quickTerminal?.holdForDrag()
      begin(source, from: surface, zones: measure(store))
    }
    let hit = accepting(at: screenPoint)
    highlight(hit?.zone, on: hit?.host)
    showGhost(at: screenPoint, overOtherHost: hit?.host != nil)
    return hit != nil
  }

  /// Shows `zone` as where the drop would land on `host` (nil: the dragging window), and nowhere
  /// else.
  private func highlight(_ zone: PaneDropZone?, on host: (any PaneDropZoneHost)?) {
    if let store {
      let own = host == nil ? zone : nil
      if store.incomingPaneDrop != own { store.incomingPaneDrop = own }
    }
    if let otherHost {
      let other = host === otherHost ? zone : nil
      if otherHost.incomingPaneDrop != other { otherHost.incomingPaneDrop = other }
    }
  }

  /// Carries the shared ghost (`DragGhost`) over the window, except where the dragged thing shows
  /// itself: its own tab strip or the title bar's tab row, where its chip follows the pointer, and
  /// the sidebar, whose List draws its own drag image. Out of the window the window it would make
  /// shows instead (`DetachedPaneDragPreview`).
  private func showGhost(at screenPoint: CGPoint, overOtherHost: Bool) {
    guard let store, let source, let window = store.hostWindow,
      overOtherHost || window.frame.contains(screenPoint), surface != .sidebar,
      !ownRow.contains(where: { $0.contains(screenPoint) }),
      let title = store.ghostTitle(of: source)
    else { return DragGhost.shared.hide() }
    DragGhost.shared.show(title: title, at: screenPoint)
  }

  /// Where the dragged thing's own chip shows it: its tab strip, or the title bar's tab row.
  private var ownRow: [CGRect] {
    switch surface {
    case .titleBar:
      return zones.compactMap { $0.titleBarTabs == nil ? nil : $0.rect }
    case .paneTabs:
      guard case .terminal(_, let owner) = source else { return [] }
      let strip = zones.filter {
        guard $0.isPaneTab, case .tab(_, let container, _) = $0.zone else { return false }
        return container == owner
      }
      guard let first = strip.first else { return [] }
      return [strip.dropFirst().reduce(first.rect) { $0.union($1.rect) }.insetBy(dx: -8, dy: -4)]
    default:
      return []
    }
  }

  /// The drag ends at `screenPoint`: over a destination that takes it, the drop is made. Whether it
  /// was, so the surface makes no drop of its own. The session ends either way.
  @discardableResult
  func ended(at screenPoint: CGPoint) -> Bool {
    defer { cancel() }
    guard let store, let source, let zone = accepting(at: screenPoint)?.zone else { return false }
    Task { await store.dropTerminals(source, on: zone) }
    return true
  }

  /// Starts `source`'s drag from `surface` over `zones`, measured now: tests give their own.
  func begin(_ source: TerminalDragSource, from surface: Surface, zones: [Zone]) {
    self.source = source
    self.surface = surface
    self.zones = zones
    otherHost = zones.lazy.compactMap(\.host).first
  }

  /// Ends the session with no drop.
  func cancel() {
    DragGhost.shared.hide()
    source = nil
    highlight(nil, on: nil)
    zones = []
    otherHost = nil
  }

  /// The zone under `screenPoint`, as it was when the drag started, other than the source's own.
  func zone(at screenPoint: CGPoint) -> PaneDropZone? { hitZone(at: screenPoint)?.zone }

  /// Whose zone is under `screenPoint`: nil for the dragging window's, else the other host's (the
  /// Quick Terminal's panel).
  func host(at screenPoint: CGPoint) -> (any PaneDropZoneHost)? { hitZone(at: screenPoint)?.host }

  /// Whether the zone under `screenPoint` is a sidebar row, the Terminals heading or a title-bar
  /// tab that refuses the drag: a pane tab drag over one stops there, as over one that takes it.
  func refuses(at screenPoint: CGPoint) -> Bool {
    guard let store, let source, let hit = hitZone(at: screenPoint), !hit.isPaneTab
    else { return false }
    return store.terminalDrop(source, on: hit.zone) == nil
  }

  private func hitZone(at screenPoint: CGPoint)
    -> (zone: PaneDropZone, isPaneTab: Bool, host: (any PaneDropZoneHost)?)?
  {
    for zone in zones where !zone.covered.contains(screenPoint) {
      if let hit = hit(zone, at: screenPoint) { return (hit, zone.isPaneTab, zone.host) }
    }
    return nil
  }

  /// The zone under `screenPoint`, and whose it is, when the source's drop there does something.
  /// The dragging window decides it, whoever's zone it is (`AppStore.terminalDrop`).
  private func accepting(at screenPoint: CGPoint)
    -> (zone: PaneDropZone, host: (any PaneDropZoneHost)?)?
  {
    guard let store, let source, let hit = hitZone(at: screenPoint),
      store.terminalDrop(source, on: hit.zone) != nil
    else { return nil }
    return (hit.zone, hit.host)
  }

  /// The part of a title-bar tab where another title-bar tab let go drops on it: the middle half
  /// of its width. Nearer either edge it reorders.
  nonisolated static func titleBarBand(of tab: CGRect) -> CGRect {
    tab.insetBy(dx: tab.width * titleBarBandInset, dy: 0)
  }

  /// How far in from each edge of a title-bar tab its drop band starts, as a share of its width.
  nonisolated static let titleBarBandInset: CGFloat = 0.25

  /// The title bar's tabs as the drag measured them when it started, each with whether a drop on
  /// it does something, for the bar to reorder around the same bands the drop uses
  /// (`TabReorder.dropTargetIndex(spans:…)`). Empty when no drag from the title bar is on.
  func titleBarTabs() -> [SidebarID: (rect: CGRect, takes: Bool)] {
    guard let store, let source, surface == .titleBar else { return [:] }
    var tabs: [SidebarID: (rect: CGRect, takes: Bool)] = [:]
    for zone in zones where zone.isTitleBarTab {
      guard case .target(let sid) = zone.zone else { continue }
      let takes = source != .entry(sid) && store.terminalDrop(source, on: zone.zone) != nil
      tabs[sid] = (zone.rect, takes)
    }
    return tabs
  }

  private func hit(_ zone: Zone, at point: CGPoint) -> PaneDropZone? {
    if let tabs = zone.titleBarTabs {
      // A pane's, let go in the title bar's row but on no tab: a standalone terminal there.
      guard surface == .paneTabs, zone.rect.contains(point),
        !tabs.contains(where: { $0.rect.contains(point) })
      else { return nil }
      return .titleBarGap(before: tabs.first { $0.rect.minX > point.x }?.sid)
    }
    if zone.isPaneTab {
      guard zone.rect.contains(point), case .tab(let tab, let container, _) = zone.zone else {
        return nil
      }
      // A tab's own strip keeps its reorder.
      if surface == .paneTabs, case .terminal(_, let owner) = source, owner == container {
        return nil
      }
      return .tab(tab, in: container, after: point.x > zone.rect.midX)
    }
    if zone.isTitleBarTab, surface == .titleBar {
      // Its edges reorder the title bar's tabs.
      return Self.titleBarBand(of: zone.rect).contains(point) ? zone.zone : nil
    }
    if !zone.isTitleBarTab, surface == .sidebar, zone.zone != .standalone {
      // Between rows is the List's: a reorder, or a group's terminal made standalone there.
      let band = AppStore.groupBand(of: zone.rect, folded: zone.isFoldedGroup)
      return band.contains(point) ? zone.zone : nil
    }
    return zone.rect.contains(point) ? zone.zone : nil
  }
}

extension AppStore: PaneDropZoneHost {}

extension AppStore {
  /// Every drop zone this window shows, where it is on screen now: its title-bar tabs, and the
  /// sidebar rows, Terminals heading, pane tabs and group title bars marked as zones
  /// (`PaneDropZoneMarker`). Pane tabs first, so a tab inside a zone is hit before what holds it.
  /// The Quick Terminal panel's pane tabs too, while it shows: whichever of the two windows is in
  /// front hides the other's zones under it.
  func terminalDropZones() -> [TerminalDragSession.Zone] {
    let own = ownTerminalDropZones()
    guard let window = hostWindow,
      let panel = terminalsSection.quickTerminalHolder as? QuickTerminalHost,
      let panelWindow = panel.hostWindow, panelWindow !== window, quickTerminalShows(panelWindow)
    else { return own }
    var panelZones = Self.markedZones(panel.paneDropZoneViews, in: panelWindow) { _ in false }
      .filter(\.isPaneTab)
    guard !panelZones.isEmpty else { return own }
    for index in panelZones.indices { panelZones[index].host = panel }
    return Self.stacked(
      own, in: window.frame, with: panelZones, in: panelWindow.frame,
      panelInFront: isInFront(panelWindow, of: window))
  }

  /// `own` and the panel's zones, the front window's first, each window's hidden under the other's
  /// frame where that is in front.
  nonisolated static func stacked(
    _ own: [TerminalDragSession.Zone], in frame: CGRect,
    with panel: [TerminalDragSession.Zone], in panelFrame: CGRect, panelInFront: Bool
  ) -> [TerminalDragSession.Zone] {
    var own = own
    var panel = panel
    if panelInFront {
      for index in own.indices { own[index].covered = panelFrame }
      return panel + own
    }
    for index in panel.indices { panel[index].covered = frame }
    return own + panel
  }

  /// Whether the Quick Terminal's panel is on screen and not sliding away.
  private func quickTerminalShows(_ panelWindow: NSWindow) -> Bool {
    if let controller = WindowRegistry.shared.quickTerminal, !controller.isVisible { return false }
    return panelWindow.isVisible && panelWindow.occlusionState.contains(.visible)
  }

  /// Whether `window` is in front of `other`.
  private func isInFront(_ window: NSWindow, of other: NSWindow) -> Bool {
    let order = NSApp.orderedWindows
    guard let index = order.firstIndex(of: window) else { return false }
    guard let otherIndex = order.firstIndex(of: other) else { return true }
    return index < otherIndex
  }

  /// This window's own zones.
  private func ownTerminalDropZones() -> [TerminalDragSession.Zone] {
    guard let window = hostWindow else { return [] }
    var zones: [TerminalDragSession.Zone] = []
    if let run = workroomTabRun, run.window === window {
      let row = window.convertToScreen(run.convert(run.bounds, to: nil))
      for (sid, frame) in workroomTabFrames {
        let rect = CGRect(
          x: row.minX + frame.minX, y: row.maxY - frame.maxY, width: frame.width,
          height: frame.height)
        zones.append(.init(zone: .target(sid), rect: rect, isTitleBarTab: true))
      }
      // The row itself, out to the window's edge: the space between and after its tabs.
      let tabs = zones.compactMap { zone -> (sid: SidebarID, rect: CGRect)? in
        guard case .target(let sid) = zone.zone else { return nil }
        return (sid, zone.rect)
      }.sorted { $0.rect.minX < $1.rect.minX }
      let rowRect = CGRect(
        x: row.minX, y: row.minY, width: window.frame.maxX - row.minX, height: row.height)
      zones.append(.init(zone: .titleBarGap(before: nil), rect: rowRect, titleBarTabs: tabs))
    }
    let marked = Self.markedZones(paneDropZoneViews, in: window) { self.isFoldedGroup($0) }
    return marked.filter(\.isPaneTab) + zones + marked.filter { !$0.isPaneTab }
  }

  /// The zones of `views` shown in `window`, where they are on screen now.
  private static func markedZones(
    _ views: [PaneDropZone: [PaneDropZoneMarker.Box]], in window: NSWindow,
    isFoldedGroup: (PaneDropZone) -> Bool
  ) -> [TerminalDragSession.Zone] {
    var marked: [TerminalDragSession.Zone] = []
    for (zone, boxes) in views {
      for box in boxes {
        guard let view = box.view, view.window === window, !view.isHiddenOrHasHiddenAncestor
        else { continue }
        // Kept within its height: a marker in a sidebar pane's sticky header (#652) reports a
        // visible rect as tall as its pane, which would take the drops meant for the rows below.
        // Not its width: a row's reaches across the List's, past the row's own insets.
        let shown = view.visibleRect
        let visible = shown.intersection(
          CGRect(x: shown.minX, y: view.bounds.minY, width: shown.width, height: view.bounds.height)
        )
        guard !visible.isEmpty else { continue }
        marked.append(
          .init(
            zone: zone, rect: window.convertToScreen(view.convert(visible, to: nil)),
            isPaneTab: box.isPaneTab, isFoldedGroup: isFoldedGroup(zone)))
      }
    }
    return marked
  }

  /// Whether `zone` is a folded group's row in the Terminals section.
  private func isFoldedGroup(_ zone: PaneDropZone) -> Bool {
    guard case .target(let sid) = zone, case .terminalGroup = sid, let id = sid.targetID else {
      return false
    }
    return terminalsSection.group(id)?.isFolded == true
  }
}
