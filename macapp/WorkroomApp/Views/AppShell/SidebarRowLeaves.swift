import SwiftUI
import WorkroomDomain

// Leaves of the sidebar's rows that read what changes without the row changing, so the change
// repaints the leaf and re-runs no row: a root's resolved branch, and each host's program-status
// link.

/// A root row's label: the branch its project's root is on (`RootPresentation`).
struct SidebarRootLabel: View {
  @EnvironmentObject private var vcsStatus: VCSStatusService
  let projectID: Project.ID

  var body: some View {
    #if DEBUG
      let _ = { SidebarRowPasses.rootLabel += 1 }()
    #endif
    let style = RootPresentation.make(vcsStatus.rootRefs[projectID] ?? .unresolved)
    Text(style.label)
      .font(.callout)
      .lineLimit(1)
      .truncationMode(.tail)
      // A healthy root must apply NO foreground color so it inherits the sidebar's default
      // (vibrant) foreground and dims with every other row when the window goes inactive — exactly
      // like the workroom rows. Pinning a color here (even `.foregroundColor(nil)`) opts the text
      // out of that vibrancy dimming, which left roots bright on blur (issue #43). Only the
      // de-emphasized detached/none states take an explicit `.secondary`.
      .modifier(RootLabelTint(dim: style.dim))
  }
}

/// A root row's tooltip: its branch, as `SidebarRootLabel` reads it.
struct SidebarRootTooltip: ViewModifier {
  @EnvironmentObject private var vcsStatus: VCSStatusService
  let projectID: Project.ID

  func body(content: Content) -> some View {
    content.help(RootPresentation.make(vcsStatus.rootRefs[projectID] ?? .unresolved).tooltip)
  }
}

/// A terminal row's tooltip: its title, then what its program reports or why nothing does. Each
/// host's program-status link (#358) is observed here, so a host that connects repaints the
/// "Program status: …" line, and its publishes re-run no row.
struct SidebarTerminalTooltip: ViewModifier {
  @ObservedObject private var programStatus = ProgramStatusMonitor.shared
  let title: String
  let indicator: PaneIndicator
  let rollup: ProgramStatusRollup?
  let hasSession: Bool
  let hostID: HostID

  func body(content: Content) -> some View {
    let lines = ProgramStatusPresentation.tooltipLines(
      indicator: indicator, rollup: rollup, hostState: programStatus.hosts[hostID],
      hasSession: hasSession)
    return content.help(([title] + lines).joined(separator: "\n"))
  }
}
