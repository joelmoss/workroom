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

  @State private var state: LoadState = .loading
  /// The file whose diff is shown; defaults to the first changed file once loaded.
  @State private var selectedPath: String?
  private let theme = ThemeService.shared

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
        HSplitView {
          fileList(changeset.files)
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 380)
          diffPane(changeset)
            .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }

  private func load() async {
    state = .loading
    selectedPath = nil
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    let commitID = descriptor.commitID
    do {
      let changeset: VCSChangeset
      if UITestFixture.isActive {
        changeset = try await UITestFixture.vcsProvider.changeset(root: root, commitID: commitID)
      } else {
        // Off the main actor: the providers do blocking work (UniFFI / libgit2).
        changeset = try await Task.detached(priority: .userInitiated) {
          try await VCS.provider(for: root).changeset(root: root, commitID: commitID)
        }.value
      }
      if Task.isCancelled { return }
      state = .loaded(changeset)
      selectedPath = changeset.files.first?.path
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
        .font(.headline).lineLimit(2)
        .foregroundStyle(commit.summary.isEmpty ? .secondary : .primary)
        .textSelection(.enabled)
      HStack(spacing: 10) {
        Label(commit.shortID, systemImage: "number")
          .font(.system(.caption, design: .monospaced))
        if let author = commit.authors.first, !author.name.isEmpty {
          Label(author.name, systemImage: "person")
        }
        Label(Self.dateFormatter.string(from: commit.timestamp), systemImage: "clock")
        if changeset.isMerge {
          Label("Merge", systemImage: "arrow.triangle.merge")
        }
        Spacer(minLength: 0)
        ForEach(commit.refs, id: \.self) { ref in
          Text(ref)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help("Bookmark / branch")
        }
      }
      .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      if let body = Self.messageBody(changeset.fullMessage), !body.isEmpty {
        Text(body)
          .font(.callout).foregroundStyle(.secondary)
          .textSelection(.enabled).lineLimit(8)
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    // The detail's presence marker lives on the header (not the outer container), so it doesn't
    // propagate onto and clobber the `ChangesetFileRow` / `diff.line` leaves in the sibling HSplitView.
    .accessibilityIdentifier("ChangesetDetail")
  }

  /// The commit message minus its first line (the summary already shown), trimmed. `nil` when the
  /// message is a single line.
  private static func messageBody(_ full: String) -> String? {
    let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > 1 else { return nil }
    return lines.dropFirst().joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
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
    return HStack(spacing: 6) {
      Text(Self.badge(file.kind))
        .font(.system(.caption2, design: .monospaced).weight(.bold))
        .foregroundStyle(Self.badgeColor(file.kind))
        .frame(width: 14)
      Text((file.path as NSString).lastPathComponent).lineLimit(1)
      Spacer(minLength: 0)
    }
    .font(.callout)
    .padding(.horizontal, 8).padding(.vertical, 3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
    .contentShape(Rectangle())
    .onTapGesture { selectedPath = file.path }
    .help(file.path)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("ChangesetFileRow")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        directory: directory)
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
