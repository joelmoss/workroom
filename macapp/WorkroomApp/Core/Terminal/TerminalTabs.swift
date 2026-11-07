import Foundation
import TerminalModel

/// Every terminal tab of the app, by id: its record (`TerminalTab`: content, session, live and
/// agent state) and, for a terminal, its surface (D2 as revised by eng review D4, ADR 0069). Each
/// window's `TerminalSessions` keeps only its layout, per target, over these ids (`TargetPanes`),
/// so a tab lives here once, whichever window shows it, and a move between windows (#444, and the
/// Q12 merge into a window already showing the workroom) shifts ids from one layout to another
/// while the tab itself stays put. Nothing per tab travels, so nothing per tab can be dropped on
/// the way.
///
/// Each tab is held by one window at a time (`TabRecords`): the window whose layout has it. The
/// window reads its tabs here only through its own layout, so it never sees another window's.
///
/// Production and tests share `.shared`, as windows share it: a window that goes takes its tabs
/// with it (`TerminalSessions`' `deinit`), as its store once did.
@MainActor
final class TerminalTabs {
  static let shared = TerminalTabs()

  private let records = TabRecords<TerminalTab, UUID>()
  private var surfaces = SurfaceRegistry()

  /// `id`'s record, observed per tab.
  func record(_ id: TerminalTab.ID) -> TerminalTab? { records[id] }

  /// The records of `ids`, in that order, skipping any that has gone.
  func records(_ ids: [TerminalTab.ID]) -> [TerminalTab] { records.records(ids) }

  /// The window holding `id`, or nil (no such tab, or one between windows).
  func holder(of id: TerminalTab.ID) -> UUID? { records.holder(of: id) }

  /// Store `tab` for `holder`, adding it or replacing its record: refused when another window holds
  /// it, which a window reading through its own layout never asks.
  @discardableResult
  func set(_ tab: TerminalTab, by holder: UUID) -> Bool { records.set(tab, by: holder) }

  /// `id`'s surface while `holder` holds it: nil for a content tab, or a tab another window holds.
  func surface(of id: TerminalTab.ID, heldBy holder: UUID) -> GhosttySurfaceView? {
    records.holder(of: id) == holder ? surfaces[id] : nil
  }

  /// Keep `view` as `id`'s surface, from the moment its tab is made.
  func register(_ view: GhosttySurfaceView, for id: TerminalTab.ID) {
    surfaces.register(view, for: id)
  }

  /// Drop `id` altogether, record and surface: it closed or was reaped. The surface is torn down
  /// first, by the window that held it.
  func remove(_ id: TerminalTab.ID) {
    records.remove(id)
    surfaces.remove(id)
  }

  /// `holder` lets go of `ids` without ending them, for another window to `claim`.
  func release(_ ids: some Sequence<TerminalTab.ID>, by holder: UUID) {
    records.release(ids, by: holder)
  }

  /// `holder` takes `ids` another window let go of. False, and none taken, when any is held
  /// elsewhere: one layout at a time.
  @discardableResult
  func claim(_ ids: [TerminalTab.ID], by holder: UUID) -> Bool { records.claim(ids, by: holder) }

  /// `holder`'s window has gone: drop every tab it held, record and surface.
  func removeAll(heldBy holder: UUID) {
    for id in records.removeAll(heldBy: holder) { surfaces.remove(id) }
  }
}
