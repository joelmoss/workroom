import Foundation

/// One visited location in the back/forward history (issue #26): a target, the tab focused there, and
/// what that tab was showing.
///
/// Identity is `(target, tab, contentID, selectedPath)`; `payload` is replay data and is deliberately
/// outside `==` (see its doc). `tab` alone was the whole identity until content panes joined — every
/// focused terminal is still a distinct step (including the two on-screen panes of a split, and the
/// neighbour auto-focused after a close), so there is no split special-casing. Content needed more,
/// because the Changes/Files/History panels share ONE preview tab that is retargeted in place.
struct NavLocation: Equatable {
  let target: SidebarID
  /// The tab focused at the time. Always a real tab: a location is only ever recorded once a
  /// terminal is actually focused (see `AppStore.recordCurrentLocation`/`applyLocation`).
  let tab: TerminalTab.ID

  /// What the tab was *showing*, reduced to identity — `nil` for a terminal pane. Reuses
  /// `FocusedTabSelection`, the app's one canonical identity reduction of `TabContent` (the inspector
  /// rows already compare against it), so "the same place" cannot mean two different things in two
  /// places. Part of `==`.
  ///
  /// This is what makes back/forward work at all for content panes: the panels share ONE preview tab
  /// that is retargeted in place, so `(target, tab)` alone cannot tell "the diff I was just looking
  /// at" from "the diff I am looking at now".
  var contentID: FocusedTabSelection? = nil

  /// A changeset's in-commit file selection. Identity too — each selection is its own step — but it
  /// rides alongside `contentID` because `FocusedTabSelection.changeset` deliberately carries only the
  /// commit id (an inspector row matches on the commit, not the file). `nil` ⇒ the default (first) file.
  var selectedPath: String? = nil

  /// The descriptor replay needs to put this content back on screen. **Excluded from `==`** on
  /// purpose: descriptors carry fields that drift without changing which place this is —
  /// `DiffDescriptor.change` flips as a file is staged or deleted, `ChangesetDescriptor.title` is
  /// rebuilt from a fallback on replay, and `isPreview` flips on Keep Open (it is normalised to
  /// `false` here anyway). Including them would defeat `record`'s dedup and pile up steps that look
  /// identical on screen.
  var payload: NavPayload? = nil

  /// Identity only — see `payload`. Hand-written rather than derived for exactly that reason.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.target == rhs.target && lhs.tab == rhs.tab && lhs.contentID == rhs.contentID
      && lhs.selectedPath == rhs.selectedPath
  }
}

/// What replay needs to re-open a content pane: the whole descriptor, not just its identity.
///
/// Three cases, not four, and that asymmetry is deliberate: `TabContent.terminal` owns a live
/// `GhosttySurfaceView`, which a value-type history entry must never retain. A terminal location is
/// `payload == nil` — replay just re-focuses its tab. The `TabContent` bridge (and the exhaustive
/// switches that make a fifth content kind a compile error) lives beside `TabContent` itself.
enum NavPayload: Sendable {
  case diff(DiffDescriptor)
  case file(FileDescriptor)
  case changeset(ChangesetDescriptor)
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
  /// enablement stays honest — no entry that would no-op on replay survives (issue #26).
  ///
  /// Keyed on the tab id even for content entries, which now carry a `payload` that could in
  /// principle be re-opened without their original tab. That is the **rule**, not an oversight: back
  /// ignores anything that was closed, and nothing is ever reopened. The visible consequence, pinned
  /// by `NavigationHistoryTests`: browse three files in the shared preview tab and close it, and all
  /// three steps go with it — but an entry naming a tab you later pinned survives that tab's close,
  /// because the tab is still there. Two browse runs, different Back behaviour, decided by what you
  /// pinned afterwards.
  ///
  /// The cursor
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
