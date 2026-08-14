import SwiftUI

/// Wraps whatever `NSView` the hover-preview controller is currently showing (`previewHost`) — a
/// `PreviewHostView` with hit-testing disabled (Codex #12) containing the re-homed, scaled surface.
private struct PreviewHostRepresentable: NSViewRepresentable {
  let host: NSView

  func makeNSView(context: Context) -> NSView { host }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The floating preview box shown near a hovered tab chip once `TerminalHoverPreviewController.phase`
/// reaches `.visible`. Positioned by the caller (`WorkroomTerminalsView`) from the hovered chip's
/// `TabChipAnchorKey` anchor.
struct TerminalHoverPreviewOverlay: View {
  let host: NSView
  let title: String

  /// Chrome overhead outside the host's own bounds — the caption row plus its padding. `host` is
  /// sized (by `TransformScaleFrameSource.mount()`) to hug the previewed pane's own aspect ratio
  /// within `TerminalHoverPreviewController.maxHostSize`, rather than a fixed box, so callers compute
  /// this instance's real footprint from `host.frame.size`, not a static constant.
  static let chromeHeight: CGFloat = 20 + 12 * 2
  private let theme = ThemeService.shared
  private var hostSize: CGSize { host.frame.size }

  var body: some View {
    VStack(spacing: 0) {
      PreviewHostRepresentable(host: host)
        .frame(width: hostSize.width, height: hostSize.height)
        .clipShape(
          RoundedRectangle(
            cornerRadius: TerminalPanelMetrics.cornerRadius, style: .continuous)
        )
      Text(title)
        .font(.caption)
        .foregroundStyle(theme.tokens.fgMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.top, 4)
        .frame(width: hostSize.width, alignment: .leading)
    }
    .padding(6)
    .background {
      RoundedRectangle(cornerRadius: TerminalPanelMetrics.cornerRadius + 4, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: TerminalPanelMetrics.cornerRadius + 4, style: .continuous)
            .strokeBorder(theme.tokens.border, lineWidth: 1)
        )
    }
    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    // Hit-testing is already disabled on the mounted surface itself (`PreviewHostView`), but the
    // overlay's own chrome (border/caption/material) must not intercept clicks meant for whatever's
    // underneath it either — a preview is look-only.
    .allowsHitTesting(false)
  }
}
