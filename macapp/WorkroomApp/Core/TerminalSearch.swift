import Combine
import Foundation

/// Scrollback **find** (search) for the embedded terminals. Workroom adds no search engine of its
/// own — libghostty (the bundled engine is upstream Ghostty 1.3.x, which shipped scrollback search)
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
  /// The 1-based index of the currently-selected match (0 when there are none). The base is whatever
  /// libghostty reports; we store it verbatim and clamp negatives ("no selection") to 0.
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
      return TerminalSearchState(needle: needle, total: 0, selected: 0)
    case .total(let total):
      guard var next = current else { return nil }
      next.total = max(0, total)
      return next
    case .selected(let selected):
      guard var next = current else { return nil }
      next.selected = max(0, selected)
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
  /// 1-based index of the selected match (0 = none).
  @Published private(set) var selected: Int = 0
  /// Whether the find bar is shown.
  @Published private(set) var isActive: Bool = false

  /// Set by the owning surface: runs a search keybind action on the live surface. Nil in headless
  /// tests, so the model is exercisable without an engine.
  var perform: ((TerminalSearchAction) -> Void)?

  // MARK: App → engine

  /// Open the find bar (⌘F). Shows optimistically so the bar is instant even before the engine
  /// echoes `START_SEARCH`; the callback then refines the needle (e.g. a selection).
  func start() {
    isActive = true
    perform?(.start)
  }

  /// Push the field's text to the engine. No-op while closed, so the field clearing on `end()`
  /// doesn't fire a stray search after the bar is gone.
  func setNeedle(_ text: String) {
    guard isActive else { return }
    perform?(.setNeedle(text))
  }

  /// Jump to the next / previous match (⌘G / ⇧⌘G). No-op while closed.
  func navigate(_ direction: TerminalSearchAction.Direction) {
    guard isActive else { return }
    perform?(.navigate(direction))
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
    selected = 0
  }

  // MARK: Derived (for the bar)

  var hasMatches: Bool { total > 0 }

  /// "3/12", "No results", or "" while the field is empty.
  var matchSummary: String {
    if needle.isEmpty { return "" }
    return total > 0 ? "\(selected)/\(total)" : "No results"
  }
}
