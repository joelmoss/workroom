import CoreGraphics
import WorkroomDomain

/// How an Open list grouped other than by workroom (`OpenTabsGrouping`) nests its rows, for a
/// lift: which top-level block each row is in, and the title-bar tabs each block holds.
struct OpenRowShape: Equatable {
  /// Each row's top-level block: its project's (`.project(path)`) in a project grouping, else its
  /// own target's.
  let block: [OpenTabsItem: SidebarID]
  /// Each block's targets, in the title bar's order.
  let titleBar: [SidebarID: [SidebarID]]
  /// The workroom rows under their project's header (Project › Workroom).
  let nested: Set<OpenTabsItem>
}

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
/// Grouped otherwise (`shape`), the blocks are the top-level ones: a project's header and
/// everything under it, or a target with no project. A lifted header or top-level row lands among
/// them, its block with it; a workroom row under its project's header lands among that project's
/// workrooms. A lifted tab's gap over a tab row joins that row's workroom, before or after it by
/// half; between blocks it is a standalone terminal there; a header's lower half, or a workroom
/// row under one, starts that workroom's tabs.
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
    /// A lifted tab, between blocks: just before block `blocks[index]`, or after the last at
    /// `blocks.count`.
    case between(Int)
    /// A lifted tab, among another workroom's tabs: just before its tab row at this index, or
    /// after its last.
    case into(SidebarID, Int)
  }

  /// Where in the title bar a lifted row's targets go when let go in a grouped list.
  enum TitleBarPlace: Equatable {
    case before(SidebarID)
    case after(SidebarID)
    case end
    /// In the title-bar slots the moved tabs hold now, in the order given: a reorder within a
    /// project, which keeps its place among the other targets.
    case inTheirSlots
  }

  /// The List's rows as the model had them when the row lifted, a placeholder for it included.
  let items: [OpenTabsItem]
  /// The List's rows as the drag measured its drop zones: `items` without a placeholder.
  let measured: [OpenTabsItem]
  /// Other workrooms a lifted tab can join among their tabs.
  let joinable: Set<SidebarID>
  let dragged: OpenTabsItem
  /// The rows it lands among, top to bottom, itself included.
  let domain: [OpenTabsItem]
  /// Rows out of the list while it is lifted: a lifted workroom's own tabs, a lifted header's
  /// project.
  let hidden: Set<OpenTabsItem>
  /// Its place among `domain` when it lifted.
  let origin: Int
  /// A lifted tab that can become a standalone terminal: it lands between blocks too.
  let leavesWorkroom: Bool
  /// The top-level blocks, top to bottom: each workroom tab's, or, grouped, each project's and
  /// each target's with no project.
  let blocks: [SidebarID]
  /// How a grouped list nests its rows; nil grouped by workroom.
  let shape: OpenRowShape?
  /// `domain` without the lifted row.
  private let others: [OpenTabsItem]
  /// Each row's index in `measured`.
  private let measuredIndex: [OpenTabsItem: Int]
  /// Where it would land: nil while the pointer is outside the list, where no gap shows.
  private(set) var landing: Landing? {
    didSet {
      if landing != oldValue { order = arranged() }
    }
  }
  /// The rows the List shows, top to bottom: the lifted row in the gap, or left out when there is
  /// none. Arranged again only when `landing` changes, as the pointer reads it on every move.
  private(set) var order: [OpenTabsItem] = []

  init?(
    items: [OpenTabsItem], dragged: OpenTabsItem, leavesWorkroom: Bool = false,
    joinable: Set<SidebarID> = [], measured: [OpenTabsItem]? = nil, shape: OpenRowShape? = nil
  ) {
    guard items.contains(dragged) else { return nil }
    self.shape = shape
    let blockOf = { (item: OpenTabsItem) in shape?.block[item] ?? item.owner }
    var blocks: [SidebarID] = []
    for item in items where blocks.last != blockOf(item) { blocks.append(blockOf(item)) }
    let owner = dragged.owner
    switch dragged {
    case .workroom, .project:
      if let shape, shape.nested.contains(dragged) {
        // Among its project's workrooms; its root, which the list keeps first, alone.
        let project = blockOf(dragged)
        domain =
          dragged.isRoot
          ? [dragged]
          : items.filter { shape.nested.contains($0) && blockOf($0) == project && !$0.isRoot }
        hidden = Set(items.filter { $0.isTab && $0.owner == owner })
      } else {
        // Among the blocks' first rows, its block with it.
        domain = items.enumerated().filter { index, item in
          index == 0 || blockOf(items[index - 1]) != blockOf(item)
        }.map(\.element)
        hidden = Set(items.filter { $0 != dragged && blockOf($0) == blockOf(dragged) })
      }
      self.leavesWorkroom = false
      self.joinable = []
    case .tab:
      domain = items.filter { $0.isTab && $0.owner == owner }
      hidden = []
      self.leavesWorkroom = leavesWorkroom
      // Only those showing tabs: a workroom with none is one row, joined over its middle.
      self.joinable = joinable.filter { sid in
        sid != owner && items.contains { $0.isTab && $0.owner == sid }
      }
    }
    guard let origin = domain.firstIndex(of: dragged) else { return nil }
    self.items = items
    let measured = measured ?? items
    self.measured = measured
    // The first, as `firstIndex(of:)` finds.
    measuredIndex = Dictionary(
      measured.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    self.dragged = dragged
    self.origin = origin
    self.blocks = blocks
    others = domain.filter { $0 != dragged }
    landing = .among(origin)
    order = arranged()
  }

  /// `item`'s top-level block.
  private func block(of item: OpenTabsItem) -> SidebarID { shape?.block[item] ?? item.owner }

  /// Block `block`'s targets, in the title bar's order.
  private func titleBar(of block: SidebarID) -> [SidebarID] { shape?.titleBar[block] ?? [block] }

  /// What a lifted lead row moves as one with `item`: its block's rows, or, under its project's
  /// header, its workroom's.
  private func unit(of item: OpenTabsItem) -> SidebarID {
    liftsNested ? item.owner : block(of: item)
  }

  /// Whether the lifted row is a tab's.
  private var liftsTab: Bool { dragged.isTab }

  /// Whether the lifted row is a workroom row under its project's header.
  private var liftsNested: Bool { shape?.nested.contains(dragged) == true }

  /// The row whose place on screen measures the list: the lifted row's own, or, for a placeholder,
  /// its folded workroom's, or its folded project's header.
  var anchor: OpenTabsItem {
    if measured.contains(dragged) { return dragged }
    let own = OpenTabsItem.workroom(dragged.owner)
    if measured.contains(own) || shape == nil { return own }
    return measured.first { block(of: $0) == block(of: dragged) } ?? own
  }

  /// The index among `domain` a drop now gives it, nil when it would stay where it is or leave
  /// its workroom.
  var movedIndex: Int? {
    guard case .among(let index) = landing, index != origin else { return nil }
    return index
  }

  /// A lifted row of a grouped list let go now: the title-bar tabs it moves, and where they go,
  /// as its block's (a project's targets, or a target's) or, under its project's header, its
  /// project's reordered in the slots they hold, its workroom beside the sibling it lands by. Nil
  /// where it stays, or grouped by workroom, where `movedIndex` is the title bar's.
  var titleBarMove: (moving: [SidebarID], place: TitleBarPlace)? {
    guard shape != nil, !liftsTab, let index = movedIndex else { return nil }
    var landed = others
    landed.insert(dragged, at: min(index, landed.count))
    let at = min(index, landed.count - 1)
    if liftsNested {
      // Its project's targets reordered in the slots they hold, so its header, at its first
      // target, stays where it is although other targets are between them.
      var project = titleBar(of: block(of: dragged)).filter { $0 != dragged.owner }
      if at + 1 < landed.count, let next = project.firstIndex(of: landed[at + 1].owner) {
        project.insert(dragged.owner, at: next)
      } else if at > 0, let previous = project.firstIndex(of: landed[at - 1].owner) {
        project.insert(dragged.owner, at: previous + 1)
      } else {
        return nil
      }
      return (project, .inTheirSlots)
    }
    let moving = titleBar(of: block(of: dragged))
    guard at + 1 < landed.count, let next = titleBar(of: block(of: landed[at + 1])).first else {
      return (moving, .end)
    }
    return (moving, .before(next))
  }

  /// A lifted tab let go now becomes a standalone terminal between blocks: the workroom tab above
  /// that place (nil: at the start) and the one below it (nil: at the end). Nil when it stays in
  /// its workroom, or is outside the list.
  var standalonePlace: (after: SidebarID?, before: SidebarID?)? {
    guard case .between(let index) = landing else { return nil }
    return (
      index > 0 ? titleBar(of: blocks[index - 1]).last : nil,
      index < blocks.count ? titleBar(of: blocks[index]).first : nil
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
  private func tabRows(of sid: SidebarID) -> [OpenTabsItem] {
    items.filter { $0.isTab && $0.owner == sid && $0 != dragged }
  }

  /// `order` for `landing`.
  private func arranged() -> [OpenTabsItem] {
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
      let byBlock = Dictionary(grouping: base.filter { $0 != dragged }) { block(of: $0) }
      var rows: [OpenTabsItem] = []
      for (at, block) in blocks.enumerated() {
        if at == index { rows.append(dragged) }
        rows += byBlock[block] ?? []
      }
      if index >= blocks.count { rows.append(dragged) }
      return rows
    case .among(let landing):
      var leads = others
      leads.insert(dragged, at: min(landing, leads.count))
      if !liftsTab {
        // Each lead with the rows it heads: its block's, or, under a header, its workroom's.
        let inUnits = Set(leads.map(unit(of:)))
        let units = Dictionary(
          grouping: base.filter { inUnits.contains(unit(of: $0)) }, by: unit(of:))
        var rows: [OpenTabsItem] = []
        var placed = false
        for item in base {
          guard inUnits.contains(unit(of: item)) else {
            rows.append(item)
            continue
          }
          if !placed { rows += leads.flatMap { units[unit(of: $0)] ?? [$0] } }
          placed = true
        }
        return rows
      }
      var rows: [OpenTabsItem] = []
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

  /// The units a lifted row lands among in `rows`, top to bottom: each of `domain`'s rows and the
  /// rows it heads, and where in `rows` it starts.
  private func units(of rows: [OpenTabsItem]) -> [(top: Int, rows: [OpenTabsItem])] {
    let leads = Set(domain.map(unit(of:)))
    var units: [(top: Int, rows: [OpenTabsItem])] = []
    var current: SidebarID?
    for (index, item) in rows.enumerated() {
      let unit = unit(of: item)
      guard leads.contains(unit) else {
        current = nil
        continue
      }
      if unit == current {
        units[units.count - 1].rows.append(item)
      } else {
        units.append((index, [item]))
        current = unit
      }
    }
    return units
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
    if liftsTab {
      return tabPointer(at: y, pitch: pitch)
    }
    // Units of a lead row and the rows it heads.
    let units = units(of: order)
    guard let first = units.first, let last = units.last else { return }
    if y < CGFloat(first.top) * pitch {
      landing = .among(0)
      return
    }
    if y >= CGFloat(last.top + last.rows.count) * pitch {
      landing = .among(others.count)
      return
    }
    guard
      let unit = units.first(where: {
        y >= CGFloat($0.top) * pitch && y < CGFloat($0.top + $0.rows.count) * pitch
      }), unit.rows[0] != dragged, let index = others.firstIndex(of: unit.rows[0])
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
    let slot = Int((y / pitch).rounded(.down))
    guard y >= 0, slot < rows.count else {
      // Above the first row or below the last.
      if leavesWorkroom {
        landing = .between(y < 0 ? 0 : blocks.count)
      } else {
        landing = .among(y < 0 ? 0 : others.count)
      }
      return
    }
    let row = rows[slot]
    if row == dragged { return }
    let fraction = y / pitch - CGFloat(slot)
    let nested = shape?.nested.contains(row) == true
    if case .project = row {
      // A project's header: its upper half is above its project, between blocks; its lower half
      // the start of its first workroom's tabs.
      if fraction < 0.5 {
        if leavesWorkroom, let index = blocks.firstIndex(of: block(of: row)) {
          landing = .between(index)
        }
        return
      }
      guard
        let first = rows[(slot + 1)...].first(where: {
          $0 != dragged && block(of: $0) == block(of: row)
        })
      else { return }
      if first.owner == dragged.owner {
        landing = .among(0)
      } else if joinable.contains(first.owner) {
        landing = .into(first.owner, 0)
      }
      return
    }
    if row.owner == dragged.owner {
      if row.isWorkroom {
        // Its own workroom's row: its upper half is above the workroom, its lower half the start
        // of the workroom's tabs. Under a header, all of it is the start of its tabs.
        if leavesWorkroom, fraction < 0.5, !nested,
          let index = blocks.firstIndex(of: block(of: row))
        {
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
      if row.isTab, let index = tabRows(of: row.owner).firstIndex(of: row) {
        landing = .into(row.owner, fraction < 0.5 ? index : index + 1)
        return
      }
      // Its row's middle half is onto it (`liftedY`); its lower quarter starts its tabs. Under a
      // header, all of it does.
      if row.isWorkroom, fraction >= 0.5 || nested {
        landing = .into(row.owner, 0)
        return
      }
    }
    // Grouped, a tab or nested row of a workroom that won't take it is nowhere it lands.
    if shape != nil, row.isTab || nested { return }
    guard leavesWorkroom else {
      // Its tabs are the only place it lands: their start above them, their end below.
      let ownTop = rows.firstIndex { $0.owner == dragged.owner } ?? 0
      landing = .among(slot < ownTop ? 0 : others.count)
      return
    }
    guard let index = blocks.firstIndex(of: block(of: row)) else { return }
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
  /// over a project's header and a workroom row under one that shows tabs, which only open gaps;
  /// and over another
  /// workroom row's upper quarter (lifting a tab that can leave its workroom) and lower quarter
  /// (that, or one whose tabs it can join), which are gaps: only its middle half is onto it
  /// (`AppStore.groupBand`).
  func liftedY(for y: CGFloat, pitch: CGFloat) -> CGFloat? {
    guard pitch > 0, y >= 0 else { return y }
    let rows = order
    let slot = Int((y / pitch).rounded(.down))
    guard rows.indices.contains(slot) else { return y }
    let row = rows[slot]
    if row == dragged { return nil }
    if case .project = row { return nil }
    if liftsTab, row.owner == dragged.owner { return nil }
    // A workroom row under a header showing tabs it can join only opens a gap; folded, it is a
    // row like any other, onto which a drop joins it.
    if liftsTab, shape?.nested.contains(row) == true, joinable.contains(row.owner) { return nil }
    // A tab row of a workroom it can join: the gap opens there, no row takes it.
    if row.isTab, joinable.contains(row.owner) { return nil }
    if row.isWorkroom, leavesWorkroom || joinable.contains(row.owner) {
      let fraction = y / pitch - CGFloat(slot)
      if fraction < 0.25 && leavesWorkroom || fraction >= 0.75 { return nil }
    }
    guard let was = measuredIndex[row] else { return nil }
    return y + CGFloat(was - slot) * pitch
  }
}

extension OpenTabsItem {
  var isWorkroom: Bool {
    if case .workroom = self { return true }
    return false
  }

  var isTab: Bool {
    if case .tab = self { return true }
    return false
  }

  /// A project root's row, which a project grouping lists first in its project.
  var isRoot: Bool {
    if case .workroom(.root) = self { return true }
    return false
  }

  /// The workroom tab the row is, or is under; a project's header is its project's.
  var owner: SidebarID {
    switch self {
    case .workroom(let sid), .tab(_, let sid): return sid
    case .project(let path): return .project(path)
    }
  }
}
