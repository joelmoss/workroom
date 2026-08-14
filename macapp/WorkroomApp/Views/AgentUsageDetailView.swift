import SwiftUI

/// The detailed usage breakdown opened by clicking the footer's quota segment — one row per window,
/// each showing a progress bar against the reset countdown, plus a pace caption. The compact footer
/// segment stays a glanceable summary; this is where the numbers behind it live.
struct AgentUsageDetailView: View {
  /// The popover's fixed presented width (the caller applies this via `.frame(width:)`) — kept here,
  /// not just at the call site, so `barWidth` below derives from the same number rather than a second
  /// copy that could drift out of sync.
  static let popoverWidth: CGFloat = 320
  private static let horizontalPadding: CGFloat = 14

  let snapshot: AgentQuotaSnapshot
  let now: Date

  private let theme = ThemeService.shared
  private var barWidth: CGFloat { Self.popoverWidth - Self.horizontalPadding * 2 }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(snapshot.windows) { window in
        windowRow(window)
      }
    }
    .padding(Self.horizontalPadding)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal.statusBar.agentUsage.detail")
  }

  private func windowRow(_ window: AgentQuotaWindow) -> some View {
    let pace = window.pace(at: now)
    // The marker sits at the "sustainable pace" point — where usage would be if it exactly tracked
    // the window's elapsed time — derived from the pace already computed for the compact footer
    // (`usedPercentage - pace.percentagePoints` recovers that elapsed fraction) rather than a second,
    // independently-maintained calculation.
    let paceMarker = min(max(window.usedPercentage - pace.percentagePoints, 0), 100)

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
        markerIsOverPace: pace.isOver, width: barWidth)

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
    let raw = window.resetDescription(at: now)
    return raw.prefix(1).uppercased() + raw.dropFirst()
  }

  /// `"9% in reserve · Lasts until reset"`.
  private func caption(for pace: AgentPace) -> String {
    let status = pace.isOver ? "May run out before reset" : "Lasts until reset"
    return "\(pace.accessibilityDescription) · \(status)"
  }
}

/// A track with a filled portion (usage) and a marker pin (the sustainable-pace point). The fill
/// stays one constant tint rather than a severity traffic light — the footer's inline text already
/// carries that — but the marker itself IS state-colored: failure-red once this window is past its
/// sustainable pace (a deficit is the case worth noticing), success-green while still under it.
///
/// Takes an explicit `width` rather than reading one from a `GeometryReader`: a `.popover`'s content
/// view computes its own preferred size once at presentation time, and a `GeometryReader` anywhere in
/// that tree throws that computation off — it reported an intrinsic size too short to hold this row's
/// caption text, which then rendered truncated instead of wrapped. The caller already fixes the
/// popover to `AgentUsageDetailView.popoverWidth`, so the bar can just derive from that same constant.
private struct QuotaBar: View {
  let usedPercentage: Double
  let markerPercentage: Double
  let markerIsOverPace: Bool
  let width: CGFloat

  private let theme = ThemeService.shared
  private let trackHeight: CGFloat = 6
  /// Taller than the track, so the marker reads as a pin planted on it rather than another band of
  /// the bar's own color.
  private let markerHeight: CGFloat = 12
  private let markerHaloWidth: CGFloat = 6
  private let markerLineWidth: CGFloat = 2.5

  private var markerColor: Color {
    markerIsOverPace ? theme.tokens.failure : theme.tokens.diffAddFg
  }

  var body: some View {
    ZStack(alignment: .leading) {
      Capsule().fill(theme.tokens.surface).frame(width: width, height: trackHeight)
      Capsule()
        .fill(theme.tokens.accent)
        .frame(width: width * CGFloat(usedPercentage / 100), height: trackHeight)
      marker
    }
    .frame(height: markerHeight)
  }

  /// A halo in the track's own base color — so it cuts the same clean notch whether it lands over the
  /// filled or the empty portion — around a bold, state-colored center line.
  private var marker: some View {
    ZStack {
      Capsule().fill(theme.tokens.surface).frame(width: markerHaloWidth)
      Capsule().fill(markerColor).frame(width: markerLineWidth)
    }
    .frame(height: markerHeight)
    .offset(x: max(0, width * CGFloat(markerPercentage / 100) - markerHaloWidth / 2))
  }
}
