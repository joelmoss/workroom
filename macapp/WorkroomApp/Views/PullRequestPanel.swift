import SwiftUI

/// The "Pull Request" inspector section (issue #24, Phase 2): the pull request for the selected
/// workroom's branch — its state (open/draft/merged/closed), number, title (a link), and review
/// decision. Read-only in this iteration; create/merge/rebase actions come later. Reads
/// `store.selectedTargetID` + `store.workroomStatuses[sid].pr`, which a slow `gh pr list` probe
/// fills on selection (like CI). Covers the same edge states as the Changes panel: nothing
/// selected, a project (non-target), still-probing, and no PR for the branch.
struct PullRequestPanel: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.openURL) private var openURL

  var body: some View {
    Group {
      if let sid = store.selectedTargetID, isStatusable(sid) {
        content(for: sid)
      } else {
        message("Select a workroom to see its pull request.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func isStatusable(_ sid: SidebarID) -> Bool {
    if case .project = sid { return false }
    return true
  }

  @ViewBuilder
  private func content(for sid: SidebarID) -> some View {
    let status = store.workroomStatuses[sid]
    if status?.prCheckedAt == nil {
      message("Checking\u{2026}")
    } else if let pr = status?.pr {
      prDetail(pr)
    } else {
      // Probed, no PR for this branch — the icon-first empty state used across the inspector.
      emptyState("arrow.triangle.branch", "No pull request")
    }
  }

  private func prDetail(_ pr: PullRequestInfo) -> some View {
    let badge = PRPresentation.badge(pr)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: badge.symbol).foregroundStyle(badge.semantic.color)
        Text(badge.label).fontWeight(.medium).foregroundStyle(badge.semantic.color)
        Text("#\(pr.number)").foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .font(.callout)
      Button {
        if let url = URL(string: pr.url) { openURL(url) }
      } label: {
        Text(pr.title)
          .font(.callout)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
          .lineLimit(2).truncationMode(.tail)
      }
      .buttonStyle(.plain)
      .help("Open \(pr.url)")
      if let review = PRPresentation.reviewLabel(pr.reviewDecision) {
        Text(review).font(.footnote).foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func emptyState(_ icon: String, _ text: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon).font(.callout).foregroundStyle(.tertiary)
      Text(text).font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(.body)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
  }
}

extension PRPresentation.Semantic {
  /// Semantic → SwiftUI color for the PR state badge. Mirrors GitHub: open green, merged purple,
  /// closed red, draft a quiet gray.
  var color: Color {
    switch self {
    case .open: return .green
    case .draft: return .secondary
    case .merged: return .purple
    case .closed: return .red
    }
  }
}
