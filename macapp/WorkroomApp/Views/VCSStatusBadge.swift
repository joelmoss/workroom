import SwiftUI

/// Maps a status semantic to a concrete color. Color is *additive* — the SF Symbol shape
/// already carries the meaning (so color-blind users and the issue-#43 window-blur dimming
/// don't lose the signal). Unknown/neutral stay muted (`.secondary`), never alarming.
extension VCSStatusPresentation.Semantic {
  var color: Color {
    switch self {
    case .dirty: return .orange
    case .conflict: return .red
    case .unknown: return .secondary
    case .ciPass: return .green
    case .ciFail: return .red
    case .ciRunning: return .orange
    case .neutral: return .secondary
    }
  }
}

/// The shared, compact VCS status cluster (issue #24): a dirty/conflict/unknown dot, optional
/// ahead/behind counts, and an optional CI glyph. Used identically by the sidebar rows and the
/// workroom tab chip (the chip uses `compact` to drop the ahead/behind text). Clean renders
/// nothing (so dirty pops); absent CI renders nothing. Glyph order is fixed so dirty dots scan
/// as a column. The dot never truncates; ahead/behind compresses (only the non-zero side); the
/// CI glyph is last to lay out, so it's the first to be pushed out on a narrow row.
struct VCSStatusCluster: View {
  let status: WorkroomStatus
  /// Tab-chip mode: show only the status dot + CI glyph, no ahead/behind text.
  var compact: Bool = false

  var body: some View {
    let dot = VCSStatusPresentation.dot(status)
    let ab = compact ? nil : VCSStatusPresentation.aheadBehind(status)
    let ci = VCSStatusPresentation.ci(status)
    if dot != nil || ab != nil || ci != nil {
      HStack(spacing: 4) {
        if let dot {
          Image(systemName: dot.symbol)
            .font(.system(size: 9))
            .foregroundStyle(dot.semantic.color)
        }
        if let ab {
          HStack(spacing: 1) {
            if ab.ahead != 0 {
              Image(systemName: "arrow.up").font(.system(size: 8, weight: .semibold))
              Text("\(ab.ahead)").font(.caption2).monospacedDigit()
            }
            if ab.behind != 0 {
              Image(systemName: "arrow.down").font(.system(size: 8, weight: .semibold))
              Text("\(ab.behind)").font(.caption2).monospacedDigit()
            }
          }
          .foregroundStyle(.secondary)
        }
        if let ci {
          Image(systemName: ci.symbol)
            .font(.system(size: 10))
            .foregroundStyle(ci.semantic.color)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(VCSStatusPresentation.accessibilityLabel(status))
    }
  }
}

/// A single aggregate status dot for a collapsed project row — the worst child status, so
/// collapsing a project doesn't hide the command-center signal. Nothing to show ⇒ renders
/// nothing.
struct VCSAggregateDot: View {
  let status: WorkroomStatus
  var body: some View {
    if let dot = VCSStatusPresentation.dot(status) {
      Image(systemName: dot.symbol)
        .font(.system(size: 9))
        .foregroundStyle(dot.semantic.color)
        .accessibilityLabel("project \(dot.accessibility)")
    }
  }
}
