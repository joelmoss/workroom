import CoreGraphics
import WorkroomDomain

/// The Open list's order while one of its rows is lifted by a drag (#819): the other rows close
/// its slot and open a gap where it would land, and nothing reaches the store until the drop.
///
/// The lifted row stays in the List, hidden, and is the gap: moving it in the preview order slides
/// the rows round it with the List's own move animation. A lifted workroom row's tabs leave the
/// list with it and come back under it once it lands. A workroom row lands among the workroom
/// rows, past whole workrooms (a row and its tabs); a tab row among its own workroom's tabs.
///
/// Positions are the list's content space: y down from the top of its first row, in rows of one
/// `pitch`.
struct OpenRowReflow: Equatable {
  /// The List's rows as the model had them when the row lifted.
  let items: [OpenSectionItem]
  let dragged: OpenSectionItem
  /// The rows it lands among, top to bottom, itself included.
  let domain: [OpenSectionItem]
  /// Rows out of the list while it is lifted: a lifted workroom's own tabs.
  let hidden: Set<OpenSectionItem>
  /// Its place among `domain` when it lifted.
  let origin: Int
  /// Where among `domain` it would land: nil while the pointer is outside the list, where no gap
  /// shows.
  private(set) var landing: Int?

  init?(items: [OpenSectionItem], dragged: OpenSectionItem) {
    guard items.contains(dragged) else { return nil }
    let owner = dragged.owner
    switch dragged {
    case .workroom:
      domain = items.filter(\.isWorkroom)
      hidden = Set(items.filter { !$0.isWorkroom && $0.owner == owner })
    case .tab:
      domain = items.filter { !$0.isWorkroom && $0.owner == owner }
      hidden = []
    }
    guard let origin = domain.firstIndex(of: dragged) else { return nil }
    self.items = items
    self.dragged = dragged
    self.origin = origin
    landing = origin
  }

  /// The index among `domain` a drop now gives it, nil when it would stay where it is.
  var movedIndex: Int? { landing.flatMap { $0 == origin ? nil : $0 } }

  /// The rows the List shows, top to bottom: the lifted row in the gap, or left out when there is
  /// none.
  var order: [OpenSectionItem] {
    let base = items.filter { !hidden.contains($0) }
    guard let landing else { return base.filter { $0 != dragged } }
    var leads = domain.filter { $0 != dragged }
    leads.insert(dragged, at: min(landing, leads.count))
    if dragged.isWorkroom {
      var blocks: [OpenSectionItem: [OpenSectionItem]] = [:]
      var current: OpenSectionItem?
      for item in base {
        if item.isWorkroom {
          current = item
          blocks[item] = [item]
        } else if let current {
          blocks[current, default: []].append(item)
        }
      }
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
    let units = self.units(in: order)
    let others = domain.filter { $0 != dragged }
    guard let first = units.first, let last = units.last else { return }
    if y < CGFloat(first.top) * pitch {
      landing = 0
      return
    }
    if y >= CGFloat(last.top + last.count) * pitch {
      landing = others.count
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
    landing = fraction < 0.5 ? index : index + 1
  }

  /// The drag is cancelled: it goes back where it was.
  mutating func restore() { landing = origin }

  /// Where in `order` the lifted row is.
  var slot: Int? { order.firstIndex(of: dragged) }

  /// Where the pointer at `y` in the list (as it shows now) would be in the list as it was when
  /// the row lifted, which is where the drag measured the rows' drop zones: the same place on the
  /// same row. Nil over the gap and, lifting a tab, over its own workroom's rows, where the drop is
  /// this reorder's and no row's.
  func liftedY(for y: CGFloat, pitch: CGFloat) -> CGFloat? {
    guard pitch > 0, y >= 0 else { return y }
    let rows = order
    let slot = Int((y / pitch).rounded(.down))
    guard rows.indices.contains(slot) else { return y }
    let row = rows[slot]
    if row == dragged { return nil }
    if !dragged.isWorkroom, row.owner == dragged.owner { return nil }
    guard let was = items.firstIndex(of: row) else { return nil }
    return y + CGFloat(was - slot) * pitch
  }

  /// The units `rows` holds, top to bottom: a workroom row and its tabs, or one tab of the lifted
  /// tab's workroom.
  private func units(in rows: [OpenSectionItem]) -> [(lead: OpenSectionItem, top: Int, count: Int)]
  {
    var units: [(lead: OpenSectionItem, top: Int, count: Int)] = []
    for (index, item) in rows.enumerated() {
      if dragged.isWorkroom {
        if item.isWorkroom {
          units.append((item, index, 1))
        } else if !units.isEmpty {
          units[units.count - 1].count += 1
        }
      } else if domain.contains(item) {
        units.append((item, index, 1))
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
