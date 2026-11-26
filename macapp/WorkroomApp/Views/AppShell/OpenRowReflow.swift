import CoreGraphics
import WorkroomDomain

/// The Open list's order while one of its rows is lifted by a drag (#819): the other rows close
/// its slot and open a gap where it would land, and nothing reaches the store until the drop.
///
/// The lifted row stays in the List, hidden, and is the gap: moving it in the preview order slides
/// the rows round it with the List's own move animation. A lifted workroom row's tabs leave the
/// list with it and come back under it once it lands. A workroom row lands among the workroom
/// rows, past whole workrooms (a row and its tabs). A tab row lands among its own workroom's tabs;
/// among the tabs of another workroom that takes it (`joinable`), where let go it joins that
/// workroom in that place; or, when it can become a standalone terminal (`leavesWorkroom`), between
/// workrooms as well, as a workroom row would: let go there, it is one, in that place.
///
/// Where a lifted tab's gap goes is decided by the row under the pointer, and every workroom's
/// block has the same rule: the block (its row from its middle down, and its tabs) is among its
/// tabs, and its row's upper half is above the block, between workrooms. Another workroom's row's
/// middle half is onto it, a join at its end, which holds the gap (`liftedY`). A block's last slot
/// and the slot under the block are the same place in the list: the gap there is the block's while
/// the pointer came to it from the block, and between workrooms once the pointer has been past the
/// block's end (the next row's upper half, or below the list). A workroom that refuses the tab, or
/// shows no tabs, is a single row whose halves are above and below it.
///
/// A drag that started outside the list (a strip or title-bar tab) lifts its row as it comes over
/// the list; a tab whose workroom is folded is in `items` as a placeholder, which `measured`, the
/// list as the drag measured its drop zones, doesn't have.
///
/// Positions are the list's content space: y down from the top of its first row, in rows of one
/// `pitch`.
struct OpenRowReflow: Equatable {
  /// Where the lifted row would land.
  enum Landing: Equatable {
    /// At this index among `domain`.
    case among(Int)
    /// A lifted tab, between workrooms: just before the workroom row `workrooms[index]`, or after
    /// the last at `workrooms.count`.
    case between(Int)
    /// A lifted tab, among another workroom's tabs: just before its tab row at this index, or
    /// after its last.
    case into(SidebarID, Int)
  }

  /// The List's rows as the model had them when the row lifted, a placeholder for it included.
  let items: [OpenSectionItem]
  /// The List's rows as the drag measured its drop zones: `items` without a placeholder.
  let measured: [OpenSectionItem]
  /// Other workrooms a lifted tab can join among their tabs.
  let joinable: Set<SidebarID>
  let dragged: OpenSectionItem
  /// The rows it lands among, top to bottom, itself included.
  let domain: [OpenSectionItem]
  /// Rows out of the list while it is lifted: a lifted workroom's own tabs.
  let hidden: Set<OpenSectionItem>
  /// Its place among `domain` when it lifted.
  let origin: Int
  /// A lifted tab that can become a standalone terminal: it lands between workrooms too.
  let leavesWorkroom: Bool
  /// The workroom rows, top to bottom.
  let workrooms: [OpenSectionItem]
  /// Where it would land: nil while the pointer is outside the list, where no gap shows.
  private(set) var landing: Landing?

  init?(
    items: [OpenSectionItem], dragged: OpenSectionItem, leavesWorkroom: Bool = false,
    joinable: Set<SidebarID> = [], measured: [OpenSectionItem]? = nil
  ) {
    guard items.contains(dragged) else { return nil }
    let owner = dragged.owner
    switch dragged {
    case .workroom:
      domain = items.filter(\.isWorkroom)
      hidden = Set(items.filter { !$0.isWorkroom && $0.owner == owner })
      self.leavesWorkroom = false
      self.joinable = []
    case .tab:
      domain = items.filter { !$0.isWorkroom && $0.owner == owner }
      hidden = []
      self.leavesWorkroom = leavesWorkroom
      // Only those showing tabs: a workroom with none is one row, joined over its middle.
      self.joinable = joinable.filter { sid in
        sid != owner && items.contains { !$0.isWorkroom && $0.owner == sid }
      }
    }
    guard let origin = domain.firstIndex(of: dragged) else { return nil }
    self.items = items
    self.measured = measured ?? items
    self.dragged = dragged
    self.origin = origin
    workrooms = items.filter(\.isWorkroom)
    landing = .among(origin)
  }

  /// The index among `domain` a drop now gives it, nil when it would stay where it is or leave
  /// its workroom.
  var movedIndex: Int? {
    guard case .among(let index) = landing, index != origin else { return nil }
    return index
  }

  /// A lifted tab let go now becomes a standalone terminal between workrooms: the workroom tab
  /// above that place (nil: at the start) and the one below it (nil: at the end). Nil when it
  /// stays in its workroom, or is outside the list.
  var standalonePlace: (after: SidebarID?, before: SidebarID?)? {
    guard case .between(let index) = landing else { return nil }
    return (
      index > 0 ? workrooms[index - 1].owner : nil,
      index < workrooms.count ? workrooms[index].owner : nil
    )
  }

  /// A lifted tab let go now joins another workroom among its tabs: that workroom, and the tab it
  /// goes just before (nil: after its last). Nil anywhere else.
  var joinPlace: (into: SidebarID, before: TerminalTab.ID?)? {
    guard case .into(let sid, let index) = landing else { return nil }
    let tabs = tabRows(of: sid)
    guard index < tabs.count, case .tab(let before, _) = tabs[index] else { return (sid, nil) }
    return (sid, before)
  }

  /// Workroom `sid`'s tab rows as they were when the row lifted, the lifted one left out.
  private func tabRows(of sid: SidebarID) -> [OpenSectionItem] {
    items.filter { !$0.isWorkroom && $0.owner == sid && $0 != dragged }
  }

  /// The rows the List shows, top to bottom: the lifted row in the gap, or left out when there is
  /// none.
  var order: [OpenSectionItem] {
    let base = items.filter { !hidden.contains($0) }
    switch landing {
    case nil:
      return base.filter { $0 != dragged }
    case .into(let sid, let index):
      var rows = base.filter { $0 != dragged }
      let tabs = tabRows(of: sid)
      let at: Int
      if index < tabs.count, let before = rows.firstIndex(of: tabs[index]) {
        at = before
      } else if let last = tabs.last.flatMap({ rows.firstIndex(of: $0) }) {
        at = last + 1
      } else {
        at = (rows.firstIndex(of: .workroom(sid)) ?? rows.count - 1) + 1
      }
      rows.insert(dragged, at: min(at, rows.count))
      return rows
    case .between(let index):
      let blocks = Self.blocks(of: base.filter { $0 != dragged })
      var rows: [OpenSectionItem] = []
      for (at, lead) in workrooms.enumerated() {
        if at == index { rows.append(dragged) }
        rows += blocks[lead] ?? [lead]
      }
      if index >= workrooms.count { rows.append(dragged) }
      return rows
    case .among(let landing):
      var leads = domain.filter { $0 != dragged }
      leads.insert(dragged, at: min(landing, leads.count))
      if dragged.isWorkroom {
        let blocks = Self.blocks(of: base)
        return leads.flatMap { blocks[$0] ?? [$0] }
      }
      var rows: [OpenSectionItem] = []
      var placed = false
      for item in base {
        if domain.contains(item) {
          if !placed { rows += leads }
          placed = true
        } else {
          rows.append(item)
        }
      }
      return rows
    }
  }

  /// Each workroom row's block in `rows`: the row and the tabs under it.
  private static func blocks(of rows: [OpenSectionItem]) -> [OpenSectionItem: [OpenSectionItem]] {
    var blocks: [OpenSectionItem: [OpenSectionItem]] = [:]
    var current: OpenSectionItem?
    for item in rows {
      if item.isWorkroom {
        current = item
        blocks[item] = [item]
      } else if let current {
        blocks[current, default: []].append(item)
      }
    }
    return blocks
  }

  /// The pointer is at `y` in the list (nil: outside it). Over the gap nothing moves; over another
  /// row the gap goes before it while the pointer is in its upper half and after it in its lower
  /// half (lifting a workroom, after another workroom's tabs too), so a row the gap passes slides
  /// under a pointer that is then in the gap: no row flickers back. `holds`: the pointer is onto a row
  /// that takes the drop (or refuses it), which shows that instead of moving the gap.
  mutating func pointer(at y: CGFloat?, pitch: CGFloat, holds: Bool = false) {
    guard let y, pitch > 0 else {
      landing = nil
      return
    }
    if holds { return }
    if !dragged.isWorkroom {
      return tabPointer(at: y, pitch: pitch)
    }
    let units = self.units(in: order)
    let others = domain.filter { $0 != dragged }
    guard let first = units.first, let last = units.last else { return }
    if y < CGFloat(first.top) * pitch {
      landing = .among(0)
      return
    }
    if y >= CGFloat(last.top + last.count) * pitch {
      landing = .among(others.count)
      return
    }
    guard
      let unit = units.first(where: {
        y >= CGFloat($0.top) * pitch && y < CGFloat($0.top + $0.count) * pitch
      }), unit.lead != dragged, let index = others.firstIndex(of: unit.lead)
    else { return }
    // Judged on the unit's own row, a workroom's tabs under it being past it. Judged on the whole
    // block, its row's upper half would push the gap above it before the pointer reached the
    // row's middle, where a drop is onto it, and the row would slide away from under the pointer.
    let fraction = (y - CGFloat(unit.top) * pitch) / pitch
    landing = .among(fraction < 0.5 ? index : index + 1)
  }

  /// `pointer(at:)` for a lifted tab.
  private mutating func tabPointer(at y: CGFloat, pitch: CGFloat) {
    let rows = order
    let others = domain.filter { $0 != dragged }
    let own = OpenSectionItem.workroom(dragged.owner)
    let slot = Int((y / pitch).rounded(.down))
    guard y >= 0, slot < rows.count else {
      // Above the first row or below the last.
      if leavesWorkroom {
        landing = .between(y < 0 ? 0 : workrooms.count)
      } else {
        landing = .among(y < 0 ? 0 : others.count)
      }
      return
    }
    let row = rows[slot]
    if row == dragged { return }
    let fraction = y / pitch - CGFloat(slot)
    if row.owner == dragged.owner {
      if row.isWorkroom {
        // Its own workroom's row: its upper half is above the workroom, its lower half the start
        // of the workroom's tabs.
        if leavesWorkroom, fraction < 0.5, let index = workrooms.firstIndex(of: own) {
          landing = .between(index)
        } else {
          landing = .among(0)
        }
        return
      }
      guard let index = others.firstIndex(of: row) else { return }
      landing = .among(fraction < 0.5 ? index : index + 1)
      return
    }
    // Another workroom's block, whose tabs it can join: the block is among them, as its own is.
    if joinable.contains(row.owner) {
      if !row.isWorkroom, let index = tabRows(of: row.owner).firstIndex(of: row) {
        landing = .into(row.owner, fraction < 0.5 ? index : index + 1)
        return
      }
      // Its row's middle half is onto it (`liftedY`); its lower quarter starts its tabs.
      if row.isWorkroom, fraction >= 0.5 {
        landing = .into(row.owner, 0)
        return
      }
    }
    guard leavesWorkroom else {
      // Its tabs are the only place it lands: their start above them, their end below.
      let ownTop = rows.firstIndex(of: own) ?? 0
      landing = .among(slot < ownTop ? 0 : others.count)
      return
    }
    guard let index = workrooms.firstIndex(of: .workroom(row.owner)) else { return }
    // Judged on the workroom's own row, as a lifted workroom's gap is: its tabs are past it.
    landing = .between(row.isWorkroom && fraction < 0.5 ? index : index + 1)
  }

  /// The drag is cancelled: it goes back where it was.
  mutating func restore() { landing = .among(origin) }

  /// Where in `order` the lifted row is.
  var slot: Int? { order.firstIndex(of: dragged) }

  /// Where the pointer at `y` in the list (as it shows now) would be in the list as it was when
  /// the row lifted, which is where the drag measured the rows' drop zones: the same place on the
  /// same row. Nil over the gap and, lifting a tab, over its own workroom's rows, where the drop is
  /// this reorder's and no row's; over the tab rows of a workroom it can join, where its gap opens;
  /// and over another workroom row's upper quarter (lifting a tab that can leave its workroom) and
  /// lower quarter (that, or one whose tabs it can join), which are gaps: only its middle half is
  /// onto it (`AppStore.groupBand`).
  func liftedY(for y: CGFloat, pitch: CGFloat) -> CGFloat? {
    guard pitch > 0, y >= 0 else { return y }
    let rows = order
    let slot = Int((y / pitch).rounded(.down))
    guard rows.indices.contains(slot) else { return y }
    let row = rows[slot]
    if row == dragged { return nil }
    if !dragged.isWorkroom, row.owner == dragged.owner { return nil }
    // A tab row of a workroom it can join: the gap opens there, no row takes it.
    if !row.isWorkroom, joinable.contains(row.owner) { return nil }
    if row.isWorkroom, leavesWorkroom || joinable.contains(row.owner) {
      let fraction = y / pitch - CGFloat(slot)
      if fraction < 0.25 && leavesWorkroom || fraction >= 0.75 { return nil }
    }
    guard let was = measured.firstIndex(of: row) else { return nil }
    return y + CGFloat(was - slot) * pitch
  }

  /// The units `rows` holds, top to bottom, for a lifted workroom: a workroom row and its tabs.
  private func units(in rows: [OpenSectionItem]) -> [(lead: OpenSectionItem, top: Int, count: Int)]
  {
    var units: [(lead: OpenSectionItem, top: Int, count: Int)] = []
    for (index, item) in rows.enumerated() {
      if item.isWorkroom {
        units.append((item, index, 1))
      } else if !units.isEmpty {
        units[units.count - 1].count += 1
      }
    }
    return units
  }
}

extension OpenSectionItem {
  var isWorkroom: Bool {
    if case .workroom = self { return true }
    return false
  }

  /// The workroom tab the row is, or is under.
  var owner: SidebarID {
    switch self {
    case .workroom(let sid), .tab(_, let sid): return sid
    }
  }
}
