import Combine
import Foundation

/// Scrollback **find** (search) for the embedded terminals. Workroom adds no search engine of its
/// own — libghostty (the bundled engine; see `macapp/project.yml` for which build) shipped it and
/// owns the matching, viewport highlighting, and match tracking. This file is the host side: the
/// thin chrome (a find bar) plus the two engine-free seams that carry data across the C boundary.
///
/// The two seams are deliberately pure + unit-tested (`TerminalSearchTests`), since everything past
/// them needs a live Metal surface + PTY and so can only be exercised by manual QA:
///   - `TerminalSearchAction.bindingString` — the keybind-action string we hand to
///     `ghostty_surface_binding_action` (app → engine).
///   - `TerminalSearchState.reduce` — folds libghostty's search apprt-action callbacks into the
///     bar's display state (engine → app).
///
/// Flow: ⌘F → `start` → engine emits `START_SEARCH` → bar appears. User types → `setNeedle` →
/// engine searches + highlights, emits `SEARCH_TOTAL` then `SEARCH_SELECTED` → bar shows "3/12".
/// ⌘G / ⇧⌘G → `navigate` → engine re-emits `SEARCH_SELECTED`. Esc → `end` → engine emits
/// `END_SEARCH` → bar hides. The needle is app-owned input (the bar's text field is the source of
/// truth) — verified against Ghostty's `src/Surface.zig`: the surface does not capture keystrokes
/// for the needle, it only reports results back out.

// MARK: - App → engine (pure)

/// A scrollback-search keybind action, mapped to the libghostty action string passed to
/// `ghostty_surface_binding_action`. Pure + engine-free so the action names are unit-tested (a typo
/// here is otherwise only caught at runtime).
enum TerminalSearchAction: Equatable {
  case start
  case setNeedle(String)
  case navigate(Direction)
  case end

  enum Direction: String, Equatable {
    case next
    case previous
  }

  /// The libghostty keybind-action string. `search:<needle>` mirrors Ghostty's colon-argument
  /// syntax (like `goto_tab:3`); an empty needle is the engine's documented "cancel the search"
  /// form, which is exactly what we want when the field is cleared.
  var bindingString: String {
    switch self {
    case .start: return "start_search"
    case .setNeedle(let needle): return "search:\(needle)"
    case .navigate(let direction): return "navigate_search:\(direction.rawValue)"
    case .end: return "end_search"
    }
  }

  /// The `navigate_search` step(s) for one Find-Next / Find-Previous press (⌘G / ⇧⌘G), given the
  /// engine's current `selected` match index and the `total` match count. `selected` is libghostty's
  /// raw **0-based** index, but in the engine's own order it counts **newest→oldest** (index `0` is
  /// the bottom-most match, `total - 1` the top-most); `< 0` means no match is selected. Pure, so the
  /// direction + wrap logic is unit-tested.
  ///
  /// **Direction is inverted from the engine's:** Ghostty's `navigate_search:next` steps newest→oldest
  /// (up the scrollback), which is the opposite of the editor convention users expect from "Find Next"
  /// (the topmost match first, then *downward*). So Find Next emits engine `previous` and Find Previous
  /// emits engine `next`. The bar's 1-based position is `total - selected` (see `matchSummary`), so it
  /// counts up as Find Next walks down the screen.
  ///
  /// **Wrap is synthesized host-side:** libghostty's `navigate_search` does NOT wrap — the bundled
  /// engine stops dead at the ends ("we don't wrap or reset the match currently"). At an end
  /// we step the other way across the remaining (total-1) matches to reach the opposite end. The
  /// engine's search thread drains the whole burst in one mailbox pass and notifies only the *net*
  /// selection once, so it collapses into a single selection + render — no flicker. With no current
  /// selection (`selected < 0`) a single step lets the engine pick an end itself (and it is NOT
  /// mistaken for an end match, so it never wraps).
  static func navigationPlan(findNext: Bool, selected: Int, total: Int) -> [Direction] {
    guard total > 0 else { return [] }
    if findNext {
      // Find Next == engine `previous` (steps toward index 0, the bottom). At index 0 (the last
      // Find-Next position) → wrap to the top (index total-1) via `next` steps.
      if total > 1 && selected == 0 { return Array(repeating: .next, count: total - 1) }
      return [.previous]
    } else {
      // Find Previous == engine `next` (steps toward index total-1, the top). At index total-1 (the
      // last Find-Previous position) → wrap to the bottom (index 0) via `previous` steps.
      if total > 1 && selected == total - 1 { return Array(repeating: .previous, count: total - 1) }
      return [.next]
    }
  }
}

// MARK: - Engine → app (pure)

/// The find bar's display state, folded from libghostty's search apprt-action callbacks. Pure +
/// `Equatable` so the transitions are unit-tested without a live engine. `nil` means "no search".
struct TerminalSearchState: Equatable {
  /// The engine's echo of the active needle (e.g. the selection when search starts from a
  /// selection). The bar's text field — not this — is the user-facing source of truth once typing
  /// begins; this seeds the field on `.start`.
  var needle: String
  /// Total matches in the scrollback, as reported by the engine.
  var total: Int
  /// The engine's **0-based** index of the currently-selected match, in libghostty's own
  /// newest→oldest order (`0` = bottom-most match, `total - 1` = top-most); `-1` when none is
  /// selected. libghostty reports a negative index for "no current match" (e.g. right after typing,
  /// before the first navigate); we normalise any negative to `-1` so it stays distinct from index
  /// `0`. The find bar maps this to a top-down 1-based position via `total - selected` (see
  /// `matchSummary`), and Find Next/Previous are inverted from the engine's (see `navigationPlan`).
  var selected: Int

  /// A libghostty search callback. Mirrors the four `GHOSTTY_ACTION_*SEARCH*` apprt actions.
  enum Event: Equatable {
    case start(needle: String)
    case total(Int)
    case selected(Int)
    case end
  }

  /// Fold one callback into the next state. `START_SEARCH` opens (resetting counts); `END_SEARCH`
  /// closes (→ nil); `SEARCH_TOTAL`/`SEARCH_SELECTED` update counts but are ignored when no search
  /// is open (a stray count before `START_SEARCH` must not crash or conjure a bar).
  static func reduce(_ current: TerminalSearchState?, _ event: Event) -> TerminalSearchState? {
    switch event {
    case .start(let needle):
      return TerminalSearchState(needle: needle, total: 0, selected: -1)
    case .total(let total):
      guard var next = current else { return nil }
      next.total = max(0, total)
      return next
    case .selected(let selected):
      guard var next = current else { return nil }
      // Keep the raw 0-based index; collapse any negative ("no current match") to -1.
      next.selected = selected < 0 ? -1 : selected
      return next
    case .end:
      return nil
    }
  }
}

// MARK: - Observable bridge

/// Bridges a terminal surface and its SwiftUI find bar. The surface feeds engine callbacks in via
/// `apply(_:)` (delegating to the pure `TerminalSearchState.reduce`); the bar two-way-binds `needle`
/// and reads the published counts, and drives actions back out through `perform` — which the surface
/// wires to `ghostty_surface_binding_action`.
///
/// Not `@MainActor`: the surface mutates this only from libghostty's action callbacks, which fire on
/// the main thread (see `GhosttyRuntimeAdapter`), and SwiftUI reads it on the main thread — so the
/// `@Published` writes are already main-thread-confined without the isolation friction of annotating
/// an object the nonisolated runtime callbacks touch.
final class TerminalSearchModel: ObservableObject {
  /// The find field's text — the user-facing source of truth, two-way bound by the bar and pushed to
  /// the engine on change. Seeded from the engine only on `.start`.
  @Published var needle: String = ""
  /// Total matches reported by the engine.
  @Published private(set) var total: Int = 0
  /// Engine 0-based index of the selected match (newest→oldest: `0` = bottom, `total-1` = top);
  /// `-1` = none. The bar shows `total - selected` as a top-down 1-based position.
  @Published private(set) var selected: Int = -1
  /// Whether the find bar is shown.
  @Published private(set) var isActive: Bool = false
  /// Bumped on every `start()` (⌘F). The bar observes it to (re)focus the find field — so ⌘F while
  /// the bar is already open pulls focus back to the field instead of doing nothing.
  @Published private(set) var focusRequest: Int = 0

  /// Set by the owning surface: runs a search keybind action on the live surface. Nil in headless
  /// tests, so the model is exercisable without an engine.
  var perform: ((TerminalSearchAction) -> Void)?

  // MARK: App → engine

  /// Open the find bar (⌘F), or — if it's already open — just pull focus back to the field. Shows
  /// optimistically so the bar is instant even before the engine echoes `START_SEARCH`; the callback
  /// then refines the needle (e.g. a selection). `focusRequest` is always bumped so the bar refocuses
  /// the field; the engine `start_search` is sent only on the first open (re-sending it while a
  /// search is live would needlessly restart the engine's search).
  func start() {
    focusRequest &+= 1
    guard !isActive else { return }
    isActive = true
    perform?(.start)
  }

  /// Push the field's text to the engine. No-op while closed, so the field clearing on `end()`
  /// doesn't fire a stray search after the bar is gone.
  func setNeedle(_ text: String) {
    guard isActive else { return }
    perform?(.setNeedle(text))
  }

  /// Jump to the next / previous match (⌘G / ⇧⌘G), wrapping at the ends. No-op while closed.
  /// The wrap is synthesized as a burst of opposite-direction steps (see `navigationPlan`) because
  /// the engine itself doesn't wrap; the burst coalesces into one selection in the engine.
  func navigate(_ direction: TerminalSearchAction.Direction) {
    guard isActive else { return }
    for step in TerminalSearchAction.navigationPlan(
      findNext: direction == .next, selected: selected, total: total)
    {
      perform?(.navigate(step))
    }
  }

  /// Close the find bar (Esc). Hides immediately rather than waiting for the `END_SEARCH` echo —
  /// the echo reduces to the same closed state, so it's idempotent.
  func end() {
    perform?(.end)
    reset()
  }

  // MARK: Engine → app

  /// Fold a libghostty search callback into the published state via the pure reducer. On `.start`
  /// the field adopts the engine's needle (a selection, or empty); `.total`/`.selected` never touch
  /// the field, so they can't clobber what the user is typing.
  func apply(_ event: TerminalSearchState.Event) {
    let current =
      isActive ? TerminalSearchState(needle: needle, total: total, selected: selected) : nil
    guard let next = TerminalSearchState.reduce(current, event) else {
      reset()
      return
    }
    isActive = true
    total = next.total
    selected = next.selected
    if case .start(let needle) = event { self.needle = needle }
  }

  private func reset() {
    isActive = false
    needle = ""
    total = 0
    selected = -1
  }

  // MARK: Derived (for the bar)

  var hasMatches: Bool { total > 0 }

  /// "3/12", "0/12" (matches found, none selected yet), "No results", or "" while the field is empty.
  /// `selected` is the engine's 0-based index counting newest→oldest, so the user-facing position
  /// (top match = 1, counting down as Find Next advances) is `total - selected`; `-1` (none) shows 0.
  var matchSummary: String {
    if needle.isEmpty { return "" }
    guard total > 0 else { return "No results" }
    return "\(selected < 0 ? 0 : total - selected)/\(total)"
  }
}
