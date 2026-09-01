import SwiftUI

/// The accent "Update" pill in the trailing title bar, shown when Sparkle has found a newer version in
/// the background (a gentle reminder — see `Updater`). Tapping it runs Sparkle's standard check, which
/// presents the already-found update's install prompt. Filled with the theme accent (like
/// `UnreadBadge`) so it reads as a call to action beside the plain icon buttons. Renders nothing when
/// no update is pending.
struct UpdateAvailableButton: View {
  @EnvironmentObject private var updater: Updater
  @State private var hovering = false
  private let theme = ThemeService.shared

  /// A check already in flight elsewhere blocks a new one; a download blocks a redundant click on an
  /// already-shown Sparkle progress window (`canCheckForUpdates` alone doesn't catch this — Sparkle
  /// keeps it true while its own window is up).
  private var isBusy: Bool { updater.isDownloading || !updater.canCheckForUpdates }

  var body: some View {
    if let version = updater.availableVersionString {
      Button {
        updater.checkForUpdates()
      } label: {
        HStack(spacing: 4) {
          if updater.isDownloading {
            ProgressView().controlSize(.mini)
            Text("Updating…").fontWeight(.regular)
          } else {
            Image(systemName: "arrow.down.circle.fill")
            Text("Update")
          }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(theme.tokens.accentForeground.opacity(isBusy ? 0.85 : 1))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
          Capsule().fill(theme.tokens.accent.opacity(isBusy ? 0.5 : (hovering ? 0.85 : 1)))
        )
        .contentShape(Capsule())
      }
      // Override the title bar's shared ToolbarIconButtonStyle — this is a filled pill, not an icon.
      .buttonStyle(.plain)
      .disabled(isBusy)
      // Animate the hover dim imperatively, NOT via a `.animation(value: hovering)` modifier wrapping
      // the label. The modifier would also interpolate any 1pt re-round of the label's pixel-snapped
      // origin on hover-in into a visible slide (the icon-button "jumps on hover" bug, issue #78);
      // `withAnimation` confines the easing to the opacity change and leaves layout to snap.
      .onHover { isHovering in
        withAnimation(.easeOut(duration: 0.12)) { hovering = isHovering }
      }
      .help(
        updater.isDownloading
          ? "Updating…" : "Update to \(version) — click to install"
      )
      .accessibilityLabel("Update available")
      .accessibilityIdentifier("toolbar.update")
    }
  }
}
