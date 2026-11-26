import AppKit
import SwiftUI
import WorkroomDomain

/// Where a lifted Open row lands, and the lift a drag from outside the list makes (#819): a strip
/// tab, a pane's title bar or a title-bar tab dragged over the Open list lifts its own row there,
/// as if the drag had started on it. Its ghost takes over from the drag's own image while the
/// pointer is over the list, the rows open the same gaps, and a drop there lands as the row's own
/// would. A tab whose workroom is folded has no row: a placeholder under its workroom is lifted.
extension OpenRowLift {
  /// The workrooms whose tabs tab `tab` of `owner` can join, of `rows`: each that shows tabs and
  /// takes it.
  static func joinable(
    _ tab: TerminalTab.ID, of owner: SidebarID, rows: [OpenSectionRow], store: AppStore
  ) -> Set<SidebarID> {
    Set(
      rows.filter { $0.sid != owner && $0.canFold }.map(\.sid).filter {
        store.canDropTerminals(.terminal(tab, of: owner), on: .target($0))
      })
  }

  /// Lets the lifted row of `store`'s list go at `screen`, where its gap is: a workroom row's
  /// reorder; a tab's reorder, join among another workroom's tabs, or standalone terminal between
  /// workrooms; or, in its own place, back there. False when the pointer is off the list, where
  /// the gap isn't, and the caller decides.
  @discardableResult
  func landInGap(at screen: CGPoint, in store: AppStore) -> Bool {
    guard let reflow = reflow(for: store), isOverList(screen) else { return false }
    switch reflow.dragged {
    case .workroom(let sid):
      guard let index = reflow.movedIndex else {
        cancel()
        return true
      }
      store.moveWorkroomTab(sid, toIndex: index)
      settle()
    case .tab(let tab, let owner):
      if let place = reflow.standalonePlace {
        // A new row, which the gap holds for until it is made.
        land {
          await store.moveOpenTabToStandalone(
            tab, in: owner, after: place.after, before: place.before)
        }
      } else if let join = reflow.joinPlace {
        land { await store.moveOpenTab(tab, of: owner, into: join.into, before: join.before) }
      } else if let index = reflow.movedIndex {
        store.moveOpenTab(tab, toIndex: index, in: owner)
        settle()
      } else {
        cancel()
      }
    }
    return true
  }

  // MARK: A drag from outside the list

  /// The Open row `source`'s drag from `surface` stands for: a pane's tab (a strip's tab or a
  /// pane's title bar) is its tab row, a title-bar tab its workroom's row. Nil for any other.
  nonisolated static func item(
    for source: TerminalDragSource, from surface: TerminalDragSession.Surface
  ) -> OpenSectionItem? {
    switch (source, surface) {
    case (.terminal(let tab, let owner), .paneTabs): return .tab(tab, in: owner)
    case (.entry(let sid), .titleBar), (.entry(let sid), .groupTitleBar): return .workroom(sid)
    default: return nil
    }
  }

  /// `source`'s drag from `surface`, which started outside the Open list, is at `screen`: once it
  /// is over the list, lifts the row it stands for out of `store`'s list (`item(for:from:)`), its
  /// ghost drawing that row, and the gap follows the pointer from then on (`handedOver`). Nothing
  /// while a row is lifted already: the drag started on it, or has lifted it.
  func handOver(
    _ source: TerminalDragSource, from surface: TerminalDragSession.Surface, at screen: CGPoint,
    in store: AppStore
  ) {
    guard reflow == nil, store.sidebarView == .open, let window = store.hostWindow,
      let item = Self.item(for: source, from: surface),
      // Cheap first, as this runs on every move of the drag: over the list at all.
      let (_, shown) = Self.listRow(.target(item.owner), in: store), shown.contains(screen)
    else { return }
    // With the tab it lifts, under its workroom although that is folded.
    let rows = store.openSectionRows(showing: item)
    guard let row = rows.first(where: { $0.sid == item.owner }) else { return }
    let measured = SidebarOpenList.items(of: rows)
    let items = SidebarOpenList.items(of: rows, showing: item)
    let zone: PaneDropZone
    let content: AnyView
    let leaves: Bool
    let joinable: Set<SidebarID>
    switch item {
    case .workroom(let sid):
      zone = .target(sid)
      content = SidebarOpenList.ghost(
        of: SidebarOpenWorkroomRow(row: row.model, hovered: false, store: store), store: store)
      (leaves, joinable) = (false, [])
    case .tab(let tab, let owner):
      guard let tabRow = row.tabs.first(where: { $0.tab.id == tab }) else { return }
      // Measured on its own row, or its folded workroom's (`OpenRowReflow.anchor`).
      zone = measured.contains(item) ? .terminalRow(tab, in: owner) : .target(owner)
      content = SidebarOpenList.ghost(
        of: SidebarOpenTabRow(row: tabRow.model, tab: tabRow.tab, hovered: false, store: store),
        store: store)
      leaves = store.canMoveOpenTabToStandalone(tab, in: owner)
      joinable = Self.joinable(tab, of: owner, rows: rows, store: store)
    }
    guard let (rowRect, list) = Self.listRow(zone, in: store), list.contains(screen),
      let reflow = OpenRowReflow(
        items: items, dragged: item, leavesWorkroom: leaves, joinable: joinable,
        measured: measured)
    else { return }
    // Held by its middle, where the pointer came onto the list.
    start(
      reflow, in: store, window: window, content: content, row: rowRect, list: list,
      held: CGPoint(x: screen.x, y: rowRect.midY))
    isHandover = true
    follow(screen: screen)
  }

  /// A drag that lifted its row from outside the list (`handOver`) is at `screen`: the ghost and
  /// the gap follow it. `holds`: it is onto a row that takes the drop or refuses it.
  func handedOver(to screen: CGPoint, in store: AppStore, holds: Bool) {
    guard isHandover, reflow(for: store) != nil else { return }
    follow(screen: screen)
    move(to: screen, holds: holds)
  }

  /// Ends the lift a drag from outside the list made, not let go in it: its drag ended elsewhere,
  /// or was cancelled. The ghost fades, and the list goes back to its order.
  func endHandover(in store: AppStore) {
    guard isHandover, reflow(for: store) != nil else { return }
    drop()
  }
}
