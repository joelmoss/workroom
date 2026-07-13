import SwiftUI

/// The inspector's **History** section body (issue #59): a newest-first commit log for the selected
/// workroom, read via `VCSProviding` through the store-owned `HistoryModel`. Lives inside the
/// inspector's scroll view, so it renders a flat `VStack` of rows (like `ChangesPanel`/`FilesPanel`)
/// rather than a `List`. Single-click a row opens the commit's `ChangesetDetailView` as a preview
/// content tab; a quick double-click persists it (the same gate the Changes panel uses).
struct HistoryPanel: View {
  @EnvironmentObject var store: AppStore
  private var model: HistoryModel { store.commitHistory }
  private let theme = ThemeService.shared

  var body: some View {
    Group {
      switch model.state {
      case .idle:
        placeholder("Select a workroom", systemImage: "clock")
      case .loading where model.commits.isEmpty:
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Loading history…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
      case .failed(let message):
        placeholder(message, systemImage: "exclamationmark.triangle")
      default:
        if model.commits.isEmpty {
          placeholder("No history", systemImage: "clock")
        } else {
          list
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // No container-level `accessibilityIdentifier` here: SwiftUI propagates a container id onto the
    // combined `HistoryRow` leaves, clobbering their own id. The rows carry "HistoryRow"; that the
    // pane is showing is asserted via `inspector.header.History` (the canonical section marker).
    // Point the model at the selected target — only while History is the active section, so a
    // selection (or another section showing) never loads history you're not looking at. Mirrors
    // FilesPanel; `focus` no-ops when already on the path.
    .task(id: activationKey) {
      guard store.activeInspectorSection == .history else { return }
      model.focus(store.selectedTarget.map { URL(fileURLWithPath: $0.path) })
    }
  }

  private var activationKey: String {
    "\(AppStore.targetIDString(for: store.selectedTargetID) ?? "")"
      + "\u{1F}\(store.activeInspectorSection == .history)"
  }

  /// The changeset tab's title for a commit — its summary, or the short id when it has none.
  private func title(_ commit: VCSCommit) -> String {
    commit.summary.isEmpty ? commit.shortID : commit.summary
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(model.commits) { commit in
        HistoryRow(
          commit: commit,
          onPreview: {
            store.openChangesetPreview(commitID: commit.commitID, title: title(commit))
          },
          onPersist: {
            store.openChangesetPersistent(commitID: commit.commitID, title: title(commit))
          })
      }
      if !model.reachedEnd {
        Button {
          model.loadMore()
        } label: {
          HStack(spacing: 6) {
            if case .loading = model.state {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "arrow.down.circle")
            }
            Text("Load more").font(.callout)
          }
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("HistoryLoadMore")
      }
    }
  }

  private func placeholder(_ text: String, systemImage: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
      Text(text).font(.callout)
    }
    .foregroundStyle(.secondary)
    .padding(.vertical, 6).padding(.horizontal, 8)
  }
}

/// One commit row: first line of the message, then a metadata line (short id · author · relative
/// time) with any bookmark/branch refs, and a `@` marker for the jj working copy.
private struct HistoryRow: View {
  let commit: VCSCommit
  /// Single-click: open the commit's changeset detail as a preview tab. Double-click: persist it.
  let onPreview: () -> Void
  let onPersist: () -> Void
  /// Timestamp of the last plain click, for the manual double-click gate (mirrors `ChangesPanel`).
  @State private var lastClick: Date?

  private static let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        if commit.isWorkingCopy {
          Text("@").font(.system(.body, design: .monospaced)).foregroundStyle(.tint)
            .help("Working copy")
        }
        Text(commit.summary.isEmpty ? "(no description)" : commit.summary)
          .lineLimit(1)
          .foregroundStyle(commit.summary.isEmpty ? .secondary : .primary)
        Spacer(minLength: 4)
        ForEach(commit.refs, id: \.self) { ref in
          Text(ref)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help("Bookmark / branch")
        }
      }
      HStack(spacing: 6) {
        Text(commit.shortID).font(.system(.caption, design: .monospaced))
        if let author = commit.authors.first, !author.name.isEmpty {
          Text("· \(author.name)")
        }
        Text("· \(Self.relative.localizedString(for: commit.timestamp, relativeTo: Date()))")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
    .padding(.vertical, 4).padding(.horizontal, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    // Eager single-click preview, quick second click (< 0.35s) persists — the same manual
    // double-click gate the Changes panel uses (avoids SwiftUI's count:2 delay).
    .onTapGesture {
      let now = Date()
      if let last = lastClick, now.timeIntervalSince(last) < 0.35 {
        onPersist()
        lastClick = nil
      } else {
        onPreview()
        lastClick = now
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("HistoryRow")
  }
}
