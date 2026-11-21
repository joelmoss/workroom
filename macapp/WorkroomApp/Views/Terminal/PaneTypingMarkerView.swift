import AppKit
import DesignSystem
import SwiftUI

/// The typing marker's measurements (#696), in points. Whole numbers, so the pill lands on the
/// pixel grid at any scale it is centred at.
enum PaneTypingMarkerMetrics {
  /// From the top of the terminal to the pill: the go-to-bottom button's inset from the bottom.
  static let topInset: CGFloat = 12
  static let height: CGFloat = 22
  static let iconSize: CGFloat = 12
  /// Below the pill, for its shadow to fall into; clicks there reach the terminal like any other.
  static let shadowRoom: CGFloat = 14
  /// The least room kept either side of the pill in a narrow pane; its text truncates first.
  static let sideMargin: CGFloat = 12
  /// The band across the top of the terminal the marker's host covers.
  static var band: CGFloat { topInset + height + shadowRoom }
}

/// What the pill shows, which `PaneTypingMarkerOverlay` sets with the animation it wants.
@MainActor @Observable
final class PaneTypingMarkerModel {
  var marker: PaneTypingMarker?
}

/// Who is typing into this pane (#696): a pill floating at the top centre of the terminal, in the
/// theme's own colours over a thin material, with the sender's agent logo (the one its tab chip
/// shows) or the terminal glyph, its name and its tab. Purely a sign: it takes no clicks and no
/// focus (`PaneTypingMarkerHost`), so it never gets between the user and their terminal.
struct PaneTypingMarkerView: View {
  let model: PaneTypingMarkerModel
  /// The pill's frame in the host, for the tooltip's rect, and `.zero` once it has gone.
  let onPillFrame: (CGRect) -> Void

  @Environment(\.themeTokens) private var tokens
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .top) {
      if let marker = model.marker {
        pill(marker)
          .transition(
            reduceMotion
              ? .opacity
              : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: -3)),
                removal: .opacity))
      }
    }
    .padding(.top, PaneTypingMarkerMetrics.topInset)
    .padding(.horizontal, PaneTypingMarkerMetrics.sideMargin)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .coordinateSpace(.named(Self.space))
    .onChange(of: model.marker == nil) { _, gone in
      if gone { onPillFrame(.zero) }
    }
  }

  private static let space = "typingMarker"

  private func pill(_ marker: PaneTypingMarker) -> some View {
    HStack(spacing: 5) {
      icon(marker.icon)
      Text(marker.name)
        .fontWeight(.semibold)
        .foregroundStyle(tokens.fg)
        .lineLimit(1)
      if let place = marker.place {
        Text("·").foregroundStyle(tokens.fgDim)
        // Kept whole in a narrow pane, where the name truncates first: the tab is what the user
        // goes to.
        Text(place)
          .foregroundStyle(tokens.fgMuted)
          .lineLimit(1)
          .layoutPriority(1)
      }
      if marker.others > 0 {
        Text("+\(marker.others)")
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(tokens.fgMuted)
          .padding(.horizontal, 5)
          .frame(height: 14)
          .background(Capsule().fill(tokens.surface))
      }
    }
    .font(.subheadline)
    .padding(.leading, 6)
    .padding(.trailing, 9)
    .frame(height: PaneTypingMarkerMetrics.height)
    .background {
      Capsule().fill(.ultraThinMaterial)
      Capsule().fill(tokens.bg.opacity(0.8))
    }
    .overlay(Capsule().strokeBorder(tokens.border, lineWidth: 0.5))
    .shadow(color: .black.opacity(0.16), radius: 7, y: 2)
    .environment(\.colorScheme, tokens.colorScheme)
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .named(Self.space))
    } action: {
      onPillFrame($0)
    }
    // One element whose description is the tooltip's sentence. Not a static text: on macOS that
    // reports its words as a value, with no description.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(marker.help)
    .accessibilityIdentifier("terminal.typingMarker")
  }

  @ViewBuilder private func icon(_ icon: PaneTypingMarker.Icon) -> some View {
    let size = PaneTypingMarkerMetrics.iconSize
    if case .agent(let agent) = icon, let tool = Self.logos[agent] {
      Image(ToolLogoRegistry.assetName(for: tool.id))
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    } else {
      // The glyph a terminal's tab chip shows, in a slot as wide as a logo, so the text never
      // moves when the sender changes.
      Image(systemName: "terminal")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(tokens.fgMuted)
        .frame(width: size, height: size)
    }
  }

  /// Each coding agent's bundled logo, resolved once: `ToolLogoRegistry` only vends one whose
  /// imageset shipped, so the pill never draws a blank.
  private static let logos: [CodingAgentBackend: RecognizedTool] = Dictionary(
    uniqueKeysWithValues: CodingAgentBackend.allCases.compactMap { agent in
      ToolLogoRegistry.tool(forExecutableName: agent.executable).map { (agent, $0) }
    })
}

/// Hosts the typing marker over a terminal. It takes no mouse input at all: every click, drag,
/// scroll and hover goes to the terminal beneath, whose cursor stays its own. The tooltip is the
/// terminal's, over the pill's rect (`PaneTypingMarkerOverlay`).
final class PaneTypingMarkerHost: NSHostingView<ThemeRooted<PaneTypingMarkerView>> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func resetCursorRects() {}
  override var acceptsFirstResponder: Bool { false }
}

/// A terminal's typing marker (#696): follows `PaneTypingMonitor` for the pane's session, and shows
/// who else is typing into it, fading in at their first keystroke and out 3 s after their last. It
/// can't be turned off. Owned by `GhosttySurfaceView`, so it goes wherever the terminal does: a
/// split, a pane popped out into its own window, the Quick Terminal.
@MainActor
final class PaneTypingMarkerOverlay: NSObject, NSViewToolTipOwner {
  /// The terminal the marker floats over, which holds the tooltip.
  private weak var surface: NSView?
  /// The pane's session, read each time: its tab's.
  private let session: () -> UUID?
  var monitor: PaneTypingMonitor = .shared
  /// Where a session's terminal is open. A seam for tests.
  var locate: (UUID) -> PaneTypingPlace? = { PaneTypingPlace.locate($0) }
  let model = PaneTypingMarkerModel()
  private(set) var host: PaneTypingMarkerHost?
  private var listener: UUID?
  private var toolTip: NSView.ToolTipTag?
  /// The pill's frame in the host's own coordinates, `.zero` while none shows.
  private var pillFrame: CGRect = .zero

  init(surface: NSView, session: @escaping () -> UUID?) {
    self.surface = surface
    self.session = session
  }

  // A window closing frees its panes without a teardown: the monitor stops calling this one.
  isolated deinit {
    if let listener { monitor.removeListener(listener) }
  }

  /// Starts following the monitor.
  func start() {
    guard listener == nil else { return }
    listener = monitor.addListener { [weak self] sessions in
      guard let self, let session = self.session(), sessions.contains(session) else { return }
      self.refresh()
    }
  }

  /// Stops for good: the pane closed.
  func stop() {
    if let listener { monitor.removeListener(listener) }
    listener = nil
    removeToolTip()
    host?.removeFromSuperview()
    host = nil
  }

  /// Shows what the monitor says now: who is typing into the pane, or nobody.
  func refresh() {
    let marker = session().flatMap { session -> PaneTypingMarker? in
      PaneTypingMarker.make(
        typists: monitor.typists(of: session), receiver: locate(session), locate: locate)
    }
    guard marker != model.marker else { return }
    let appearing = model.marker == nil
    if marker != nil { installHost() }
    let animation: Animation =
      marker == nil
      ? .easeIn(duration: 0.35) : appearing ? .easeOut(duration: 0.2) : .smooth(duration: 0.2)
    withAnimation(animation) { model.marker = marker }
    if marker == nil { removeToolTip() }
    guard let marker, appearing, let host else { return }
    // Told to VoiceOver too, once per run of typing: a user in the terminal would never see it.
    NSAccessibility.post(
      element: host, notification: .announcementRequested,
      userInfo: [
        .announcement: marker.help, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
  }

  /// Lays the host across the top of the terminal: called as the terminal resizes.
  func layout() {
    guard let host, let surface else { return }
    let band = PaneTypingMarkerMetrics.band
    // The surface is not flipped: y counts from the bottom.
    host.frame = CGRect(
      x: 0, y: max(0, surface.bounds.height - band), width: surface.bounds.width, height: band)
    updateToolTip()
  }

  /// Keeps the marker above the terminal's Metal content and its other overlays after the surface
  /// re-adds them (`createSurface`).
  func raise() {
    guard let host, let surface else { return }
    surface.addSubview(host, positioned: .above, relativeTo: nil)
  }

  private func installHost() {
    guard host == nil, let surface else { return }
    let host = PaneTypingMarkerHost(
      rootView: PaneTypingMarkerView(model: model) { [weak self] frame in
        self?.pillFrame = frame
        self?.updateToolTip()
      }
      .themeTokensRoot())
    host.sizingOptions = []
    host.autoresizingMask = [.width, .minYMargin]
    surface.addSubview(host, positioned: .above, relativeTo: nil)
    self.host = host
    layout()
  }

  /// The tooltip over the pill, on the terminal: the view the mouse is over is the terminal's, as
  /// the marker takes no mouse input.
  private func updateToolTip() {
    removeToolTip()
    guard model.marker != nil, pillFrame != .zero, let host, let surface else { return }
    // SwiftUI measures from the top; a host that is not flipped measures from the bottom.
    var local = pillFrame
    if !host.isFlipped { local.origin.y = host.bounds.height - pillFrame.maxY }
    toolTip = surface.addToolTip(surface.convert(local, from: host), owner: self, userData: nil)
  }

  private func removeToolTip() {
    if let toolTip { surface?.removeToolTip(toolTip) }
    toolTip = nil
  }

  /// The tooltip's text: who is typing, from which tab, into this pane.
  var help: String? { model.marker?.help }

  nonisolated func view(
    _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String {
    MainActor.assumeIsolated { help ?? "" }
  }
}
