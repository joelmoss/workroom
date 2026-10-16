import SwiftUI

/// The terminal body for one target (issue #23). Lifted out of `RootView.targetDetail` so the detail
/// pane and each workroom pane render identical terminal UI. Carries **no** navigation title or
/// toolbar — the caller owns that chrome (`WorkroomPaneLeaf`'s title bar since issue #139).
///
/// Two states withhold the terminal, inside one `ZStack` so this view keeps a single structural
/// position in its parent:
///
/// - **The directory is gone** (deleted on disk). Don't mount a terminal over a dead path. Every
///   visible workroom is guarded here, focused or not (issue #23 follow-up). The way out is the title
///   bar's ✕.
/// - **This workroom is still being created** (#483): its run's `CreationPane`, from the click until
///   the run ends. Each pane draws its OWN run (issue #167, defect 4), so the two halves of a
///   create-as-split each show their own create.
struct TargetTerminalDetail: View {
  let target: TerminalTarget
  /// Whether this workroom pane is the focused one — gates terminal first-responder so a co-displayed
  /// non-focused workroom doesn't steal focus on mount (issue #23 follow-up). `true` for a solo target.
  var surfaceActive: Bool = true
  /// Whether this workroom is itself one member of a multi-workroom split — forwarded to
  /// `WorkroomTerminalsView` (see `PaneTreeView.workroomIsSplit`).
  var workroomIsSplit: Bool = false
  @EnvironmentObject var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let run = store.creationRun(forTargetID: target.id)
    ZStack {
      // A create's run covers its pane in every window, its terminal withheld, until the run ends
      // (`isCreationBlocking`, issue #167, #483). It wins over `.creating`'s unavailability below.
      if let run {
        // On top, so when the run ends it fades out over the terminal mounting beneath it (design
        // D13); under Reduce Motion, a plain swap.
        CreationPane(run: run)
          .zIndex(1)
          .transition(.opacity)
      } else if target.opensTerminals {
        WorkroomTerminalsView(
          target: target, sessions: store.terminals, surfaceActive: surfaceActive,
          workroomIsSplit: workroomIsSplit
        )
        .transition(.identity)
      } else if let reason = target.terminalUnavailability {
        ContentUnavailableView {
          Label(reason.title, systemImage: reason.systemImage)
        } description: {
          Text(reason.detail(for: target))
        }
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: run == nil)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
