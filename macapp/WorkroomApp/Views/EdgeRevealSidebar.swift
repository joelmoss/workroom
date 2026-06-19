import AppKit
import SwiftUI

/// Edge-hover reveal for a collapsed sidebar (issue #56). When a sidebar is closed, mousing to its
/// window edge slides the sidebar content IN, OVER the detail (an overlay, not a pushed column —
/// `NavigationSplitView`/`.inspector` only push, with no native macOS overlay mode), and mousing off
/// slides it back out.
///
/// Three pieces:
/// - `EdgeRevealReducer` — the pure reveal/hide decision logic, unit-tested in isolation (the view is
///   a thin shell over it). No timers, no AppKit, no SwiftUI — just state transitions + effects.
/// - `EdgeHoverSensor` — a click-through `NSView` strip (placed over the top toolbar) that reports
///   cursor enter/exit via an `NSTrackingArea` without intercepting clicks (so the toolbar buttons,
///   window controls, and the tabs below keep working). It sits over the toolbar rather than the full
///   window edge so it never covers the workroom/terminal tabs as the cursor reaches them (issue #56).
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

// MARK: - Hover sensor

/// A click-through strip that reports cursor enter/exit (placed over the top toolbar by
/// `EdgeRevealSidebar`). It overrides
/// `hitTest` to return nil (so clicks/drags/selection pass straight through to the terminal beneath,
/// like `ScrollbarThumbView`) while an `NSTrackingArea` still delivers enter/exit (like
/// `GoToBottomButton`). The two behaviours are independent: `hitTest` routes button events; tracking
/// areas are driven by the window's mouse tracking against the registered rect.
struct EdgeHoverSensor: NSViewRepresentable {
  var onHoverChange: (Bool) -> Void

  func makeNSView(context: Context) -> SensorView {
    let view = SensorView()
    view.onHoverChange = onHoverChange
    return view
  }

  func updateNSView(_ nsView: SensorView, context: Context) {
    nsView.onHoverChange = onHoverChange
  }

  final class SensorView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Click-through: never intercept mouse events meant for the content beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Rebuild against the live bounds on every geometry change (window resize, full-screen) — a
    // tracking area cached against stale bounds would stop firing at the (moved) edge.
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self)
      addTrackingArea(area)
      tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
      onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
      onHoverChange?(false)
    }
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

  /// Off-screen clearance added to the hidden panel's slide so its shadow fully clears the edge.
  private let sensorWidth: CGFloat = 6
  /// The trigger zone: a strip over the top toolbar/titlebar (issue #56 feedback), not the full window
  /// edge. Height ≈ the unified titlebar+toolbar; width is a generous, easy-to-hit leading/trailing
  /// portion of the toolbar.
  private let topSensorHeight: CGFloat = 52
  private let topSensorWidth: CGFloat = 180
  /// Debounce before hiding after the cursor leaves — long enough to cross the sensor→panel seam
  /// without a flicker, short enough to feel responsive.
  private let hideDelay: Duration = .milliseconds(180)

  var body: some View {
    ZStack(alignment: stackAlignment) {
      if enabled {
        // The panel respects the toolbar safe area (it starts BELOW the top toolbar, not over it).
        // The sensor is kept in a SEPARATE overlay below — its `ignoresSafeArea` must not drag the
        // panel's stack up into the titlebar (issue #56).
        panel
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: stackAlignment)
    // The trigger is confined to the top toolbar strip (issue #56 feedback), not the full-height
    // window edge — a full-height edge sensor covered the workroom/terminal tabs at the top of the
    // detail, revealing the panel before the cursor could reach them. It reaches up into the
    // (transparent) titlebar via `ignoresSafeArea` and stays click-through, so the toolbar buttons and
    // window controls beneath it keep working. Hosted in its own overlay so that `ignoresSafeArea`
    // affects only the sensor, leaving the panel below the toolbar.
    .overlay(alignment: side == .leading ? .topLeading : .topTrailing) {
      if enabled {
        EdgeHoverSensor { hovering in apply { $0.setSensorHover(hovering) } }
          .frame(width: topSensorWidth, height: topSensorHeight)
          .ignoresSafeArea(.container, edges: .top)
      }
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
      .sidebarCard(topMargin: 0)
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

/// Adds both edge-hover reveal overlays (issue #56) to the split view: the left Projects panel (active
/// while `sidebarVisible` is false) and the right inspector panel (active while `inspectorVisible` is
/// false), each at the captured docked width. Packaged as a `ViewModifier` so `RootView`'s already
/// large `body` stays within the Swift type-checker's budget (adding the two overlays inline tipped it
/// past "unable to type-check in reasonable time").
struct EdgeRevealSidebars: ViewModifier {
  @EnvironmentObject private var store: AppStore
  let sidebarVisible: Bool
  let inspectorVisible: Bool

  func body(content: Content) -> some View {
    content
      .overlay {
        EdgeRevealSidebar(
          side: .leading, enabled: !sidebarVisible, width: store.dockedSidebarWidth ?? 260
        ) {
          ProjectSidebar()
        }
      }
      .overlay {
        EdgeRevealSidebar(
          side: .trailing, enabled: !inspectorVisible, width: store.dockedInspectorWidth ?? 300
        ) {
          RightInspector()
        }
      }
  }
}
