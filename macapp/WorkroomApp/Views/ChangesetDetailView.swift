import SwiftUI

/// The changeset (commit detail) content tab (issue #59): a whole commit's metadata, its changed-file
/// list, and the selected file's diff. Read through `VCSProviding.changeset`; the per-file diff reuses
/// the unmodified `DiffViewer` with a `.commit(id)` source, so it inherits the whole diff-rendering +
/// view-mode stack with no new view code. Single-click a file in the list to view its diff — the list
/// retargets local `@State` and the viewer re-fetches (cancelling the prior load).
struct ChangesetDetailView: View {
  let descriptor: ChangesetDescriptor
  /// The workroom directory the VCS reads in.
  let directory: String
  /// This changeset tab's id + target — so a file tap routes through the store (which records a
  /// back/forward step and updates the tab), rather than a view-local `@State`.
  let tabID: TerminalTab.ID
  let target: TerminalTarget
  @EnvironmentObject var store: AppStore

  @State private var state: LoadState = .loading
  /// Committed width of the file-list pane. Starts intentionally narrow.
  @State private var listWidth: CGFloat = 230
  /// Live width during a divider drag (`nil` when not dragging). Kept in local `@State` so the drag
  /// re-renders only this view; committed to `listWidth` on release.
  @State private var liveWidth: CGFloat?
  /// The width to render right now — the live drag value if dragging, else the committed one.
  private var effectiveListWidth: CGFloat { liveWidth ?? listWidth }
  /// The file whose diff is shown — the tab descriptor's selection (so it's restorable via
  /// back/forward and persists across renders), falling back to the first changed file.
  private var selectedPath: String? {
    if let path = descriptor.selectedPath { return path }
    if case .loaded(let changeset) = state { return changeset.files.first?.path }
    return nil
  }
  /// The diff header's unified/side-by-side choice for this changeset (nil ⇒ follow the global
  /// default). Held here so it persists as the user clicks between files; doesn't touch the global.
  @State private var diffMode: DiffViewMode?
  /// Commit-description disclosure: collapsed shows 2 lines; expanded shows all. The summary is
  /// always shown in full — only the body below it collapses.
  @State private var descriptionExpanded = false
  /// True when the description body doesn't fit in 2 lines (so the Show more/less toggle is offered).
  @State private var descriptionTruncatable = false
  /// The file-list row under the pointer, for its hover highlight.
  @State private var hoveredPath: String?
  private let theme = ThemeService.shared

  private static let minListWidth: CGFloat = 180
  private static let maxListWidth: CGFloat = 400

  enum LoadState: Equatable {
    case loading
    case loaded(VCSChangeset)
    case failed(String)
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(theme.tokens.bg)
      // Fetch on appear + whenever the tab is retargeted to another commit (preview reuse).
      .task(id: descriptor.commitID) { await load() }
  }

  @ViewBuilder private var content: some View {
    switch state {
    case .loading:
      ProgressView().controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    case .failed(let reason):
      message("Changeset unavailable", systemImage: "exclamationmark.triangle", detail: reason)
    case .loaded(let changeset):
      loaded(changeset)
    }
  }

  private func loaded(_ changeset: VCSChangeset) -> some View {
    VStack(spacing: 0) {
      header(changeset)
      Divider()
      if changeset.files.isEmpty {
        message("No file changes", systemImage: "doc", detail: nil)
      } else {
        // A hand-rolled split (not `HSplitView`) so the divider shows a reliable resize cursor and
        // the list starts narrow. Live resize is driven by the AppKit `InspectorResizeHandle` (the
        // same smooth, cursor-bearing handle the sidebar/inspector use), not a SwiftUI gesture.
        HStack(spacing: 0) {
          fileList(changeset.files)
            .frame(width: effectiveListWidth)
          resizeHandle
          diffPane(changeset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }

  private func load() async {
    state = .loading
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    let commitID = descriptor.commitID
    do {
      let changeset: VCSChangeset
      if UITestFixture.isActive {
        changeset = try await UITestFixture.vcsProvider.changeset(root: root, commitID: commitID)
      } else {
        // The provider self-offloads its blocking read to GCD (`runBlocking`), so a plain await here
        // stays off the cooperative pool — no `Task.detached` wrapper needed.
        changeset = try await VCS.provider(for: root).changeset(root: root, commitID: commitID)
      }
      if Task.isCancelled { return }
      state = .loaded(changeset)
    } catch {
      if Task.isCancelled { return }
      state = .failed("\(error)")
    }
  }

  // MARK: Header

  private func header(_ changeset: VCSChangeset) -> some View {
    let commit = changeset.commit
    return VStack(alignment: .leading, spacing: 5) {
      Text(commit.summary.isEmpty ? "(no description)" : commit.summary)
        .font(.headline)
        .foregroundStyle(commit.summary.isEmpty ? .secondary : .primary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        // Identity, styled like the Changes panel header: change-id (purple, jj only) + commit-id
        // (blue), monospaced — rather than a `#`-prefixed short id — so it reads the same in both.
        if let changeID = commit.changeID {
          Text(changeID)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.purple)
            .help("Change ID")
        }
        Text(commit.shortID)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.blue)
          .help("Commit ID")
        // Bookmarks/branches, as the same gray capsules the History list rows use, and in the same
        // reading order as the identity that precedes them — left of the author rather than pushed to
        // the far right, so a commit's refs sit beside the ids they belong to in both surfaces.
        ForEach(commit.refs, id: \.self) { ref in
          Text(ref)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help("Bookmark / branch")
        }
        if !commit.authorNamesDisplay.isEmpty {
          Label {
            Text(commit.authorNamesDisplay)
          } icon: {
            AvatarStack(
              subjects: commit.authors.map { AvatarSubject(author: $0, pixelSize: 48) }, size: 16)
          }
        }
        Label(Self.dateFormatter.string(from: commit.timestamp), systemImage: "clock")
        if changeset.isMerge {
          Label("Merge", systemImage: "arrow.triangle.merge")
        }
        diffStat(changeset)
        if commit.showsUnpushedBadge {
          // Made its own accessibility element so the header container's `ChangesetDetail` id (below)
          // can't swallow it — a container id propagates onto child leaves, and an XCUITest query for
          // this marker found nothing until it became a leaf in its own right.
          Label("Not pushed", systemImage: "arrow.up")
            .foregroundStyle(theme.tokens.warning)
            .help(VCSPushScope.unpushedHelp(changeset.pushScope))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Not pushed")
            .accessibilityIdentifier("ChangesetDetailUnpushed")
        }
        Spacer(minLength: 0)
      }
      .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      if let body = Self.messageBody(changeset.fullMessage), !body.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          Text(body)
            .font(.callout).foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(descriptionExpanded ? nil : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(descriptionTruncationProbe(body))
            .onPreferenceChange(DescriptionTruncationKey.self) { descriptionTruncatable = $0 }
            .animation(.easeInOut(duration: 0.12), value: descriptionExpanded)
          if descriptionTruncatable {
            Button(descriptionExpanded ? "Show less" : "Show more") {
              descriptionExpanded.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(.tint)
            .help(descriptionExpanded ? "Collapse the description" : "Show the full description")
          }
        }
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    // The detail's presence marker lives on the header (not the outer container), so it doesn't
    // propagate onto and clobber the `ChangesetFileRow` / `diff.line` leaves in the sibling HSplitView.
    .accessibilityIdentifier("ChangesetDetail")
  }

  /// The changeset's `+N −M` line-count summary, coloured like the diff gutter (green add / red
  /// remove). Rendered only when the backend resolved counts (`insertions`/`deletions` non-nil) — an
  /// unresolved changeset simply omits it rather than showing a misleading `+0 −0`.
  @ViewBuilder private func diffStat(_ changeset: VCSChangeset) -> some View {
    if let insertions = changeset.insertions, let deletions = changeset.deletions {
      HStack(spacing: 5) {
        Text("+\(insertions)").foregroundStyle(theme.tokens.diffAddFg)
        Text("−\(deletions)").foregroundStyle(theme.tokens.diffRemoveFg)
      }
      .font(.system(.caption, design: .monospaced))
      // Combine the +/- into one element with a spoken label. No a11y identifier: the header's
      // `ChangesetDetail` id absorbs its descendant leaves (see the header note), so this element's
      // own id wouldn't survive — its label still merges into the header's, which the UITest matches.
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(insertions) insertions, \(deletions) deletions")
      .help("\(insertions) insertions, \(deletions) deletions")
    }
  }

  /// The commit message minus its first line (the summary already shown), trimmed. `nil` when the
  /// message is a single line.
  private static func messageBody(_ full: String) -> String? {
    let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > 1 else { return nil }
    return lines.dropFirst().joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A hidden two-copy measure of the description at the body's width — a 2-line-capped copy vs an
  /// unlimited copy — reporting `DescriptionTruncationKey = true` when the full text is taller. It
  /// measures both cap and full regardless of the current expansion, so the toggle survives expand.
  private func descriptionTruncationProbe(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .lineLimit(2)
      .hidden()
      .overlay(
        GeometryReader { twoLine in
          Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: twoLine.size.width, alignment: .leading)
            .hidden()
            .background(
              GeometryReader { full in
                Color.clear.preference(
                  key: DescriptionTruncationKey.self,
                  value: full.size.height > twoLine.size.height + 1)
              })
        }
      )
      .allowsHitTesting(false)
  }

  // MARK: File list

  private func fileList(_ files: [VCSChangedFile]) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(files) { file in
          fileRow(file)
        }
      }
      .padding(.vertical, 4)
    }
    .accessibilityIdentifier("ChangesetFileList")
  }

  private func fileRow(_ file: VCSChangedFile) -> some View {
    let isSelected = (selectedPath ?? "") == file.path
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(Self.badge(file.kind))
        .font(.system(.caption2, design: .monospaced).weight(.bold))
        .foregroundStyle(Self.badgeColor(file.kind))
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 1) {
        // File name on top, the full relative path dimmed beneath it — so a row reads even when the
        // list is narrow. The path truncates from the middle, keeping the leading dirs + the name.
        // A moved file's line reads `old → new`: the two paths are one row, so this is the only place
        // the rename is visible at all.
        Text((file.path as NSString).lastPathComponent)
          .lineLimit(1).truncationMode(.middle)
        Text(ChangeBadge.pathLine(path: file.path, oldPath: file.oldPath))
          .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
    .font(.callout)
    .padding(.horizontal, 8).padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected
        ? Color.accentColor.opacity(0.18)
        : (hoveredPath == file.path ? theme.tokens.rowHover : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { inside in
      if inside {
        hoveredPath = file.path
      } else if hoveredPath == file.path {
        hoveredPath = nil
      }
    }
    .onTapGesture { store.selectChangesetFile(file.path, tab: tabID, in: target) }
    .help(ChangeBadge.pathLine(path: file.path, oldPath: file.oldPath))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("ChangesetFileRow")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// The draggable divider between the file list and the diff: a 1pt visible line with a 10pt AppKit
  /// hit strip (`InspectorResizeHandle`) overlaid. The handle drives a LIVE resize — each mouse-moved
  /// delta updates `liveWidth` so both panes track the cursor — and shows a reliable resize cursor
  /// (`addCursorRect`). This is the same AppKit-backed handle the sidebar/inspector use, so it's as
  /// smooth as those; a SwiftUI `DragGesture` here was janky. The width commits to `listWidth` on end.
  private var resizeHandle: some View {
    Rectangle()
      .fill(theme.tokens.border)
      .frame(width: 1)
      .frame(maxHeight: .infinity)
      .overlay {
        InspectorResizeHandle(
          onDrag: { dx in
            liveWidth = min(
              max(effectiveListWidth + dx, Self.minListWidth), Self.maxListWidth)
          },
          onEnd: {
            if let final = liveWidth {
              listWidth = final
              liveWidth = nil
            }
          }
        )
        .frame(width: 10)
        // The AppKit handle's `addCursorRect` doesn't fire reliably outside an NSSplitView context,
        // so drive the resize cursor at the SwiftUI layer too (the AppKit view still handles drags).
        .pointerStyle(.columnResize)
      }
      .accessibilityHidden(true)
  }

  // MARK: Diff

  @ViewBuilder private func diffPane(_ changeset: VCSChangeset) -> some View {
    if let path = selectedPath ?? changeset.files.first?.path,
      let file = changeset.files.first(where: { $0.path == path })
    {
      // Reuse the diff viewer unchanged: a `.commit` source routes through VCSProviding.fileDiff.
      // Retargeting `selectedPath` hands it a new descriptor; its own `.task(id:)` cancels the prior
      // load and re-fetches, so no bespoke cancellation is needed here.
      DiffViewer(
        descriptor: DiffDescriptor(
          path: file.path, change: Self.change(file.kind),
          source: .commit(descriptor.commitID), isPreview: false),
        directory: directory,
        // Always `.commit(...)` here, never `.jjWorkingCopy` — this pane never snapshots, so no
        // project root is needed to key `JJSnapshotGate`.
        projectRoot: nil,
        showsFileHeader: true,
        headerModeBinding: $diffMode)
    } else {
      message("Select a file", systemImage: "sidebar.left", detail: nil)
    }
  }

  // MARK: Empty / error state

  private func message(_ title: String, systemImage: String, detail: String?) -> some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage).font(.title2).foregroundStyle(.tertiary)
      Text(title).font(.callout).foregroundStyle(.secondary)
      if let detail, !detail.isEmpty {
        Text(detail).font(.footnote).foregroundStyle(.tertiary)
          .multilineTextAlignment(.center).lineLimit(3)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  // MARK: Change-kind styling

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  private static func badge(_ kind: VCSChangeKind) -> String {
    switch kind {
    case .added: return "A"
    case .modified: return "M"
    case .deleted: return "D"
    case .renamed: return "R"
    case .copied: return "C"
    case .conflicted: return "!"
    case .other: return "•"
    }
  }

  private static func badgeColor(_ kind: VCSChangeKind) -> Color {
    switch kind {
    case .added: return .green
    case .modified: return .yellow
    case .deleted: return .red
    case .renamed, .copied: return .blue
    case .conflicted: return .orange
    case .other: return .secondary
    }
  }

  /// Map the app-native change kind onto the `DiffDescriptor.change` the viewer expects. Unused for a
  /// `.commit` diff (which routes through the backend regardless), but kept exact for clarity.
  private static func change(_ kind: VCSChangeKind) -> ChangedFile.Change {
    switch kind {
    case .added: return .added
    case .modified: return .modified
    case .deleted: return .deleted
    case .renamed, .copied: return .renamed
    case .conflicted: return .conflicted
    case .other: return .other
    }
  }
}

/// True when the changeset description body overflows its collapsed 2-line height (⇒ offer expand).
private struct DescriptionTruncationKey: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
