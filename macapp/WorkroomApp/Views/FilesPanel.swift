import SwiftUI

/// The inspector's **Files** section body: the selected repo's working tree as a collapsible,
/// indented list (it lives inside the inspector's own scroll view, so it flattens the tree to rows
/// itself rather than hosting a `List`/`OutlineGroup`). A single click on a file opens it read-only
/// in the main pane (preview), a quick second click persists it, and ⌘-click opens it in the
/// external editor — mirroring the Changes panel. Directory rows toggle expansion.
struct FilesPanel: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var model: FileTreeModel
  private let theme = ThemeService.shared

  var body: some View {
    Group {
      if store.inspectorTargetID == nil {
        // No active workspace (nothing selected, or the selected workroom has no open tabs) — empty
        // out to match the detail pane's "No terminal" state rather than list a stale workroom.
        placeholder("No open terminal", systemImage: "folder")
      } else {
        switch model.state {
        case .idle:
          placeholder("No workroom selected", systemImage: "folder")
        case .loading:
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Listing files…").font(.callout).foregroundStyle(.secondary)
          }
          .padding(.vertical, 6).padding(.horizontal, 8)
        case .unavailable:
          placeholder("Not a repository", systemImage: "folder.badge.questionmark")
        case .loaded:
          if model.roots.isEmpty {
            placeholder("No files", systemImage: "folder")
          } else {
            fileList
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Point the tree at the inspector's active target (nil once all its tabs close → the tree
    // clears), only while Files is the active activity-bar section. Re-runs on either change;
    // `activate` no-ops when already on the path, so re-selecting the same target is instant.
    .task(id: activationKey) {
      guard store.activeInspectorSection == .files else { return }
      let target = store.inspectorTarget
      model.activate(path: target?.path, projectRoot: target.flatMap(store.projectRoot(forTarget:)))
    }
  }

  private var activationKey: String {
    "\(AppStore.targetIDString(for: store.inspectorTargetID) ?? "")"
      + "\u{1F}\(store.activeInspectorSection == .files)"
  }

  private var fileList: some View {
    let rows = model.rows
    let capped = Array(rows.prefix(FileTreeModel.renderCap))
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(capped, id: \.node.path) { row in
        FileTreeRowView(model: model, row: row)
      }
      if rows.count > capped.count {
        Text("+\(rows.count - capped.count) more — narrow the tree or open in your editor.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.vertical, 4).padding(.horizontal, 8)
      }
    }
    .padding(.vertical, 2)
  }

  private func placeholder(_ text: String, systemImage: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage).foregroundStyle(.tertiary)
      Text(text).font(.callout).foregroundStyle(.secondary)
    }
    .padding(.vertical, 6).padding(.horizontal, 8)
  }
}

/// One row of the Files tree: an indented directory (with a disclosure chevron) or file. Its own
/// view so hover + the click-timing state stay per-row.
private struct FileTreeRowView: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var model: FileTreeModel
  let row: FileTreeRow
  @State private var hovering = false
  /// Tracks the previous click time so a quick second click promotes the preview to a persisted tab
  /// (same manual double-click handling the Changes panel uses).
  @State private var lastClick: Date?
  private let theme = ThemeService.shared

  private var node: FileNode { row.node }
  private var isExpanded: Bool { model.expanded.contains(node.path) }

  var body: some View {
    HStack(spacing: 4) {
      Color.clear.frame(width: CGFloat(row.depth) * 13, height: 1)
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .frame(width: 10)
        .opacity(node.isDirectory ? 1 : 0)
      Image(systemName: node.isDirectory ? "folder" : "doc")
        .font(.system(size: 11))
        .foregroundStyle(node.isDirectory ? theme.tokens.accent : theme.tokens.fgMuted)
        .frame(width: 15, alignment: .center)
      Text(node.name)
        .font(.callout)
        .foregroundStyle(.primary)
        .lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3).padding(.horizontal, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Rectangle()
        .fill(hovering ? theme.tokens.rowHover : .clear)
        .padding(.horizontal, -12)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { handleTap() }
    .help(node.isDirectory ? node.path : "Open \(node.path)")
    .contextMenu {
      if !node.isDirectory {
        Button {
          store.openFileInEditor(path: node.path)
        } label: {
          Label("Open in \(ExternalEditor.remembered?.name ?? "Editor")", systemImage: "doc.text")
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier(
      "files.\(node.isDirectory ? "dir" : "file").\(node.path)"
    )
    .accessibilityLabel(
      node.isDirectory
        ? "\(node.name), folder, \(isExpanded ? "expanded" : "collapsed")"
        : "\(node.name), file, open")
  }

  private func handleTap() {
    if node.isDirectory {
      model.toggle(node)
      lastClick = nil
      return
    }
    if NSEvent.modifierFlags.contains(.command) {
      store.openFileInEditor(path: node.path)  // ⌘-click → external editor, not the in-app viewer
      lastClick = nil
      return
    }
    let now = Date()
    if let last = lastClick, now.timeIntervalSince(last) < 0.35 {
      store.openFilePersistent(path: node.path)  // quick second click → persist
      lastClick = nil
    } else {
      store.openFilePreview(path: node.path)  // eager: show the read-only preview immediately
      lastClick = now
    }
  }
}
