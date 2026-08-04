import AppKit
import Defaults

/// Hosts one `QuickSwitcherReducer` session and connects it to the world (issue #132, T10): it freezes
/// the item list at open, arms the reveal, polls the trigger modifier, watches for the ways a session
/// can die, and performs the commit. The reducer decides; this only executes.
///
/// The panel is deliberately **not** owned here. `onReveal` / `onCursorMoved` / `onEnd` are the seam
/// T11 hangs the rail on, which keeps this whole class testable with no window on screen.
@MainActor
final class QuickSwitcherController {
  static let shared = QuickSwitcherController()

  /// One frozen candidate. Frozen at open so the list can't reshuffle under the cursor mid-gesture —
  /// MRU order changes the instant anything is selected, which is exactly what a commit does.
  enum Item {
    case workroom(WorkroomSlot)
    case pane(TerminalTab)
  }

  // MARK: Injected seams (production defaults; tests replace)

  /// The live hardware modifier snapshot. A *global* read on purpose: it stays true through menu
  /// tracking, Mission Control and another app holding focus, all of which starve a local
  /// `flagsChanged` monitor. Masked to the device-independent bits — the raw value carries
  /// left/right-key and numeric-pad bits that never match a configured trigger.
  var flagsProvider: () -> NSEvent.ModifierFlags = {
    NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
  }

  /// D16: with VoiceOver running the switcher never opens a session — see `handleTrigger`.
  var voiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }

  /// Where the pointer is. Read at reveal *and* at each hover so D17's threshold compares two values
  /// from the same source — a test that injected only the hover position would be measuring against
  /// the real mouse, wherever the machine's cursor happens to sit.
  var pointerProvider: () -> NSPoint = { NSEvent.mouseLocation }

  /// Speaks a destination on the VoiceOver path. Replaced in tests to assert what was announced.
  var announce: (String) -> Void = { message in
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }

  /// Starts the two production timers. Injected so tests can drive `revealTimerFired` / `poll`
  /// directly instead of waiting out real time.
  var startTimers: (QuickSwitcherController) -> Void = { controller in
    controller.installRealTimers()
  }
  var stopTimers: () -> Void = {}

  // MARK: Rail seam (T11)

  var onReveal: (([Item], Int) -> Void)?
  /// The item list changed mid-session and the rail must be re-rendered from it. Separate from
  /// `onCursorMoved`, which moves the highlight only: the rail is handed a frozen array at reveal, so
  /// without this the cards on screen and the array a commit indexes into drift apart.
  var onItemsChanged: (([Item], Int) -> Void)?
  var onCursorMoved: ((Int) -> Void)?
  var onEnd: (() -> Void)?

  // MARK: State

  private(set) var reducer = QuickSwitcherReducer()
  private(set) var items: [Item] = []
  /// The window the gesture started in — the commit's "am I already here" reference.
  private weak var originStore: AppStore?
  /// For a `.panes` session, the workroom whose panes are on the rail, frozen at open. Resolving it
  /// live off `originStore.selectedTarget` instead let a sidebar click (or a project reload) mid-gesture
  /// either kill every item or, worse, commit a pane into whatever workroom is selected *now*.
  private var paneTargetID: SidebarID?
  /// The modifier that must stay held. Released ⇒ commit.
  private var triggerFlags: NSEvent.ModifierFlags = []
  private var observers: [NSObjectProtocol] = []
  private var pollTimer: Timer?
  private var revealTimer: Timer?
  private var ceilingTimer: Timer?
  /// Pointer position at reveal, for D17's movement threshold.
  private var pointerAtReveal: NSPoint?

  var isLive: Bool { reducer.isLive }
  var isRevealed: Bool { reducer.isRevealed }

  /// How far the pointer must actually travel before hover may steer the cursor (D17).
  static let hoverArmDistance: CGFloat = 4

  /// How often the trigger modifier is sampled. Named alongside the reducer's `revealDelay` and
  /// `sessionCeiling` rather than left inline: it is the gesture's release latency, so it belongs with
  /// the other two numbers that define how the hold feels.
  static let pollInterval: TimeInterval = 0.03

  // MARK: Entry

  /// The key monitor's entry point. Returns whether the event was consumed.
  @discardableResult
  func handleTrigger(
    _ kind: QuickSwitcherKind, reverse: Bool, in store: AppStore,
    registry: WindowRegistry = .shared, recency: SwitcherRecency = .shared
  ) -> Bool {
    // D16 — VoiceOver: no session, no panel. ⌃⌥ is VoiceOver's own modifier pair, a panel that can't
    // become key can never hold VoiceOver focus however well it narrates, and a fast Tab-Tab-Tab would
    // queue announcements that land *after* the commit. So this degrades to the stage-1 tap flip, which
    // is a complete interaction on its own, and says where it landed.
    if voiceOverEnabled() {
      // VoiceOver can come on *mid-session* (or the rail can already be up when it does). Without this
      // the live session keeps its timers and its rail, the tap below commits immediately, and the
      // modifier release then commits a SECOND time off the frozen list.
      if isLive { cancel(.escape) }
      let outcome = QuickSwitcher.stepDescribing(
        kind, reverse: reverse, in: store, registry: registry, recency: recency)
      // Spoken from what the commit actually wrote, not from the origin store: a cross-window switch
      // leaves the origin's own selection untouched, so reading it back announced the workroom the user
      // just left — on the one path where the announcement *is* the entire UI.
      if let spoken = outcome.spoken { announce(spoken) }
      return outcome.switched
    }

    if isLive {
      // A live session owns only its own kind and its own window. Dropping both (as this did) meant a
      // ⌃Tab landing inside the 30 ms poll window after ⌥ came up would step the *workroom* rail, eat
      // the key so the pane switch never happened, and then commit a workroom nobody asked for. Start
      // over instead: cancel and re-open for what was actually pressed.
      if kind == reducer.kind, store === originStore {
        apply(reducer.handle(.step(reverse: reverse)))
        return true
      }
      cancel(.escape)
    }

    let frozen = Self.collect(kind, in: store, registry: registry, recency: recency)
    let effect = reducer.handle(.open(kind: kind, count: frozen.count, reverse: reverse))
    // Under 2 items there is nothing to switch to, so the key passes through to the terminal.
    guard effect != .none else { return false }
    items = frozen
    originStore = store
    paneTargetID = kind == .panes ? store.selectedTargetID : nil
    triggerFlags =
      (kind == .workrooms
      ? Defaults[.switcherWorkroomModifier] : Defaults[.switcherPaneModifier]).flags
    installObservers()
    startTimers(self)
    apply(effect)
    // A held modifier is not drivable by synthetic input (see `switcherRevealsImmediately`), so under
    // the fixture flag skip straight to the revealed state.
    if UITestFixture.switcherRevealsImmediately { revealTimerFired() }
    return true
  }

  /// Escape while a session is live.
  @discardableResult
  func handleEscape() -> Bool {
    guard isLive else { return false }
    cancel(.escape)
    return true
  }

  /// ←/→ while the rail is **up**, carrying nothing but the trigger modifier. Returns whether it was
  /// consumed.
  ///
  /// Both guards are load-bearing, and the branch that calls this used to have neither. `isRevealed`
  /// rather than `isLive`: during the 250 ms pending phase there is nothing on screen to steer, so
  /// eating an arrow there both swallowed the keystroke and popped the rail. And extra modifiers must
  /// disqualify it, or a live session steals ⌥⌘←/→ (terminal tabs), ⇧⌥⌘←/→ (workroom tabs) and
  /// ⌃⌘arrows (pane focus) — every one of which the user is already holding the trigger for.
  @discardableResult
  func handleArrow(reverse: Bool, flags: NSEvent.ModifierFlags = []) -> Bool {
    guard isRevealed, flags.subtracting(triggerFlags).isEmpty else { return false }
    apply(reducer.handle(.step(reverse: reverse)))
    return true
  }

  /// A card was hovered. Ignored until the pointer has actually moved (D17) — the reducer holds that
  /// rule; this only reports the movement.
  func point(index: Int, pointer: NSPoint? = nil) {
    guard isLive else { return }
    let location = pointer ?? pointerProvider()
    if let origin = pointerAtReveal,
      hypot(location.x - origin.x, location.y - origin.y) > Self.hoverArmDistance
    {
      pointerAtReveal = nil
      apply(reducer.handle(.armHover))
    }
    apply(reducer.handle(.point(index: index)))
  }

  /// A card was clicked. Commits immediately; the modifier release that follows is swallowed.
  func clickCommit(index: Int) {
    guard isLive else { return }
    apply(reducer.handle(.commit(index: index)))
  }

  func cancel(_ reason: QuickSwitcherReducer.Cancel) {
    guard isLive else { return }
    apply(reducer.handle(.cancel(reason)))
  }

  // MARK: Timer / poll inputs (called by the real timers, or directly by tests)

  func revealTimerFired() {
    apply(reducer.handle(.revealTimerFired))
  }

  /// One 30 ms tick. The only thing that ends a held session normally.
  func poll() {
    guard isLive else { return }
    // Under the reveal fixture flag the "hold" is a synthetic tap, so the modifier is already up by
    // the time the first tick lands and the rail would vanish before anything could look at it. The
    // session then ends on Escape or a click, which is what those tests drive.
    guard !UITestFixture.switcherRevealsImmediately else { return }
    guard !flagsProvider().contains(triggerFlags) else { return }
    apply(reducer.handle(.modifierReleased))
  }

  /// A window closed, a pane died, or a sheet went up: drop dead candidates, keep the cursor on the
  /// **item** it was tracking, and re-render the rail from the surviving list.
  ///
  /// Every part of that matters. `filter` compacts the array, so removing anything before the cursor
  /// shifts every later item down one — remapping by identity is what stops the release committing the
  /// card's neighbour. And the rail was handed a frozen array at reveal, so it has to be re-pushed or
  /// the cards on screen no longer line up with the array a click indexes into (a visible card then
  /// either switches to the wrong place or silently does nothing).
  func reconcileItems() {
    guard isLive else { return }
    let tracked = items.indices.contains(reducer.cursor) ? items[reducer.cursor] : nil
    let survivors = items.filter(isAlive)
    guard survivors.count != items.count else { return }  // nothing died; leave the rail alone
    items = survivors
    let remapped = tracked.flatMap { item in items.firstIndex { Self.sameItem($0, item) } }
    apply(reducer.handle(.itemsChanged(count: items.count, cursor: remapped ?? reducer.cursor)))
    if reducer.isRevealed { onItemsChanged?(items, reducer.cursor) }
  }

  /// Identity, not index — the two things `reconcileItems` has to line up.
  private static func sameItem(_ lhs: Item, _ rhs: Item) -> Bool {
    switch (lhs, rhs) {
    case (.workroom(let a), .workroom(let b)): a.id == b.id && a.id != nil
    case (.pane(let a), .pane(let b)): a.id == b.id
    default: false
    }
  }

  // MARK: Effects

  private func apply(_ effect: QuickSwitcherReducer.Effect) {
    switch effect {
    case .none:
      break
    case .armReveal:
      break  // the timers were installed by `handleTrigger`; nothing to show yet
    case .reveal:
      // Record where the pointer already is, so a panel appearing under a stationary cursor can't
      // steer the selection (D17).
      pointerAtReveal = pointerProvider()
      onReveal?(items, reducer.cursor)
    case .moveCursor(let index):
      if reducer.isRevealed { onCursorMoved?(index) }
    case .end(let commit):
      let chosen = commit.flatMap { items.indices.contains($0) ? items[$0] : nil }
      let store = originStore
      let target = store.flatMap(frozenPaneTarget(in:))
      teardown()
      onEnd?()
      // `target` was read before `teardown()` cleared it.
      if let chosen, let store { Self.perform(chosen, from: store, target: target) }
    }
  }

  private func teardown() {
    items = []
    originStore = nil
    paneTargetID = nil
    triggerFlags = []
    pointerAtReveal = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    for timer in [pollTimer, revealTimer, ceilingTimer] { timer?.invalidate() }
    pollTimer = nil
    revealTimer = nil
    ceilingTimer = nil
    stopTimers()
  }

  // MARK: Observers

  private func installObservers() {
    let center = NotificationCenter.default
    observers = [
      // Left the app entirely (⌘Tab away, clicked another app) — don't commit somewhere they can't see.
      center.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.cancel(.deactivated) }
      },
      center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
        [weak self] _ in
        // Deferred: the window is still in `allStores` *during* willClose, so a same-tick re-resolve
        // would keep counting the one that's going away.
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.reconcileItems() } }
      },
    ]
  }

  /// The production timers. `.common` run-loop mode is load-bearing: the default mode does not run
  /// during menu tracking or a modal loop, so a `.default`-mode poll would stall exactly in the cases
  /// the hardware-snapshot approach exists to survive, and the rail would hang until the mode exited.
  fileprivate func installRealTimers() {
    let reveal = Timer(
      timeInterval: Self.seconds(QuickSwitcherReducer.revealDelay), repeats: false
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.revealTimerFired() }
    }
    let poll = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    let ceiling = Timer(
      timeInterval: Self.seconds(QuickSwitcherReducer.sessionCeiling), repeats: false
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.cancel(.timeout) }
    }
    for timer in [reveal, poll, ceiling] { RunLoop.main.add(timer, forMode: .common) }
    revealTimer = reveal
    pollTimer = poll
    ceilingTimer = ceiling
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    let parts = duration.components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }

  // MARK: Items

  static func collect(
    _ kind: QuickSwitcherKind, in store: AppStore, registry: WindowRegistry = .shared,
    recency: SwitcherRecency = .shared
  ) -> [Item] {
    switch kind {
    case .workrooms:
      return QuickSwitcher.workroomSlots(registry: registry, recency: recency).map(Item.workroom)
    case .panes:
      return QuickSwitcher.paneTabs(in: store, recency: recency).map(Item.pane)
    }
  }

  /// Still switchable? A slot whose window has gone (or has raised a sheet since) is dead; a pane is
  /// checked against its origin window's live tab list. An instance method, not a static: a pane's
  /// liveness is only answerable against *this* session's origin store.
  private func isAlive(_ item: Item) -> Bool {
    switch item {
    case .workroom(let slot):
      guard let store = slot.store, !store.hasModalPresentation else { return false }
      return store.displayedWorkroomTargets().contains { $0.sid == slot.sid }
    case .pane(let tab):
      guard let store = originStore, let target = frozenPaneTarget(in: store) else { return false }
      return store.terminals.tabs(for: target).contains { $0.id == tab.id }
    }
  }

  /// The `.panes` session's workroom, resolved from the id frozen at open.
  private func frozenPaneTarget(in store: AppStore) -> TerminalTarget? {
    guard let sid = paneTargetID, let target = store.target(for: sid), !target.isMissing else {
      return nil
    }
    return target
  }

  /// `target` is the session's frozen workroom, needed only by a pane commit.
  private static func perform(_ item: Item, from store: AppStore, target: TerminalTarget?) {
    switch item {
    case .workroom(let slot): QuickSwitcher.commit(slot, from: store)
    case .pane(let tab):
      guard let target else { return }
      QuickSwitcher.commit(pane: tab.id, in: store, target: target)
    }
  }
}
