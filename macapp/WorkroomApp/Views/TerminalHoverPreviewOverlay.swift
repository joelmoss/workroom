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

  static let width: CGFloat = 260
  static let height: CGFloat = 160
  /// Rough total footprint including the caption row and chrome padding — used by the caller
  /// (`WorkroomTerminalsView`) to position the overlay below a hovered chip without it overlapping.
  static let estimatedTotalHeight: CGFloat = height + 20 + 12 * 2
  private let theme = ThemeService.shared

  var body: some View {
    VStack(spacing: 0) {
      PreviewHostRepresentable(host: host)
        .frame(width: Self.width, height: Self.height)
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
        .frame(width: Self.width, alignment: .leading)
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
