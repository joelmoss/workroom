import SwiftUI

/// A toast over one terminal pane, for something that happened to that pane rather than to the
/// workroom: a restored pane whose terminal had ended and was replaced by a new one (#459). Hosted by
/// `GhosttySurfaceView`, top-trailing, so it never covers the go-to-bottom button.
///
/// Styled as `ToastStack`'s cards. Auto-dismisses after 8s, paused while hovered; a click anywhere on
/// it dismisses it at once. Nothing to navigate to: the pane it describes is the one beneath it.
struct PaneNoticeToast: View {
  let message: String
  let onDismiss: () -> Void

  @State private var hovering = false
  @State private var dismissTask: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let theme = ThemeService.shared

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .foregroundStyle(.secondary)
      Text(message).font(.callout).lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(width: 280, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).fill(theme.tokens.hover.opacity(hovering ? 1 : 0)))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.tokens.border, lineWidth: 0.5))
    .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
    .contentShape(RoundedRectangle(cornerRadius: 12))
    .onTapGesture { onDismiss() }
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
    .onChange(of: hovering) { _, isHovering in
      if isHovering {
        dismissTask?.cancel()
      } else {
        armDismiss()
      }
    }
    .onAppear { armDismiss() }
    .onDisappear { dismissTask?.cancel() }
    // Room for the shadow inside the hosting view's bounds.
    .padding(10)
    .help("Dismiss")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(message)
    .accessibilityAction(named: "Dismiss") { onDismiss() }
  }

  private func armDismiss() {
    dismissTask?.cancel()
    dismissTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
      if Task.isCancelled || hovering { return }
      onDismiss()
    }
  }
}
