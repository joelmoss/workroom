import AppKit
import Defaults

/// Which of the two quick switchers a keystroke opened (issue #132).
enum QuickSwitcherKind: Equatable {
  /// ⌥Tab — open workrooms, across every window.
  case workrooms
  /// ⌃Tab — the key window's current workroom's panes.
  case panes
}

/// What the key monitor should do with a quick-switcher keystroke aimed at a particular window
/// (issue #132) — see `AppDelegate.switcherGate(for:in:)`, which decides it.
enum SwitcherGate {
  /// Not one of our windows: the key belongs to whatever is focused there.
  case passThrough
  /// One of ours, but with a modal up: eat the key rather than retarget a live dialog's subject.
  case swallow
  /// Go ahead on this store.
  case act(AppStore)
}

/// The modifier a quick switcher is triggered with. Stored as a preference because a global hotkey
/// grabber wins over our local key monitor and there is no way to detect or beat one: AltTab,
/// HyperSwitch and Contexts all bind ⌥Tab by default via a CGEvent tap, which is upstream of
/// `NSApp.sendEvent`, so for those users the keystroke never reaches Workroom at all. Retuning the
/// modifier is the only possible remedy (issue #132). ⌘ combinations that the OS owns (⌘Tab, ⇧⌘Tab)
/// are deliberately not offered.
enum SwitcherModifier: String, CaseIterable, Defaults.Serializable {
  case option
  case control
  case commandOption
  case commandControl

  var flags: NSEvent.ModifierFlags {
    switch self {
    case .option: [.option]
    case .control: [.control]
    case .commandOption: [.command, .option]
    case .commandControl: [.command, .control]
    }
  }

  /// Menu-style glyphs, for the keyboard-shortcuts sheet.
  var display: String {
    switch self {
    case .option: "⌥"
    case .control: "⌃"
    case .commandOption: "⌥⌘"
    case .commandControl: "⌃⌘"
    }
  }
}

/// The keystroke → switcher decision, as a pure function of what an `NSEvent` contributes plus the
/// two configured modifiers (issue #132).
///
/// Deliberately **not** added to `GhosttySurfaceView.isAppShortcut`. That list is a static allowlist,
/// and whether Tab belongs to the app depends on runtime state — a workroom with one pane has nothing
/// to switch to, so ⌃Tab must reach the TUI. The codebase already resolved this same fork the same
/// way: ⌃⌘arrows is deliberately unreserved so it passes through at a split's edge. The `AppDelegate`
/// monitor runs inside `NSApp.sendEvent` *before* key-equivalent dispatch, so when the switcher does
/// act the surface never sees the key regardless.
enum QuickSwitcherKey {
  /// Tab. Matched by keyCode, not characters, so it is layout-stable (and ⇧Tab still reads as Tab).
  static let tabKeyCode: UInt16 = 48

  /// The switcher this keystroke triggers, and whether ⇧ makes it step backwards. `nil` for anything
  /// that isn't Tab with exactly one configured trigger modifier (⇧ aside).
  nonisolated static func classify(
    keyCode: UInt16, flags: NSEvent.ModifierFlags,
    workroomModifier: SwitcherModifier = Defaults[.switcherWorkroomModifier],
    paneModifier: SwitcherModifier = Defaults[.switcherPaneModifier]
  ) -> (kind: QuickSwitcherKind, reverse: Bool)? {
    guard keyCode == tabKeyCode else { return nil }
    let relevant = flags.intersection([.command, .shift, .option, .control])
    let reverse = relevant.contains(.shift)
    let base = relevant.subtracting(.shift)
    guard !base.isEmpty else { return nil }  // bare Tab belongs to the terminal (shell completion)
    // Workrooms win a tie, so a user who sets both modifiers the same still gets a working ⌥Tab
    // rather than an unreachable pane switcher.
    if base == workroomModifier.flags { return (.workrooms, reverse) }
    if base == paneModifier.flags { return (.panes, reverse) }
    return nil
  }
}

/// The quick switcher itself (issue #132), stage 1: every press commits immediately, ordered by
/// most-recent use rather than position.
///
/// ```
///   ⌥Tab      items (MRU):  [ current  prev  older … ]  → commit items[1]
///   ⇧⌥Tab                                               → commit items[count - 1]
/// ```
///
/// Stage 2 adds the held-modifier rail on top of the same item collection, and moves the commit to
/// modifier release.
@MainActor
enum QuickSwitcher {
  /// Act on a switcher keystroke. Returns whether it actually switched — the key monitor consumes the
  /// event only then, so ⌃Tab still reaches a TUI in a workroom that has nothing to switch to.
  @discardableResult
  static func step(
    _ kind: QuickSwitcherKind, reverse: Bool, in store: AppStore,
    registry: WindowRegistry = .shared, recency: SwitcherRecency = .shared
  ) -> Bool {
    switch kind {
    case .workrooms:
      stepWorkrooms(reverse: reverse, in: store, registry: registry, recency: recency)
    case .panes: stepPanes(reverse: reverse, in: store, recency: recency)
    }
  }

  // MARK: Workrooms (⌥Tab, every window)

  /// Every window's open workrooms, MRU-ordered. Windows with a sheet/dialog up are excluded: raising
  /// one and moving its selection would leave its own modal describing a workroom the app is no longer
  /// pointed at — for the commit sheet, that is a wrong-target VCS write.
  static func workroomSlots(
    registry: WindowRegistry = .shared, recency: SwitcherRecency = .shared
  ) -> [WorkroomSlot] {
    let slots = registry.allStores
      .filter { !$0.hasModalPresentation }
      .flatMap { store in
        store.displayedWorkroomTargets().map {
          WorkroomSlot(store: store, sid: $0.sid, target: $0.target)
        }
      }
    return recency.workroomOrder(slots)
  }

  private static func stepWorkrooms(
    reverse: Bool, in store: AppStore, registry: WindowRegistry, recency: SwitcherRecency
  ) -> Bool {
    let slots = workroomSlots(registry: registry, recency: recency)
    guard slots.count > 1 else { return false }
    let current = store.selectedTargetID.flatMap { sid in
      slots.firstIndex { $0.store === store && $0.sid == sid }
    }
    let next = destination(from: current, count: slots.count, reverse: reverse)
    return commit(slots[next], from: store)
  }

  /// Switch to one workroom slot. Shared by the tap-only path above and the held-modifier session's
  /// release commit (T10), so the two can't diverge on the raise-then-select ordering.
  @discardableResult
  static func commit(_ slot: WorkroomSlot, from store: AppStore) -> Bool {
    guard let target = slot.store, target !== store || slot.sid != store.selectedTargetID else {
      return false  // already here: no raise, no selection write, no history entry
    }
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    // Raise first, then select: `AppStore.persistsSidebarPrefs` keys on being `lastActiveStore`, so
    // the registry's didBecomeKey observer must have run before the selection write.
    target.hostWindow?.makeKeyAndOrderFront(nil)
    target.openExisting(slot.sid)
    return true
  }

  // MARK: Panes (⌃Tab, the current workroom)

  /// The selected workroom's panes in MRU order, or `[]` when nothing is selected.
  static func paneTabs(in store: AppStore, recency: SwitcherRecency = .shared) -> [TerminalTab] {
    guard let target = store.selectedTarget, !target.isMissing else { return [] }
    return recency.paneOrder(store.terminals.tabs(for: target))
  }

  private static func stepPanes(
    reverse: Bool, in store: AppStore, recency: SwitcherRecency
  ) -> Bool {
    guard let target = store.selectedTarget, !target.isMissing else { return false }
    let tabs = paneTabs(in: store, recency: recency)
    guard tabs.count > 1 else { return false }
    let activeID = store.terminals.activeTab(for: target)?.id
    let current = activeID.flatMap { id in tabs.firstIndex { $0.id == id } }
    let next = destination(from: current, count: tabs.count, reverse: reverse)
    return commit(pane: tabs[next].id, in: store)
  }

  /// Switch to one pane by id. Shared with the held-modifier session's release commit (T10).
  @discardableResult
  static func commit(pane id: TerminalTab.ID, in store: AppStore) -> Bool {
    guard let target = store.selectedTarget, !target.isMissing else { return false }
    guard store.terminals.activeTab(for: target)?.id != id else { return false }
    guard store.terminals.tabs(for: target).contains(where: { $0.id == id }) else { return false }
    // `select`, not `focus`: it also promotes the owning workroom in a split and takes keyboard focus.
    store.terminals.select(id, for: target)
    return true
  }

  // MARK: Stepping

  /// The item a single press lands on. From the head of an MRU list, forward is "the one before this"
  /// and backward is the least-recently-used — so a tap flips to where you just were, and tapping
  /// again flips back (the commit re-orders MRU). When the current place isn't in the list at all (a
  /// root with no terminals, a window with a modal), enter at the most recent / least recent end.
  nonisolated static func destination(from current: Int?, count: Int, reverse: Bool) -> Int {
    guard let current else { return reverse ? count - 1 : 0 }
    return AppStore.wrapped(index: current, by: reverse ? -1 : 1, count: count)
  }
}
