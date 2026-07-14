import Foundation

/// One visited location in the back/forward history (issue #26): a terminal target plus the
/// specific terminal tab focused there. `(target, tab)` is the whole identity — every focused
/// terminal is a distinct step (including the two on-screen panes of a split, and the neighbour
/// auto-focused after a close), so there is no split special-casing.
struct NavLocation: Equatable {
  let target: SidebarID
  /// The tab focused at the time. Always a real tab: a location is only ever recorded once a
  /// terminal is actually focused (see `AppStore.recordCurrentLocation`/`applyLocation`).
  let tab: TerminalTab.ID
  /// For a changeset tab, the commit it showed at record time — so the preview tab (retargeted across
  /// commits, which drifts its content) restores the right commit on replay. `nil` for other tabs.
  var commitID: String? = nil
  /// The commit's title, captured so replay can reopen the changeset without re-resolving it. `nil`
  /// unless `commitID` is set.
  var commitTitle: String? = nil
  /// The selected file at record time: the changed file within a changeset (or a diff tab's path).
  /// `nil` ⇒ the default (first) file. Makes each in-commit file selection its own step.
  var filePath: String? = nil
}

/// A linear, browser-style back/forward history of visited terminal locations (issue #26).
///
/// ```
///   entries:  [ L0   L1   L2   L3 ]
///   cursor:           └ 1                back → L0 · forward → L2
///   record(L4) while cursor == 1  →  [ L0  L1  L4 ]   (forward truncated, L4 appended, cursor = 2)
/// ```
///
/// Pure value type (no SwiftUI/AppKit) so it is directly unit-testable, mirroring `RootPresentation`
/// / `AppStore.validatedSelection`. Liveness — is a recorded target/tab still alive? — is supplied by
/// the caller as an `isLive` predicate at `step` time; the history itself never resolves against
/// `AppStore`, so dead entries (a closed tab / deleted workroom) are skipped on replay rather than
/// pruned eagerly.
struct NavigationHistory {
  private(set) var entries: [NavLocation] = []
  /// Index of the current location in `entries`; `-1` when empty.
  private(set) var cursor: Int = -1

  /// Upper bound on retained entries. When exceeded, the oldest fall off the front (and the cursor
  /// shifts with them) so a long session can't grow history without bound. Generous — a runaway
  /// backstop, not a tuning knob.
  static let maxEntries = 100

  /// Whether there is an entry behind the cursor. Cursor-based (D2): liveness is only checked at
  /// `step` time, so this can be optimistically `true` even when every prior entry is dead.
  var canGoBack: Bool { cursor > 0 }
  /// Whether there is an entry ahead of the cursor (cursor-based — see `canGoBack`).
  var canGoForward: Bool { cursor >= 0 && cursor < entries.count - 1 }

  /// The current location, or `nil` when empty.
  var current: NavLocation? { entries.indices.contains(cursor) ? entries[cursor] : nil }

  /// Record a newly-visited location. No-op when it equals the current entry (dedup against the
  /// immediate cursor only — revisiting the same place in a row doesn't pile up). Otherwise any
  /// forward entries are truncated (you navigated somewhere new), the location is appended, and the
  /// total is capped at `maxEntries`.
  mutating func record(_ loc: NavLocation) {
    if current == loc { return }
    if cursor < entries.count - 1 {
      entries.removeSubrange((cursor + 1)...)
    }
    entries.append(loc)
    cursor = entries.count - 1
    if entries.count > Self.maxEntries {
      let overflow = entries.count - Self.maxEntries
      entries.removeFirst(overflow)
      cursor -= overflow
    }
  }

  /// Drop every entry whose tab was removed (a closed tab / reaped workroom), so back/forward
  /// enablement stays honest — no entry that would no-op on replay survives (issue #26). The cursor
  /// is kept on the right surviving location: on the current entry if it survives, else just after
  /// the nearest surviving earlier entry (so Back lands on it). Any adjacent duplicate the removal
  /// exposes (the entry between two visits to the same place is gone) is collapsed, so Back never
  /// lands on a visibly identical location.
  mutating func prune(removing tabs: Set<TerminalTab.ID>) {
    guard !tabs.isEmpty, !entries.isEmpty else { return }
    let oldCursor = cursor
    var result: [NavLocation] = []
    var cursorIndex: Int? = nil  // new index of the surviving current entry, if it survives
    var survivorsBefore = 0  // count of (deduped) survivors with original index < oldCursor
    for (i, e) in entries.enumerated() {
      if tabs.contains(e.tab) { continue }
      let isDup = result.last == e
      if !isDup { result.append(e) }
      if i == oldCursor {
        cursorIndex = result.count - 1  // current survived (its slot, or the dup it merged into)
      } else if i < oldCursor, !isDup {
        survivorsBefore = result.count
      }
    }
    entries = result
    if result.isEmpty {
      cursor = -1
    } else if let cursorIndex {
      cursor = cursorIndex
    } else {
      cursor = min(survivorsBefore, result.count)  // current removed → after the last back-survivor
    }
  }

  /// Move the cursor one step in `direction` (`-1` = back, `+1` = forward), skipping any entry the
  /// caller reports dead via `isLive`, and return the landed location. Returns `nil` — leaving the
  /// cursor unchanged — when there is no live entry that way. (With pruning this rarely skips; it's
  /// a defensive net.)
  mutating func step(_ direction: Int, isLive: (NavLocation) -> Bool) -> NavLocation? {
    var i = cursor + direction
    while entries.indices.contains(i) {
      if isLive(entries[i]) {
        cursor = i
        return entries[i]
      }
      i += direction
    }
    return nil
  }
}
