import DesignSystem
import SwiftUI

/// The inspector's **Files** section body: the selected repo's working tree as a collapsible,
/// indented list (it lives inside the inspector's own scroll view, so it flattens the tree to rows
/// itself rather than hosting a `List`/`OutlineGroup`). A single click on a file opens it read-only
/// in the main pane (preview), a quick second click persists it, and ⌘-click opens it in the
/// external editor — mirroring the Changes panel. Directory rows toggle expansion.
///
/// For a folder a terminal's inspector follows (#809) the tree is rooted at that folder, and a
/// breadcrumb pinned above it (`FilesBreadcrumbBar`) walks from its repository's root, or `~`, down
/// to it. The pane hosts this body in fill mode, so the list scrolls under the breadcrumb.
struct FilesPanel: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var model: FileTreeModel
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    let breadcrumb = store.filesBreadcrumb
    VStack(spacing: 0) {
      if let breadcrumb {
        FilesBreadcrumbBar(breadcrumb: breadcrumb) { store.browseFiles(toSegment: $0) }
      }
      content(followed: breadcrumb != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    // Fill the pane (hosted in fill mode) so the list's own `ScrollView` has a bounded height.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    // Point the tree at the inspector's subject (nothing once all its tabs close → the tree
    // clears), only while Files is the active activity-bar section. Re-runs on either change, and
    // for a followed folder on every folder change and breadcrumb browse; `activate` no-ops when
    // already on a local path, so re-selecting the same target is instant; a remote tree has no
    // watcher, so it is listed again. While Files isn't shown (another section, or the inspector
    // hidden, which unmounts this) the tree stops watching, and it catches up once on its return.
    .task(id: activationKey) {
      guard store.activeInspectorSection == .files else { return model.pause() }
      store.activateFileTree()
      model.resume()
    }
    .onDisappear { model.pause() }
  }

  /// The section's loader: while the tree lists, and once a followed folder's repository has been
  /// pending a moment.
  private var listingIndicator: some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.small)
      Text("Listing files…").font(.callout).foregroundStyle(.secondary)
    }
    .padding(.vertical, 6).padding(.horizontal, 8)
    .help("Listing files")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Listing files")
  }

  @ViewBuilder private func content(followed: Bool) -> some View {
    Group {
      if case .followed(let followed) = store.inspectorSubject, followed.repositoryPending {
        // The folder's repository is still resolving, which decides how it lists: wait rather
        // than list it twice. Blank at first, so a fast answer never flashes a loader, then the
        // section's own loader.
        if store.followedFolderLoaderShown {
          listingIndicator.accessibilityIdentifier(pendingRepositoryLoaderID)
        } else {
          EmptyView()
        }
      } else if store.inspectorSubject == .nothing {
        // No active workspace (nothing selected, or the selected workroom has no open tabs) — empty
        // out to match the detail pane's "No terminal" state rather than list a stale workroom.
        InlineMessage("No open terminal", systemImage: "folder")
      } else {
        switch model.state {
        case .idle:
          InlineMessage(
            followed ? "No open terminal" : "No workroom selected", systemImage: "folder")
        case .loading:
          listingIndicator
        case .failed(let message):
          InlineMessage(message, systemImage: "exclamationmark.triangle")
        case .unavailable:
          // A followed folder lists with or without a repository, so for one this means the
          // folder is gone or unreadable.
          InlineMessage(
            followed ? "Folder unavailable" : "Not a repository",
            systemImage: "folder.badge.questionmark")
        case .loaded:
          if model.roots.isEmpty {
            InlineMessage(followed ? "Empty folder" : "No files", systemImage: "folder")
          } else {
            ScrollView { fileList }
              .inspectorScrollMemory(
                key: store.inspectorMemoryKey(for: .files), in: store.inspectorScrollMemory)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var activationKey: FilesActivation { store.filesActivationKey }

  /// `LazyVStack`, not `VStack`: rows are fixed-height (single-line, truncated — no soft-wrap, unlike
  /// `DiffViewer`'s lines, where lazy would cache a wrong estimate for a not-yet-materialized wrapping
  /// row — see that type's doc for when lazy is wrong), and this already lives inside the inspector's
  /// own `ScrollView` (see the type doc), which is what makes a `LazyVStack` here lazy at all instead
  /// of behaving like `VStack` with no viewport to bound against.
  private var fileList: some View {
    let rows = model.rows
    // Once per list, not per row: resolving the target can stat its directory. A followed folder
    // is always this Mac's.
    let canOpenInEditor =
      store.filesFileRoot != nil || store.inspectorTarget?.isMissing == false
    let capped = Array(rows.prefix(FileTreeModel.renderCap))
    return LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(capped, id: \.node.path) { row in
        FileTreeRowView(
          row: row, isExpanded: model.expanded.contains(row.node.path),
          onToggle: { model.toggle(row.node) },
          onOpenPreview: { store.openFilePreview(path: row.node.path) },
          onOpenPersistent: { store.openFilePersistent(path: row.node.path) },
          onOpenInEditor: { store.openFileInEditor(path: row.node.path) },
          canOpenInEditor: canOpenInEditor
        )
        .equatable()
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
}

/// One row of the Files tree: an indented directory (with a disclosure chevron) or file. Its own
/// view so hover + the click-timing state stay per-row.
///
/// Deliberately `internal`, not `private` (same reason `HistoryRow`/`ChangedFileRow` are): this WAS a
/// WORKROOM-2B eager-stack-plus-per-row-observation candidate (`FilesPanelInvalidationTests` proved it
/// — an unrelated `AppStore` publish rebuilt all 200 visible rows), fixed the same way those two were:
/// no `@EnvironmentObject`/`@ObservedObject` here at all. `FilesPanel` hoists `isExpanded` out of
/// `FileTreeModel` and passes plain closures for the store-dependent actions, so this row observes
/// NOTHING and `.equatable()` at the call site actually has something to gate on.
struct FileTreeRowView: View, Equatable {
  let row: FileTreeRow
  let isExpanded: Bool
  let onToggle: () -> Void
  let onOpenPreview: () -> Void
  let onOpenPersistent: () -> Void
  let onOpenInEditor: () -> Void
  /// False for a target whose files aren't on this Mac, such as a remote workroom's.
  let canOpenInEditor: Bool
  @State private var hovering = false
  @Environment(\.themeTokens) private var tokens

  private var node: FileNode { row.node }

  /// The closures are excluded (same reasoning as `HistoryRow.open`): `FilesPanel` builds them from
  /// `[store, row.node]`, so two rows differing only in closure identity are behaviourally identical.
  nonisolated static func == (lhs: FileTreeRowView, rhs: FileTreeRowView) -> Bool {
    lhs.row == rhs.row && lhs.isExpanded == rhs.isExpanded
      && lhs.canOpenInEditor == rhs.canOpenInEditor
  }

  #if DEBUG
    /// How many times ANY row's body has been evaluated this process — the measurement behind
    /// `FilesPanelInvalidationTests` (WORKROOM-2B follow-up). Debug-only.
    static var bodyPasses = 0
  #endif

  var body: some View {
    #if DEBUG
      Self.bodyPasses += 1
    #endif
    return HStack(spacing: 4) {
      Color.clear.frame(width: CGFloat(row.depth) * 13, height: 1)
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .frame(width: 10)
        .opacity(node.isDirectory ? 1 : 0)
      Image(systemName: node.isDirectory ? "folder" : "doc")
        .font(.system(size: 11))
        .foregroundStyle(node.isDirectory ? tokens.accent : tokens.fgMuted)
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
        .fill(hovering ? tokens.rowHover : .clear)
        .padding(.horizontal, -12)
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { handleTap() }
    .help(node.isDirectory ? node.path : "Open \(node.path)")
    .contextMenu {
      if !node.isDirectory, canOpenInEditor {
        Button {
          onOpenInEditor()
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
      onToggle()
      return
    }
    if NSEvent.modifierFlags.contains(.command) {
      onOpenInEditor()  // ⌘-click → external editor, not the in-app viewer
      return
    }
    // Eager: the first click shows the read-only preview immediately; a double-click's second click
    // persists it (the `RepeatClick` gate the Changes panel uses).
    if RepeatClick.isCurrentRepeat { onOpenPersistent() } else { onOpenPreview() }
  }
}
