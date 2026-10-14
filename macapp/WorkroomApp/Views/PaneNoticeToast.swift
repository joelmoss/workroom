import SwiftUI

/// A toast over one terminal pane, for something that happened to that pane rather than to the
/// workroom: a restored pane whose terminal had ended and was replaced by a new one (#459). Hosted by
/// `GhosttySurfaceView` (`PaneNoticeHost`), top-trailing, so it never covers the go-to-bottom button.
///
/// Styled as `ToastStack`'s `ToastView`, minus the source line: the pane it describes is the one
/// beneath it, so there is nothing to navigate to and a click dismisses it. Auto-dismisses after 8s,
/// paused while hovered.
struct PaneNoticeToast: View {
  /// Transparent room around the card for its shadow. `PaneNoticeHost` passes clicks in it through
  /// to the terminal.
  static let shadowRoom: CGFloat = 32

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
    .frame(width: 300, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).fill(theme.tokens.hover.opacity(hovering ? 1 : 0)))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.tokens.border, lineWidth: 0.5))
    .overlay(alignment: .topTrailing) { closeButton }
    .shadow(
      color: .black.opacity(hovering ? 0.34 : 0.28), radius: hovering ? 22 : 18,
      y: hovering ? 10 : 8
    )
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
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(message)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Dismisses this notice")
    .accessibilityAction { onDismiss() }
    .padding(Self.shadowRoom)
  }

  /// As `ToastView`'s: revealed on hover, hidden from VoiceOver (the default action dismisses).
  private var closeButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(theme.tokens.border, lineWidth: 0.5))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .padding(6)
    .opacity(hovering ? 1 : 0)
    .allowsHitTesting(hovering)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
    .help("Dismiss")
    .accessibilityHidden(true)
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

/// Hosts a `PaneNoticeToast` over a terminal, passing clicks in its transparent shadow room through
/// to the terminal beneath.
final class PaneNoticeHost: NSHostingView<PaneNoticeToast> {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    let room = PaneNoticeToast.shadowRoom
    guard bounds.insetBy(dx: room, dy: room).contains(local) else { return nil }
    return super.hitTest(point)
  }
}
