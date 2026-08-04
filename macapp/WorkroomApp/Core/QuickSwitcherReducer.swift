import Foundation

/// Pure decision core for one quick-switcher session (issue #132, stage 2). Modelled on
/// `EdgeRevealReducer`: no timers, no AppKit, no SwiftUI — the controller owns the reveal timer, the
/// modifier poll and the panel, and performs whatever `Effect` comes back.
///
/// ```
///                     ┌──────────────────── cancel(escape|deactivated|empty|timeout) ──────┐
///                     │                                                                    ▼
///    idle ──open(count>1)──▶ pending ──revealTimerFired(250ms)──▶ revealed ──released──▶ idle
///     ▲  │                     │  │                                 │  ▲                  │
///     │  └─open(count<=1)─▶ idle  └──step──▶ revealed (immediate)    │  └─point/step (±)   │
///     │                                                             └────commit(index) ────┘
///     └──────────── every event while .idle is a no-op ◀── (click commit, then release)
/// ```
///
/// Four rules carry the weight, each with a test:
/// - **`.idle` swallows everything.** A mouse click commits and goes idle; the modifier release that
///   inevitably follows must not commit a second time.
/// - **`step` while `.pending` reveals immediately** — ⌥Tab⌥Tab means "show me the rail now".
/// - **`revealTimerFired` outside `.pending` is a no-op**, so a timer that fires after a fast release
///   can't resurrect a finished session.
/// - **`itemsChanged(0)` ends without committing**; `> 0` clamps the cursor rather than dangling past
///   the end.
///
/// Not modelled here: the VoiceOver path (D16). With VoiceOver running the controller never opens a
/// session at all — it commits through the stage-1 `QuickSwitcher.step` and announces — so there is no
/// unfocusable panel to narrate and no announcement queue to land after the commit.
struct QuickSwitcherReducer: Equatable {

  enum Phase: Equatable {
    case idle
    /// Modifier still held, cursor has moved, panel not shown yet. A release here is the tap-flip.
    case pending
    /// The rail is on screen.
    case revealed
  }

  enum Cancel: Equatable {
    /// Escape pressed.
    case escape
    /// The app lost active state (⌘Tab away, another app clicked).
    case deactivated
    /// Every item went away.
    case empty
    /// The hard ceiling — a stuck modifier must not leave the rail up forever.
    case timeout
  }

  enum Event: Equatable {
    /// A trigger keypress with no session live. `count` is the frozen item count.
    case open(kind: QuickSwitcherKind, count: Int, reverse: Bool)
    /// Another trigger press, or ←/→.
    case step(reverse: Bool)
    /// The pointer moved onto a card. Ignored until `armHover` (D17).
    case point(index: Int)
    /// Real pointer movement seen since the reveal — hover may now steer the cursor (D17).
    case armHover
    case revealTimerFired
    /// A click on a card. `nil` means "commit whatever the cursor is on".
    case commit(index: Int?)
    case modifierReleased
    case cancel(Cancel)
    /// The item list changed under us (a window closed, a pane died). `cursor` is where the caller
    /// wants the cursor now — it must be recomputed from the *item* the cursor was tracking, because
    /// removing an earlier item shifts every later index down by one. Clamping alone silently moves the
    /// selection to a neighbour, which the release then commits.
    case itemsChanged(count: Int, cursor: Int)
  }

  enum Effect: Equatable {
    case none
    /// Start the reveal timer. The panel stays hidden — a quick tap must not flash it.
    case armReveal
    /// Show the panel (and render the current cursor).
    case reveal
    /// The cursor moved while already revealed — scroll it into view.
    case moveCursor(Int)
    /// Session over. `commit` is the index to switch to, or nil to leave the selection alone.
    case end(commit: Int?)
  }

  /// How long the modifier must stay held before the rail appears. 250 ms, not 180: at 180 a chorded
  /// tap flashes the panel. (The 180 ms in `EdgeRevealSidebar` is a *hide* debounce, not a reveal
  /// delay — reading it as precedent was a misread.)
  static let revealDelay: Duration = .milliseconds(250)

  /// The ceiling on one session, so a modifier the poll never sees released can't strand the rail.
  static let sessionCeiling: Duration = .seconds(10)

  private(set) var phase: Phase = .idle
  private(set) var kind: QuickSwitcherKind = .workrooms
  private(set) var count = 0
  private(set) var cursor = 0
  /// False from `open` until `armHover`: the panel is centred, so it can appear *under* a stationary
  /// pointer, and an unarmed `.onHover` would move the selection to whatever card landed there —
  /// release would then commit a destination the user never chose (D17).
  private(set) var hoverArmed = false

  var isRevealed: Bool { phase == .revealed }
  var isLive: Bool { phase != .idle }

  mutating func handle(_ event: Event) -> Effect {
    switch event {
    case .open(let kind, let count, let reverse):
      // Not a fresh session: an `open` arriving mid-session is another step (holding ⌥ and tapping Tab
      // again re-enters through the same monitor branch).
      if phase != .idle { return handle(.step(reverse: reverse)) }
      // Nothing to switch to — the monitor passes the key through instead, so ⌃Tab still reaches a TUI.
      guard count > 1 else { return .none }
      self.kind = kind
      self.count = count
      cursor = Self.destination(from: 0, count: count, reverse: reverse)
      hoverArmed = false
      phase = .pending
      return .armReveal

    case .step(let reverse):
      guard phase != .idle else { return .none }
      cursor = Self.destination(from: cursor, count: count, reverse: reverse)
      // A second trigger press while still pending means the user wants to see the choices now,
      // without waiting out the rest of the reveal delay.
      if phase == .pending {
        phase = .revealed
        return .reveal
      }
      return .moveCursor(cursor)

    case .point(let index):
      guard phase == .revealed, hoverArmed, index != cursor, count > 0 else { return .none }
      guard (0..<count).contains(index) else { return .none }
      cursor = index
      return .moveCursor(cursor)

    case .armHover:
      guard phase != .idle else { return .none }
      hoverArmed = true
      return .none

    case .revealTimerFired:
      // A stale timer from a session that already ended (or one already revealed by a step).
      guard phase == .pending else { return .none }
      phase = .revealed
      return .reveal

    case .commit(let index):
      guard phase != .idle else { return .none }
      let target = index ?? cursor
      // Range-check BEFORE `end()` — it resets `count`, so validating after it rejects every index.
      let valid = (0..<count).contains(target)
      end()
      return .end(commit: valid ? target : nil)

    case .modifierReleased:
      // Already committed by a click — this is the release that follows it, and must do nothing.
      guard phase != .idle else { return .none }
      let target = cursor
      end()
      return .end(commit: target)

    case .cancel:
      guard phase != .idle else { return .none }
      end()
      return .end(commit: nil)

    case .itemsChanged(let newCount, let newCursor):
      guard phase != .idle else { return .none }
      guard newCount > 0 else {
        end()
        return .end(commit: nil)
      }
      count = newCount
      let clamped = min(max(newCursor, 0), newCount - 1)
      guard clamped != cursor else { return .none }
      cursor = clamped
      return phase == .revealed ? .moveCursor(cursor) : .none
    }
  }

  private mutating func end() {
    phase = .idle
    count = 0
    cursor = 0
    hoverArmed = false
  }

  /// One step through the MRU list, wrapping — the SAME function stage 1's tap-only path already
  /// steps with (which in turn shares `AppStore.wrapped` with both tab cyclers, T6). Reused rather
  /// than reimplemented so a held-modifier step and a tapped step can never disagree.
  private static func destination(from current: Int, count: Int, reverse: Bool) -> Int {
    QuickSwitcher.destination(from: current, count: count, reverse: reverse)
  }
}
