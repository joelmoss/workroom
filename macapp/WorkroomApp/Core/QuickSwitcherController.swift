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
  var onCursorMoved: ((Int) -> Void)?
  var onEnd: (() -> Void)?

  // MARK: State

  private(set) var reducer = QuickSwitcherReducer()
  private(set) var items: [Item] = []
  /// The window the gesture started in — the commit's "am I already here" reference.
  private weak var originStore: AppStore?
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
      let switched = QuickSwitcher.step(
        kind, reverse: reverse, in: store, registry: registry, recency: recency)
      if switched, let spoken = Self.announcement(for: kind, in: store) { announce(spoken) }
      return switched
    }

    if isLive {
      apply(reducer.handle(.step(reverse: reverse)))
      return true
    }

    let frozen = Self.collect(kind, in: store, registry: registry, recency: recency)
    let effect = reducer.handle(.open(kind: kind, count: frozen.count, reverse: reverse))
    // Under 2 items there is nothing to switch to, so the key passes through to the terminal.
    guard effect != .none else { return false }
    items = frozen
    originStore = store
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

  /// ←/→ while the rail is up. Returns whether it was consumed.
  @discardableResult
  func handleArrow(reverse: Bool) -> Bool {
    guard isLive else { return false }
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

  /// A window closed (or its workroom went away): drop dead candidates and tell the reducer the new
  /// count, which clamps the cursor or ends the session.
  func reconcileItems() {
    guard isLive else { return }
    items = items.filter(isAlive)
    apply(reducer.handle(.itemsChanged(count: items.count)))
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
      teardown()
      onEnd?()
      if let chosen, let store { Self.perform(chosen, from: store) }
    }
  }

  private func teardown() {
    items = []
    originStore = nil
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
    let poll = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
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
      guard let store = originStore, let target = store.selectedTarget else { return false }
      return store.terminals.tabs(for: target).contains { $0.id == tab.id }
    }
  }

  private static func perform(_ item: Item, from store: AppStore) {
    switch item {
    case .workroom(let slot): QuickSwitcher.commit(slot, from: store)
    case .pane(let tab): QuickSwitcher.commit(pane: tab.id, in: store)
    }
  }

  /// What the VoiceOver path speaks after a tap flip: where it actually landed.
  private static func announcement(for kind: QuickSwitcherKind, in store: AppStore) -> String? {
    switch kind {
    case .workrooms:
      guard let sid = store.selectedTargetID else { return nil }
      return store.label(for: sid).full
    case .panes:
      guard let target = store.selectedTarget else { return nil }
      return store.terminals.activeTab(for: target)?.title
    }
  }
}
