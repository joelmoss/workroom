import SwiftUI

/// The loading animation shown centered in the detail pane while a workroom is being created (issue
/// #116): the whole pre-name phase, and — for a workroom with NO setup script — all the way until its
/// terminal drops in (there's no dialog in that case). A workroom WITH a setup script swaps this for
/// `SetupOverlay` once the script starts. Scoped to the creating slot by the caller, so selecting
/// another workroom shows that workroom instead (the create keeps running in the background).
struct CreationLoader: View {
  private let theme = ThemeService.shared

  var body: some View {
    VStack(spacing: 14) {
      ProgressView().controlSize(.large)
      Text("Creating workroom…")
        .font(.callout)
        .foregroundStyle(theme.tokens.fgMuted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Creating workroom")
    .accessibilityIdentifier("CreationLoader")
  }
}

/// The setup dialog shown full-pane in the detail area while a workroom's **setup script** runs
/// (issues #18, #116). Only workrooms WITH a setup script ever show it — a no-setup create shows just
/// `CreationLoader`, then its terminal. It swaps in from the loader once the script starts, streaming
/// the log; a "Dismiss" button appears once the run finishes (success or failure), and dismissing
/// lets the real terminal mount. A solid themed surface sits behind the card (no half-mounted terminal
/// peeks through). The card springs in on appear. The caller scopes it to the creating slot, so
/// selecting another workroom shows that workroom while the script keeps running in the background.
///
/// `@ObservedObject` keeps the streaming log scoped here.
struct SetupOverlay: View {
  @ObservedObject var session: ScriptLogSession
  var onDismiss: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let theme = ThemeService.shared
  /// Drives the enter animation. Flipped true in `onAppear` so the spring plays reliably regardless
  /// of how the containing pane was mounted (a `.transition` alone won't animate when the pane
  /// appears already-blocking).
  @State private var shown = false

  var body: some View {
    ZStack {
      // A solid themed surface behind the card (issue #116): a dedicated "setting up" screen, so no
      // half-mounted terminal shows through while the workroom is created. Opaque from the first
      // frame (not faded in) so nothing behind it ever flashes into view.
      theme.tokens.panel.ignoresSafeArea()

      card
        .frame(maxWidth: 720, maxHeight: 520)
        .scaleEffect(shown ? 1 : 0.98)
        .opacity(shown ? 1 : 0)
        .padding(32)
    }
    .onAppear {
      guard !shown else { return }
      if reduceMotion {
        shown = true
      } else {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { shown = true }
      }
    }
  }

  private var card: some View {
    VStack(spacing: 0) {
      ScriptLogContent(session: session, onClose: nil)
      // A "Dismiss" button once the setup run finishes (success or failure) — dismissing mounts the
      // withheld terminal (issue #116). While it's still running there's no button, just the log.
      if session.isFinished {
        Divider()
        HStack {
          Spacer()
          Button("Dismiss", action: onDismiss)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("DismissSetup")
        }
        .padding(12)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: session.isFinished)
    .background(theme.tokens.surface)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(theme.tokens.border, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
  }
}
