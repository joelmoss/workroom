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
  /// Between a pane notice's card and the pill below it (`PaneNoticeToast`).
  static let noticeGap: CGFloat = 8
  /// The band across the top of the terminal the marker's host covers, with the pill `topInset`
  /// from its top.
  static func band(topInset: CGFloat) -> CGFloat { topInset + height + shadowRoom }
}

/// What the pill shows, which `PaneTypingMarkerOverlay` sets with the animation it wants.
@MainActor @Observable
final class PaneTypingMarkerModel {
  /// What the pill says: kept through its fade-out, so it fades with its words, and gone once the
  /// fade has ended.
  var marker: PaneTypingMarker?
  /// Fading in or shown, rather than fading out. A keystroke during the fade-out turns it back
  /// from where it had got to: the one pill, never a second one beside the first.
  var visible = false
  /// From the top of the terminal to the pill: below a pane notice's card while one shows.
  var topInset = PaneTypingMarkerMetrics.topInset
}

/// Who is typing into this pane (#696): a pill floating at the top centre of the terminal, in the
/// theme's own colours over a thin material, with the sender's agent logo (the one its tab chip
/// shows) or the terminal glyph, its name and its tab. Purely a sign: it takes no clicks and no
/// focus (`PaneTypingMarkerHost`), so it never gets between the user and their terminal.
struct PaneTypingMarkerView: View {
  let model: PaneTypingMarkerModel
  /// The pill's frame in the host, for the tooltip's rect.
  let onPillFrame: (CGRect) -> Void

  @Environment(\.themeTokens) private var tokens
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .top) {
      if let marker = model.marker {
        pill(marker)
          .opacity(model.visible ? 1 : 0)
          .offset(y: model.visible || reduceMotion ? 0 : -3)
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -3)))
      }
    }
    .padding(.top, model.topInset)
    .padding(.horizontal, PaneTypingMarkerMetrics.sideMargin)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .coordinateSpace(.named(Self.space))
  }

  private static let space = "typingMarker"

  private func pill(_ marker: PaneTypingMarker) -> some View {
    HStack(spacing: 5) {
      icon(marker.icon)
      // The name keeps its room longest; the workroom gives way first, from its middle, so its
      // ends still say which one it is, and the tab number never does.
      Text(marker.name)
        .fontWeight(.semibold)
        .foregroundStyle(tokens.fg)
        .lineLimit(1)
        .layoutPriority(2)
      if let tab = marker.tab {
        Text("·").foregroundStyle(tokens.fgDim).fixedSize()
        Text(tab).foregroundStyle(tokens.fgMuted).lineLimit(1).fixedSize()
        if let workroom = marker.workroom {
          Text("in").foregroundStyle(tokens.fgMuted).fixedSize()
          // At most as wide as a tab chip's title (`TabStripMetrics.maxChipTitle`), so a long
          // name never stretches the pill across a wide pane, and a short one as wide as itself.
          CappedWidth(TabStripMetrics.maxChipTitle) {
            Text(workroom)
              .foregroundStyle(tokens.fgMuted)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .layoutPriority(1)
        }
      }
      if marker.others > 0 {
        Text("+\(marker.others)")
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(tokens.fgMuted)
          .padding(.horizontal, 5)
          .frame(height: 14)
          .background(Capsule().fill(tokens.surface))
          .fixedSize()
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

/// Its one subview no wider than `maximum`, and no wider than it needs: unlike
/// `.frame(maxWidth:)`, which grows to fill whatever room it is offered up to its maximum.
private struct CappedWidth: Layout {
  let maximum: CGFloat

  init(_ maximum: CGFloat) { self.maximum = maximum }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = min(proposal.width ?? .infinity, maximum)
    return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
      ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

/// Hosts the typing marker over a terminal. It takes no mouse input at all, by construction: it is
/// never hit (`hitTest` is nil), and it never installs a tracking area or a cursor rect (both
/// refused here, whatever SwiftUI asks for), so every click, drag, scroll and hover goes to the
/// terminal beneath, whose cursor is the only one over the band. The tooltip is the terminal's,
/// over the pill's rect (`PaneTypingMarkerOverlay`).
final class PaneTypingMarkerHost: NSHostingView<ThemeRooted<PaneTypingMarkerView>> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var acceptsFirstResponder: Bool { false }
  override func addTrackingArea(_ trackingArea: NSTrackingArea) {}
  override func updateTrackingAreas() {}
  override func resetCursorRects() {}
  override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) {}
  override func cursorUpdate(with event: NSEvent) {}
}

/// A terminal's typing marker (#696): follows `PaneTypingMonitor` for the pane's session, and shows
/// who else is typing into it, fading in at their first keystroke and out 3 s after their last. It
/// can't be turned off. Owned by `GhosttySurfaceView`, so it goes wherever the terminal does: a
/// split, a pane popped out into its own window, the Quick Terminal.
@MainActor
final class PaneTypingMarkerOverlay: NSObject, NSViewToolTipOwner {
  /// How the marker comes and goes.
  enum Fade {
    static let inDuration = 0.2
    static let outDuration = 0.35
  }

  /// The terminal the marker floats over, which holds the tooltip.
  private weak var surface: NSView?
  /// The pane's session, read each time: its tab's.
  private let session: () -> UUID?
  /// Whether the user can see the pane now: its tab selected, in a window on screen. Only then is
  /// the marker announced to VoiceOver.
  private let isOnScreen: () -> Bool
  /// How far from the terminal's top a pane notice's card reaches (`PaneNoticeToast`), 0 with
  /// none: the pill sits below it, so the two never overlap, whatever the pane's width.
  private let noticeBottom: () -> CGFloat
  var monitor: PaneTypingMonitor = .shared
  /// Where a session's terminal is open. A seam for tests.
  var locate: (UUID) -> PaneTypingPlace? = { PaneTypingPlace.locate($0) }
  /// Where VoiceOver announcements go. A seam for tests.
  var announce: (NSView, String) -> Void = { element, text in
    NSAccessibility.post(
      element: element, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }
  /// Waits out the fade-out before the marker goes. A seam for tests.
  var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  let model = PaneTypingMarkerModel()
  private(set) var host: PaneTypingMarkerHost?
  private var listener: UUID?
  private var toolTip: NSView.ToolTipTag?
  /// The pill's frame in the host's own coordinates (SwiftUI's, from the top).
  private var pillFrame: CGRect = .zero
  /// This run of typing was announced: from the marker's first appearance until its fade-out
  /// ends, so a keystroke during the fade, which brings it back, is not announced again.
  private var announced = false
  /// Counts fade-outs, so one that a keystroke interrupted never removes the marker it brought
  /// back.
  private var fadeOuts = 0

  init(
    surface: NSView, session: @escaping () -> UUID?, isOnScreen: @escaping () -> Bool = { true },
    noticeBottom: @escaping () -> CGFloat = { 0 }
  ) {
    self.surface = surface
    self.session = session
    self.isOnScreen = isOnScreen
    self.noticeBottom = noticeBottom
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
    guard let marker else {
      fadeOut()
      return
    }
    installHost()
    if model.visible {
      if marker != model.marker {
        withAnimation(.smooth(duration: Fade.inDuration)) { model.marker = marker }
      }
    } else {
      // Appearing, or back during a fade-out: from wherever the fade had got to.
      fadeOuts += 1
      withAnimation(.easeOut(duration: Fade.inDuration)) {
        model.marker = marker
        model.visible = true
      }
    }
    updateToolTip()
    announceIfSeen(marker)
  }

  /// Lays the host across the top of the terminal, below any pane notice: called as the terminal
  /// resizes and as a notice comes and goes.
  func layout() {
    guard let host, let surface else { return }
    let reserved = noticeBottom()
    let top =
      reserved > 0
      ? max(PaneTypingMarkerMetrics.topInset, reserved + PaneTypingMarkerMetrics.noticeGap)
      : PaneTypingMarkerMetrics.topInset
    if model.topInset != top {
      withAnimation(.smooth(duration: Fade.inDuration)) { model.topInset = top }
    }
    let band = PaneTypingMarkerMetrics.band(topInset: top)
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

  private func fadeOut() {
    guard model.marker != nil, model.visible else { return }
    removeToolTip()
    fadeOuts += 1
    let fade = fadeOuts
    withAnimation(.easeIn(duration: Fade.outDuration)) { model.visible = false }
    // Gone once the fade has run its course, on the overlay's own clock rather than the
    // animation's completion, so a keystroke meanwhile reliably finds it still there.
    let sleep = self.sleep
    Task { [weak self] in
      try? await sleep(.milliseconds(Int(Fade.outDuration * 1000)))
      // Not when a keystroke brought it back meanwhile.
      guard let self, self.fadeOuts == fade, !self.model.visible else { return }
      var quiet = Transaction()
      quiet.disablesAnimations = true
      withTransaction(quiet) { self.model.marker = nil }
      self.announced = false
    }
  }

  private func announceIfSeen(_ marker: PaneTypingMarker) {
    guard !announced, isOnScreen(), let host else { return }
    announced = true
    announce(host, marker.help)
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
  /// the marker takes no mouse input. Only while the marker shows, not while it fades out.
  private func updateToolTip() {
    removeToolTip()
    guard model.visible, pillFrame != .zero, let host, let surface else { return }
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
  var help: String? { model.visible ? model.marker?.help : nil }

  /// Whether the tooltip is on the terminal now.
  var hasToolTip: Bool { toolTip != nil }

  nonisolated func view(
    _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String {
    MainActor.assumeIsolated { help ?? "" }
  }
}
