import AppKit
import SwiftUI

/// Edge-hover reveal for a collapsed sidebar (issue #56, #74). When a sidebar is closed, hovering its
/// title-bar *toggle button* slides the sidebar content IN, OVER the detail (an overlay, not a pushed
/// column — `NavigationSplitView`/`.inspector` only push, with no native macOS overlay mode), and
/// mousing off slides it back out.
///
/// The trigger is the toggle button alone (`AppStore.hovering{Left,Right}Toggle`, set by the title-bar
/// bars). It used to be a wide click-through strip over the toolbar (issue #56), but that strip sat
/// directly above the leftmost workroom tabs — reaching for a tab tripped the reveal, whose panel then
/// covered the very tab you wanted (issue #74). Pinning the trigger to the button keeps it clear of
/// the tabs by construction.
///
/// Two pieces:
/// - `EdgeRevealReducer` — the pure reveal/hide decision logic, unit-tested in isolation (the view is
///   a thin shell over it). No timers, no AppKit, no SwiftUI — just state transitions + effects. Its
///   `setSensorHover` input is now driven by the toggle button's hover rather than a sensor strip.
/// - `EdgeRevealSidebar` — the SwiftUI overlay layer: it always mounts the panel while the sidebar is
///   closed and animates reveal/hide by offset+opacity (so a context menu / sheet / dialog the panel
///   presents is never destroyed mid-flow), drives the debounce, and mirrors the reveal into
///   `AppStore.previewing{Left,Right}` so notification routing + `ToastStack` stay correct.

// MARK: - Reducer

/// Pure decision core for one edge's reveal state. Combined hover (`sensor || panel`) drives it:
/// reveal immediately on enter; hide only after a debounce the *view* owns, and only if still idle
/// when it fires. Kept free of timers/AppKit/SwiftUI so every branch is unit-testable.
struct EdgeRevealReducer: Equatable {
  /// Side effect the view must perform after a transition. The reducer never runs effects itself.
  enum Effect: Equatable {
    case none
    /// Became revealed — view should cancel any pending hide and animate in.
    case reveal
    /// Re-hovered before the pending hide fired — view should cancel the hide.
    case cancelHide
    /// Left while revealed — view should arm the debounce, then call `commitHideIfStillIdle()`.
    case scheduleHide
  }

  private(set) var sensorHover = false
  private(set) var panelHover = false
  private(set) var revealed = false

  /// The panel should be visible while the cursor is over the sensor strip OR the panel itself.
  var wantsVisible: Bool { sensorHover || panelHover }

  mutating func setSensorHover(_ value: Bool) -> Effect {
    sensorHover = value
    return reconcile()
  }

  mutating func setPanelHover(_ value: Bool) -> Effect {
    panelHover = value
    return reconcile()
  }

  private mutating func reconcile() -> Effect {
    if wantsVisible {
      if !revealed {
        revealed = true
        return .reveal
      }
      return .cancelHide
    }
    return revealed ? .scheduleHide : .none
  }

  /// Called by the view when the debounce elapses. Hides only if the cursor is still away — covers the
  /// race where it re-enters as the timer fires. Returns whether the visible state changed.
  @discardableResult
  mutating func commitHideIfStillIdle() -> Bool {
    guard revealed, !wantsVisible else { return false }
    revealed = false
    return true
  }

  /// External disable (the docked sidebar was opened): force fully hidden and clear hover. Returns
  /// whether anything was active (so the view can cancel a pending hide and clear the preview flag).
  @discardableResult
  mutating func disable() -> Bool {
    let wasActive = revealed || sensorHover || panelHover
    sensorHover = false
    panelHover = false
    revealed = false
    return wasActive
  }

  /// Escape / explicit dismiss: hide and drop hover so it doesn't immediately re-reveal. Returns
  /// whether it was revealed.
  @discardableResult
  mutating func dismiss() -> Bool {
    guard revealed else { return false }
    sensorHover = false
    panelHover = false
    revealed = false
    return true
  }
}

// MARK: - Reveal overlay

/// One edge's reveal layer. Drop it on the split view as an `.overlay`; pass `enabled` = the matching
/// sidebar is collapsed, and `content` = the same sidebar view the docked column renders.
struct EdgeRevealSidebar<Content: View>: View {
  enum Side {
    case leading
    case trailing
  }

  let side: Side
  /// The matching docked sidebar is collapsed, so reveal-on-hover is active. When false the layer is
  /// inert (nothing mounted, nothing hit-testable) and any in-flight reveal is reset.
  let enabled: Bool
  /// Panel width — the captured docked width so the reveal matches the user's chosen size.
  let width: CGFloat
  @ViewBuilder var content: () -> Content

  @EnvironmentObject private var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var reducer = EdgeRevealReducer()
  @State private var hideTask: Task<Void, Never>?

  /// Debounce before hiding after the cursor leaves — long enough to cross the button→panel gap (the
  /// lower title-bar between the toggle button and the panel below it) without a flicker, short enough
  /// to feel responsive.
  private let hideDelay: Duration = .milliseconds(180)

  /// The toggle-button hover that drives this edge, read from the store (set by the title-bar bars).
  private var toggleHover: Bool {
    side == .leading ? store.hoveringLeftToggle : store.hoveringRightToggle
  }

  var body: some View {
    ZStack(alignment: stackAlignment) {
      if enabled {
        // The panel respects the toolbar safe area (it starts BELOW the top toolbar, not over it).
        panel
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: stackAlignment)
    // The trigger is the title-bar toggle button alone (issue #74): the matching toggle reports its
    // hover into the store, and we feed that into the reducer. The button sits well clear of the
    // workroom tabs, so reaching for a tab no longer trips the reveal (the old toolbar-wide sensor
    // strip sat directly above the leftmost tabs — issue #56's strip, replaced here). Guarded by
    // `enabled` so a hover that arrives mid-collapse-animation can't reveal a panel that's about to
    // tear down.
    .onChange(of: toggleHover) { _, hovering in
      guard enabled else { return }
      apply { $0.setSensorHover(hovering) }
    }
    .onChange(of: enabled) { _, isEnabled in
      // When the docked sidebar opens, force the reveal hidden so nothing lingers.
      if !isEnabled { reset() }
    }
    .onDisappear {
      hideTask?.cancel()
      hideTask = nil
      // Don't leave a stale preview flag set (which would suppress toasts forever) if the layer goes
      // away while revealed — e.g. the window closing.
      _ = reducer.disable()
      syncPreviewing()
    }
  }

  private var panel: some View {
    content()
      // Breathing room between the card's top edge and the first row — matches the native pinned
      // card's top inset. Only for the leading sidebar (a List); the trailing inspector's first
      // element is a full-width header bar that sits flush.
      .padding(.top, side == .leading ? 10 : 0)
      .frame(width: width)
      .frame(maxHeight: .infinity)
      // The same floating card the docked column uses (`sidebarCard`). `topMargin: 0` extends the card
      // up to sit flush below the toolbar like the native pinned card (the reveal's safe-area top is
      // ~8pt lower than the native card's top), so pinned and unpinned line up.
      // Both docked columns now use the frosted `.sidebar` vibrancy, so both reveals match them
      // (pinned == unpinned). `elevated`: an unpinned panel floats over the content, so it gets a
      // deeper drop shadow than the docked card.
      .sidebarCard(topMargin: 0, vibrant: true, elevated: true)
      .offset(x: panelOffsetX)
      .opacity(reducer.revealed ? 1 : 0)
      // Hidden/off-screen panel must never eat terminal clicks.
      .allowsHitTesting(reducer.revealed)
      .onHover { hovering in
        // Ignore hover while hidden. `.offset` moves only the rendering, so the hidden panel's hover
        // region still occupies the full-height leading column — without this guard hovering anywhere
        // down the left edge would reveal it (issue #56). Once revealed the panel sits at offset 0, so
        // its hover region matches what's on screen and keeping it open / hiding on exit works.
        guard reducer.revealed else { return }
        apply { $0.setPanelHover(hovering) }
      }
      .onExitCommand { dismiss() }
      // Surface the panel as one addressable accessibility container so it's queryable (by the reveal
      // UI test) while keeping its children reachable; without `.contain` the identifier on this
      // List-wrapping container doesn't surface as an XCUIElement.
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(
        side == .leading ? "sidebar.reveal.leading" : "sidebar.reveal.trailing"
      )
      .accessibilityHidden(!reducer.revealed)
  }

  private var stackAlignment: Alignment { side == .leading ? .leading : .trailing }

  /// Slide the panel fully off the matching edge when hidden (width + card margin + shadow clearance).
  private var panelOffsetX: CGFloat {
    guard !reducer.revealed else { return 0 }
    let hidden = width + 40
    return side == .leading ? -hidden : hidden
  }

  // MARK: Transitions

  /// Apply a reducer mutation inside an animation, then run its effect and mirror the visible state.
  private func apply(_ mutate: (inout EdgeRevealReducer) -> EdgeRevealReducer.Effect) {
    var effect: EdgeRevealReducer.Effect = .none
    withAnimation(revealAnimation) { effect = mutate(&reducer) }
    switch effect {
    case .reveal, .cancelHide:
      hideTask?.cancel()
      hideTask = nil
    case .scheduleHide:
      armHide()
    case .none:
      break
    }
    syncPreviewing()
  }

  private func armHide() {
    hideTask?.cancel()
    hideTask = Task { @MainActor in
      try? await Task.sleep(for: hideDelay)
      if Task.isCancelled { return }
      withAnimation(revealAnimation) { _ = reducer.commitHideIfStillIdle() }
      syncPreviewing()
    }
  }

  private func dismiss() {
    hideTask?.cancel()
    hideTask = nil
    withAnimation(revealAnimation) { _ = reducer.dismiss() }
    syncPreviewing()
  }

  private func reset() {
    hideTask?.cancel()
    hideTask = nil
    withAnimation(revealAnimation) { _ = reducer.disable() }
    // Drop any lingering toggle-hover so the next collapse starts from a known-clear baseline (the
    // button stops reporting once its sidebar is pinned, so it can't clear this itself).
    switch side {
    case .leading: store.hoveringLeftToggle = false
    case .trailing: store.hoveringRightToggle = false
    }
    syncPreviewing()
  }

  /// Mirror the reveal into the store so notification routing flashes (not toasts) and `ToastStack`
  /// withholds while this panel is on screen (issue #56 — the flash/toast invariant).
  private func syncPreviewing() {
    switch side {
    case .leading: store.previewingLeft = reducer.revealed
    case .trailing: store.previewingRight = reducer.revealed
    }
  }

  private var revealAnimation: Animation? {
    reduceMotion ? nil : .easeInOut(duration: 0.18)
  }
}

// MARK: - Both-edges modifier

/// Adds the left Projects edge-hover reveal overlay (issue #56) to the split view — active while
/// `sidebarVisible` is false, at the captured docked width. (The right inspector had a matching
/// trailing reveal, dropped when the always-visible activity bar took over the right edge: the bar
/// occupies the hover trigger zone and clicking a section icon is the reveal now.) Packaged as a
/// `ViewModifier` so `RootView`'s already large `body` stays within the Swift type-checker's budget.
struct EdgeRevealSidebars: ViewModifier {
  @EnvironmentObject private var store: AppStore
  let sidebarVisible: Bool
  /// Drag-to-split plumbing for the revealed Projects panel (issue #101) — same as the docked
  /// `SidebarColumn`'s, so dragging a row out of the slide-over forms a split too. Unlike the docked
  /// column (left of the detail) and the tab bar (above it), the reveal panel floats OVER the detail,
  /// so the drag is gated to ignore points still over the panel (see `body`) — otherwise a drop would
  /// register immediately, with no "release over the panel to cancel" zone the other two paths get.
  var paneDrag: Binding<WorkroomPaneDrag?> = .constant(nil)
  var localize: (CGPoint) -> CGPoint? = { _ in nil }
  var dropTarget: (CGPoint) -> (sid: SidebarID, edge: PaneEdge)? = { _ in nil }

  func body(content: Content) -> some View {
    // The revealed leading panel sits at offset 0 occupying detail-local x `[margin, margin+width]`
    // (`sidebarCard`'s default 8pt leading inset). `localize` already hands back a detail-local point,
    // so "cursor still over the panel card" is pure arithmetic — suppress the drag plumbing there so a
    // reveal-row drag only resolves once it crosses the card's right edge onto a pane (issue #101).
    // `panelWidth` is bound once and used for BOTH the panel's width and the gate so they can't drift.
    let panelWidth = store.dockedSidebarWidth ?? 260
    // sidebarCard's default `margin`; track it if the leading overlay ever passes a `leadingMargin`.
    let cardLeadingMargin: CGFloat = 8
    func overPanel(_ global: CGPoint) -> Bool {
      (localize(global)?.x ?? .infinity) < panelWidth + cardLeadingMargin
    }
    return
      content
      .overlay {
        EdgeRevealSidebar(
          side: .leading, enabled: !sidebarVisible, width: panelWidth
        ) {
          ProjectSidebar(
            paneDrag: paneDrag,
            localize: { overPanel($0) ? nil : localize($0) },
            dropTarget: { overPanel($0) ? nil : dropTarget($0) }
          )
        }
      }
  }
}
