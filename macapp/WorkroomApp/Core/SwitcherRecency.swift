import Foundation

/// A window's identity for the quick switcher (issue #132), stable for that window's whole life and
/// **never reused**.
///
/// Deliberately not `AppStore.windowNumber`: that is a *display* number, assigned as the smallest
/// unused positive integer and reclaimed the moment a window closes
/// (`WindowRegistry.assignWindowNumberIfNeeded`), so a closed window's number aliases onto the next
/// new window. And deliberately not `ObjectIdentifier(store)`, which is the store's address — a new
/// `AppStore` allocated where a freed one lived compares equal. Both would let a dead window's
/// recency (and, in stage 2, its cached thumbnails) surface in a fresh window. A UUID minted with the
/// store cannot.
struct WindowToken: Hashable {
  private let raw: UUID
  init() { raw = UUID() }
}

/// A workroom *as opened in one window* — the unit ⌥Tab switches between.
///
/// The window is part of the identity because `TerminalSessions` is per-window: the same workroom can
/// be open in two windows with different tabs, and they are two different places to switch to.
struct WorkroomSlotID: Hashable {
  let window: WindowToken
  let sid: SidebarID
}

/// One entry of the ⌥Tab rail: a workroom, the window it lives in, and its resolved target.
struct WorkroomSlot {
  weak var store: AppStore?
  let sid: SidebarID
  let target: TerminalTarget

  var id: WorkroomSlotID? { store.map { WorkroomSlotID(window: $0.windowToken, sid: sid) } }
}

/// A most-recently-used order over ids, and the ordering rule the switcher rail is built from.
///
/// ```
///   ids (most recent first):  [ C  A  B ]
///   touch(A)               →  [ A  C  B ]
///   ordered([A, B, C, D])  →  [ A  C  B  D ]   ← D never touched, so it keeps its given position
/// ```
///
/// Pure value type (no AppKit/SwiftUI, no store access) so every rule above is directly unit-testable,
/// mirroring `NavigationHistory` / `RootPresentation`. It never resolves liveness itself: the caller
/// passes the currently-live items to `ordered`, and ids it has never heard of simply sort last in the
/// order they arrived — so a workroom you have not visited this session still appears on the rail.
struct RecencyList<ID: Hashable>: Equatable {
  /// Most-recent first.
  private(set) var ids: [ID] = []

  /// Upper bound on retained ids; the oldest fall off the back. Generous — a runaway backstop for a
  /// long session, not a tuning knob (recency is in-memory and session-scoped).
  static var maxEntries: Int { 200 }

  /// Promote `id` to most-recent, inserting it when new. Called from the selection/focus write-points,
  /// so it must stay O(count) with a tiny constant — no allocation beyond the array move.
  mutating func touch(_ id: ID) {
    if let existing = ids.firstIndex(of: id) {
      if existing == 0 { return }
      ids.remove(at: existing)
    }
    ids.insert(id, at: 0)
    if ids.count > Self.maxEntries { ids.removeLast(ids.count - Self.maxEntries) }
  }

  /// Forget one id (its pane/workroom is gone).
  mutating func forget(_ id: ID) { ids.removeAll { $0 == id } }

  /// Drop every id that is no longer live, preserving the order of the survivors. Cheap housekeeping
  /// called at session open; correctness does not depend on it, because `ordered` only ever emits ids
  /// belonging to the items it was handed.
  mutating func retain(_ live: Set<ID>) { ids.removeAll { !live.contains($0) } }

  /// **The rail order.** Items whose id is known sort by recency (most recent first); items never
  /// touched follow, in the order given. Stable and total — every input item appears exactly once.
  func ordered<T>(_ items: [T], id: (T) -> ID) -> [T] {
    guard !ids.isEmpty else { return items }
    var rank: [ID: Int] = [:]
    rank.reserveCapacity(ids.count)
    for (i, existing) in ids.enumerated() { rank[existing] = i }
    return items.enumerated()
      .sorted { lhs, rhs in
        let l = rank[id(lhs.element)] ?? Int.max
        let r = rank[id(rhs.element)] ?? Int.max
        if l != r { return l < r }
        return lhs.offset < rhs.offset  // untouched items keep their incoming order
      }
      .map(\.element)
  }
}

/// App-global most-recently-used order for the quick switcher (issue #132): one list for workrooms
/// (across every window), one for panes.
///
/// Standalone rather than folded into `WindowRegistry`, whose charter is key routing / last-active /
/// aggregation / run ownership / quit — recency is none of those, and keeping it here keeps
/// `RecencyList` a trivially testable value type.
///
/// **Recording is unconditional.** Both write-points sit *above* `AppStore`'s `isNavigatingHistory`
/// guard, because `applyLocation` raises that flag for its whole body and the switcher's own commit
/// goes through it — a gated write would never record where the switcher just took you, and ⌥Tab
/// would ping-pong between two places forever. Recency answers "where did the user actually end up",
/// which is true for a switcher commit, a ⌘[ back-nav and a sidebar click alike; history suppression
/// is a different question (avoid phantom *history* entries).
@MainActor
final class SwitcherRecency {
  static let shared = SwitcherRecency()

  private(set) var workrooms = RecencyList<WorkroomSlotID>()
  /// Panes key on `TerminalTab.ID` alone — a UUID, unique across every window.
  private(set) var panes = RecencyList<TerminalTab.ID>()

  /// Test seam: a fresh instance, so a test never mutates the singleton's order.
  init() {}

  func recordWorkroom(store: AppStore, sid: SidebarID?) {
    guard let sid else { return }
    workrooms.touch(WorkroomSlotID(window: store.windowToken, sid: sid))
  }

  func recordPane(_ id: TerminalTab.ID?) {
    guard let id else { return }
    panes.touch(id)
  }

  func forgetPanes(_ ids: [TerminalTab.ID]) {
    for id in ids { panes.forget(id) }
  }

  /// MRU-order the rail's workroom slots, pruning recency down to what is live while here. A slot
  /// whose store has gone away has no identity and drops out.
  func workroomOrder(_ slots: [WorkroomSlot]) -> [WorkroomSlot] {
    let identified = slots.compactMap { slot -> (slot: WorkroomSlot, id: WorkroomSlotID)? in
      slot.id.map { (slot, $0) }
    }
    workrooms.retain(Set(identified.map(\.id)))
    return workrooms.ordered(identified) { $0.id }.map(\.slot)
  }

  /// MRU-order one workroom's panes.
  func paneOrder(_ tabs: [TerminalTab]) -> [TerminalTab] {
    panes.ordered(tabs) { $0.id }
  }
}
