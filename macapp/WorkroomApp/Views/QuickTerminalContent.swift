import Defaults
import SwiftUI
import WorkroomDomain

/// Everything in the Quick Terminal's window: its tab bar, then the selected tab's panes, each
/// with a pane's footer.
struct QuickTerminalContent: View {
  @ObservedObject var workspace: QuickTerminalWorkspace
  /// The surrounding window isn't SwiftUI, so nothing else redraws this on a theme switch.
  @State private var themeTick = 0

  var body: some View {
    VStack(spacing: 0) {
      QuickTerminalTabBar(workspace: workspace)
      if let tab = workspace.selectedTab {
        QuickTerminalPaneTree(workspace: workspace, tab: tab, layout: tab.layout)
          // A tab's own tree: switching tabs mounts that tab's surfaces, never re-homes them.
          .id(tab.id)
      }
    }
    .background(ThemeService.shared.tokens.panel)
    .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in themeTick += 1 }
  }
}

/// The tabs, a new-tab button, and empty space to drag the window by. It sits where a titlebar
/// would, so it is the titlebar's height.
private struct QuickTerminalTabBar: View {
  @ObservedObject var workspace: QuickTerminalWorkspace
  private let theme = ThemeService.shared

  var body: some View {
    HStack(spacing: 4) {
      ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
        if let status = workspace.panes[tab.focused]?.status {
          QuickTerminalTabChip(workspace: workspace, tab: tab, index: index, status: status)
        }
      }
      Button {
        workspace.newTab(in: QuickTerminalController.newTabDirectory())
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .help("New Tab (⌘T)")
      .accessibilityLabel("New Tab")
      .accessibilityIdentifier("quickTerminal.newTab")
      QuickTerminalDragHandle()
        .frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 8)
    .frame(height: TerminalPanelMetrics.chromeRowHeight)
    .font(.subheadline)
    .foregroundStyle(theme.tokens.fgMuted)
    .overlay(alignment: .bottom) { theme.tokens.border.frame(height: 1) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("quickTerminal.tabBar")
  }
}

/// A tab: named for its focused shell's folder, which it follows.
private struct QuickTerminalTabChip: View {
  @ObservedObject var workspace: QuickTerminalWorkspace
  let tab: QuickTerminalWorkspace.Tab
  let index: Int
  @ObservedObject var status: QuickTerminalStatus
  private let theme = ThemeService.shared

  var body: some View {
    let selected = tab.id == workspace.selectedTabID
    let title = Self.title(status.cwd)
    HStack(spacing: 4) {
      Text(title).lineLimit(1).truncationMode(.middle)
      Button {
        for id in tab.layout.tabIDs { workspace.closePane(id) }
      } label: {
        Image(systemName: "xmark").font(.caption2)
      }
      .buttonStyle(.borderless)
      .help("Close Tab")
      .accessibilityLabel("Close \(title)")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .frame(maxWidth: 180)
    .foregroundStyle(selected ? theme.tokens.fg : theme.tokens.fgMuted)
    .background(
      RoundedRectangle(cornerRadius: 5).fill(selected ? theme.tokens.surface : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture { workspace.selectTab(tab.id) }
    .help(index < 9 ? "\(title) (⌘\(index + 1))" : title)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("quickTerminal.tab")
  }

  /// "~" at home, else the folder's name.
  static func title(_ cwd: String) -> String {
    if cwd == NSHomeDirectory() { return "~" }
    return (cwd as NSString).lastPathComponent
  }
}

/// One tab's panes: a leaf is a terminal over its footer; a split lays its two sides out with a
/// divider between, as a workroom's pane tree does (`PaneTreeLayout.lengths`, `SplitDivider`).
private struct QuickTerminalPaneTree: View {
  @ObservedObject var workspace: QuickTerminalWorkspace
  let tab: QuickTerminalWorkspace.Tab
  let layout: PaneLayout<UUID>
  @Default(.dimUnfocusedPanes) private var dimUnfocusedPanes

  var body: some View {
    switch layout {
    case .leaf(let id):
      if let pane = workspace.panes[id] { leaf(id, pane) }
    case .split(let splitID, let orientation, let ratio, let first, let second):
      GeometryReader { geometry in
        let total = orientation == .horizontal ? geometry.size.width : geometry.size.height
        let lengths = PaneTreeLayout.lengths(total: total, ratio: ratio, along: orientation)
        let divider = SplitDivider(orientation: orientation, ratio: ratio, total: total) {
          workspace.setRatio($0, forSplit: splitID, inTab: tab.id)
        }
        let gutter = ZStack {
          ThemeService.shared.tokens.border
          divider.frame(
            width: orientation == .horizontal ? PaneTreeLayout.dividerHitThickness : nil,
            height: orientation == .vertical ? PaneTreeLayout.dividerHitThickness : nil)
        }
        if orientation == .horizontal {
          HStack(spacing: 0) {
            subtree(first).frame(width: lengths.first)
            gutter.frame(width: PaneTreeLayout.dividerThickness)
            subtree(second)
          }
        } else {
          VStack(spacing: 0) {
            subtree(first).frame(height: lengths.first)
            gutter.frame(height: PaneTreeLayout.dividerThickness)
            subtree(second)
          }
        }
      }
    }
  }

  private func subtree(_ layout: PaneLayout<UUID>) -> some View {
    QuickTerminalPaneTree(workspace: workspace, tab: tab, layout: layout)
  }

  private func leaf(_ id: UUID, _ pane: QuickTerminalWorkspace.Pane) -> some View {
    let focused = tab.focused == id
    let isSplit = tab.layout.tabIDs.count > 1
    return VStack(spacing: 0) {
      TerminalContainerView(view: pane.surface, isFocusedPane: focused)
        .overlay {
          // As in a workroom's split: the panes you aren't typing in are shaded.
          if isSplit, !focused, dimUnfocusedPanes {
            Color.black.opacity(0.18).allowsHitTesting(false)
          }
        }
      QuickTerminalFooter(status: pane.status)
    }
  }
}
