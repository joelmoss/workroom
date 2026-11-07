import Observation

/// One tab's record, observed on its own: a view that reads one tab re-renders when that tab
/// changes, and not when any other tab in any window does. Nil once the tab has gone, so a reader
/// still holding the cell hears it go.
@MainActor
@Observable
public final class TabRecord<Tab> {
  public fileprivate(set) var tab: Tab?

  fileprivate init(_ tab: Tab) {
    self.tab = tab
  }
}

/// Every tab of the app, by id, and which holder's layout has each one (D2 as revised by eng review
/// D4). A tab is a value whose id is the one the layouts (`TargetPanes`) arrange; its record lives
/// here once, whichever window shows it, so a move between windows changes only who holds it.
///
/// The record dictionary itself is not observed: it changes as tabs come and go anywhere, and a
/// view reading it would re-render for every window's tabs (the WORKROOM-2B class). Each record is
/// its own observable (`TabRecord`), and a layout's order, which a view reads to find its tabs,
/// changes whenever one joins or leaves it.
///
/// **A tab is held by at most one holder at a time.** Storing or claiming a tab another holder has
/// is refused, and a hand-over between windows releases the tabs (in transit, held by none) before
/// the other window claims them.
@MainActor
public final class TabRecords<Tab: Identifiable, Holder: Hashable> {
  private var records: [Tab.ID: TabRecord<Tab>] = [:]
  private var holders: [Tab.ID: Holder] = [:]

  public init() {}

  /// `id`'s record, or nil when there is no such tab. Observed per tab.
  public subscript(id: Tab.ID) -> Tab? { records[id]?.tab }

  /// The records of `ids`, in that order, skipping any that has none.
  public func records(_ ids: [Tab.ID]) -> [Tab] { ids.compactMap { self[$0] } }

  /// Who holds `id`, or nil when nobody does (no such tab, or one in transit between windows).
  public func holder(of id: Tab.ID) -> Holder? { holders[id] }

  /// The tabs `holder` holds, in no meaningful order.
  public func ids(heldBy holder: Holder) -> [Tab.ID] {
    holders.compactMap { $0.value == holder ? $0.key : nil }
  }

  /// Store `tab` for `holder`, adding it or replacing its record. A new tab, or one in transit, is
  /// `holder`'s from now on. Refused, and nothing stored, when another holder has it.
  @discardableResult
  public func set(_ tab: Tab, by holder: Holder) -> Bool {
    if let current = holders[tab.id], current != holder { return false }
    holders[tab.id] = holder
    if let record = records[tab.id] {
      record.tab = tab
    } else {
      records[tab.id] = TabRecord(tab)
    }
    return true
  }

  /// Drop `id` altogether: its record (whose readers hear it go) and its holder.
  @discardableResult
  public func remove(_ id: Tab.ID) -> Tab? {
    holders[id] = nil
    guard let record = records.removeValue(forKey: id) else { return nil }
    let tab = record.tab
    record.tab = nil
    return tab
  }

  /// Let go of the tabs of `ids` that `holder` holds, keeping their records: they are in transit
  /// to another holder, who `claim`s them.
  public func release(_ ids: some Sequence<Tab.ID>, by holder: Holder) {
    for id in ids where holders[id] == holder { holders[id] = nil }
  }

  /// Take `ids` for `holder`. Refused (returns false, and claims none) when any of them is another
  /// holder's or has no record.
  @discardableResult
  public func claim(_ ids: [Tab.ID], by holder: Holder) -> Bool {
    guard ids.allSatisfy({ records[$0] != nil && (holders[$0] ?? holder) == holder }) else {
      return false
    }
    for id in ids { holders[id] = holder }
    return true
  }

  /// Drop every tab `holder` holds (its window has gone), and return their ids.
  @discardableResult
  public func removeAll(heldBy holder: Holder) -> [Tab.ID] {
    let ids = ids(heldBy: holder)
    for id in ids { remove(id) }
    return ids
  }
}
