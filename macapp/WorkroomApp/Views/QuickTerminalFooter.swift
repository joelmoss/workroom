import SwiftUI

/// The Quick Terminal's footer: the same folder, branch and agent usage a pane's status bar shows,
/// built from the same segments. It has no run command, diagnosis or detached sessions.
struct QuickTerminalFooter: View {
  @ObservedObject var status: QuickTerminalStatus
  /// The surrounding window isn't SwiftUI, so nothing else redraws this on a theme switch.
  @State private var themeTick = 0

  var body: some View {
    HStack(spacing: 12) {
      StatusBarCwdSegment(cwd: status.cwd, onHost: false)
      if let branch = status.branch {
        StatusBarDivider()
        StatusBarBranchSegment(branch: branch)
      }
      Spacer(minLength: 8)
      // Lowest priority, so it gives way before the folder or branch, as in a pane.
      if let backend = status.backend {
        PaneUsageSlot(backend: backend, claudeProfile: status.claudeProfile)
          .layoutPriority(-1)
      }
    }
    .statusBarChrome()
    .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in themeTick += 1 }
  }
}
