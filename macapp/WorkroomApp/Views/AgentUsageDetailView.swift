import SwiftUI

/// The detailed usage breakdown opened by clicking the footer's quota segment — one row per window,
/// each showing a progress bar against the reset countdown, plus a pace caption. Since issue #168
/// the footer segment is bars alone, so this popover (and the segment's tooltip) is the ONLY place
/// the percentages behind them are written out.
struct AgentUsageDetailView: View {
  /// The popover's fixed presented width (the caller applies this via `.frame(width:)`) — kept here,
  /// not just at the call site, so `barWidth` below derives from the same number rather than a second
  /// copy that could drift out of sync.
  static let popoverWidth: CGFloat = 320
  private static let horizontalPadding: CGFloat = 14
  /// Matches `resetDescription`'s own minute-level precision (see its doc comment) — refreshing
  /// faster wouldn't change anything the displayed text shows.
  private static let refreshInterval: TimeInterval = 60

  let snapshot: AgentQuotaSnapshot

  /// Seeds `currentTime` below; the view re-reads its own clock afterward rather than holding this
  /// fixed, since a pinned popover (unlike the old hover-only tooltip) can stay open indefinitely —
  /// without a live clock its "resets in" text and pace marker would freeze at whatever moment it
  /// happened to open.
  @State private var currentTime: Date
  private let theme = ThemeService.shared
  private var barWidth: CGFloat { Self.popoverWidth - Self.horizontalPadding * 2 }

  init(snapshot: AgentQuotaSnapshot, now: Date) {
    self.snapshot = snapshot
    _currentTime = State(initialValue: now)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(snapshot.windows) { window in
        windowRow(window)
      }
    }
    .padding(Self.horizontalPadding)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal.statusBar.agentUsage.detail")
    .onReceive(Timer.publish(every: Self.refreshInterval, on: .main, in: .common).autoconnect()) {
      time in
      currentTime = time
    }
  }

  private func windowRow(_ window: AgentQuotaWindow) -> some View {
    let pace = window.pace(at: currentTime)
    let paceMarker = window.sustainablePacePercentage(at: currentTime)

    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text("\(title(for: window.kind)) \(Int(window.usedPercentage.rounded()))% used")
          .font(.callout)
          .fontWeight(.semibold)
        Spacer(minLength: 12)
        Text(capitalizedResetDescription(window))
          .font(.caption)
          .foregroundStyle(theme.tokens.fgMuted)
      }

      QuotaBar(
        usedPercentage: window.usedPercentage, markerPercentage: paceMarker,
        fill: QuotaBar.fill(for: pace.severity, theme.tokens), width: barWidth)

      Text(caption(for: pace))
        .font(.caption)
        .foregroundStyle(theme.tokens.fgMuted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  private func title(for kind: AgentQuotaWindowKind) -> String {
    switch kind {
    case .fiveHour: return "Session"
    case .weekly: return "Weekly"
    case .duration: return "\(kind.compactLabel) window"
    }
  }

  private func capitalizedResetDescription(_ window: AgentQuotaWindow) -> String {
    let raw = window.resetDescription(at: currentTime)
    return raw.prefix(1).uppercased() + raw.dropFirst()
  }

  /// `"9% in reserve · Lasts until reset"`.
  private func caption(for pace: AgentPace) -> String {
    let status = pace.isOver ? "May run out before reset" : "Lasts until reset"
    return "\(pace.accessibilityDescription) · \(status)"
  }
}

/// A track with a filled portion (usage) and a marker pin (the sustainable-pace point), drawn at two
/// scales: the popover's full-width rows and the pane footer's compact segment (issue #168).
///
/// ```
/// 0%                          used%                        100%
/// ├────────────────────────────┤                             ┤
/// ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  fill (severity) on track (border)
///                  █                                          pace pin at elapsed%, fgMuted
///                  └ offset = width × pct/100 − haloWidth/2
/// ```
///
/// Three colour decisions, each of them a correction rather than a preference:
///
/// - **The fill is severity-colored, not one constant tint.** It used to be a flat `accent`, on the
///   reasoning that the footer's inline text carried the severity instead. Issue #168 deleted that
///   text, so the fill is now the only place a deficit is visible — and both surfaces read the same
///   rule from `QuotaBar.fill(for:_:)`, so a window can't be amber in the footer and plain in the
///   popover.
/// - **The track is `border` (fg @ 0.12), not `surface` (fg @ 0.08).** `surface` on the footer's
///   `panel` ground is fainter than a hairline divider and barely above `hover`'s deliberate wash,
///   which at compact height read as no track at all — leaving a fill you couldn't see the extent of.
/// - **The pin's gap is a real knockout, not a painted-over patch.** It was `surface`, which is
///   translucent: composited over the fill it came out as fill + 8% fg and notched nothing, in
///   direct contradiction of the comment that used to sit here. Painting an opaque colour instead
///   only moves the problem, because the caller has to GUESS its own ground and both callers guessed
///   wrong — the footer's segment paints `hover` behind itself while hovered (which is now the
///   primary read path, since the percentages live in the tooltip), and the popover never sets a
///   background at all, so its content sits on system material. `.blendMode(.destinationOut)` inside
///   a `.compositingGroup()` erases instead of painting, so the gap is correct on every ground
///   without anyone having to name it.
///
/// The pin itself is neutral (`fgMuted`). It was state-colored — red past pace, green under it — but
/// with the fill now carrying that signal, coloring the pin too double-encodes it; the row caption
/// ("May run out before reset") already says it in words.
///
/// Takes an explicit `width` rather than reading one from a `GeometryReader`: a `.popover`'s content
/// view computes its own preferred size once at presentation time, and a `GeometryReader` anywhere in
/// that tree throws that computation off — it reported an intrinsic size too short to hold this row's
/// caption text, which then rendered truncated instead of wrapped. The caller already fixes the
/// popover to `AgentUsageDetailView.popoverWidth`, so the bar can just derive from that same constant.
struct QuotaBar: View {
  let usedPercentage: Double
  let markerPercentage: Double
  let fill: Color
  let width: CGFloat
  /// Scales the two HORIZONTAL marker constants for the footer's short bars. Heights are untouched:
  /// the footer is a fixed 28pt whose content height is already set by its 11pt font, so a 12pt
  /// marker neither clips nor grows anything. The widths do need it: on the narrowest footer bar a
  /// 6pt halo would be a quarter of the whole track, and measuring a first pass at 4pt showed it
  /// swallowing the entire gap between the fill's edge and the pin — leaving a pin that no longer
  /// showed which side of sustainable pace the window was on.
  var compact: Bool = false

  /// The one place a `PaceSeverity` becomes a colour, shared by the footer segment and the popover
  /// rows so the two cannot disagree about the same window.
  static func fill(for severity: PaceSeverity, _ tokens: ThemeTokens) -> Color {
    switch severity {
    case .onPace: return tokens.accent
    case .warning: return tokens.warning
    case .critical: return tokens.failure
    }
  }

  private let theme = ThemeService.shared
  private let trackHeight: CGFloat = 6
  /// Taller than the track, so the marker reads as a pin planted on it rather than another band of
  /// the bar's own color.
  private let markerHeight: CGFloat = 12
  private var markerHaloWidth: CGFloat { compact ? 2.5 : 6 }
  private var markerLineWidth: CGFloat { compact ? 1.5 : 2.5 }

  /// Where the pin's centre sits along the track.
  private var markerCenter: CGFloat { width * CGFloat(markerPercentage / 100) }

  var body: some View {
    ZStack(alignment: .leading) {
      Capsule().fill(theme.tokens.border).frame(width: width, height: trackHeight)
      Capsule()
        .fill(fill)
        .frame(width: width * CGFloat(usedPercentage / 100), height: trackHeight)
      // Erases the track and fill beneath it rather than painting over them, so the gap reads the
      // same whether the pin lands on the filled or the empty portion, on any background.
      Capsule()
        .frame(width: markerHaloWidth, height: markerHeight)
        .offset(x: max(0, markerCenter - markerHaloWidth / 2))
        .blendMode(.destinationOut)
    }
    // Required for `.destinationOut`: it composites against the group, not the whole window.
    .compositingGroup()
    // The pin itself goes OUTSIDE the group, or the knockout would erase it too.
    .overlay(alignment: .leading) {
      Capsule()
        .fill(theme.tokens.fgMuted)
        .frame(width: markerLineWidth, height: markerHeight)
        .offset(x: max(0, markerCenter - markerLineWidth / 2))
    }
    .frame(height: markerHeight)
  }
}
