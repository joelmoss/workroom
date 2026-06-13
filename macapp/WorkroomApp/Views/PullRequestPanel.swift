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
      if store.githubCLIStatus != .available {
        // gh can't be used → the PR (and CI) probes can't run; explain why instead of a blank/"no PR".
        ghWarning(store.githubCLIStatus)
      } else if let sid = store.selectedTargetID, isStatusable(sid) {
        content(for: sid)
      } else {
        message("Select a workroom to see its pull request.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Warning shown when `gh` isn't installed or isn't signed in — the GitHub-backed PR/CI data
  /// can't be fetched, so say why and how to fix it rather than silently showing nothing.
  private func ghWarning(_ status: GitHubCLIStatus) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
          .accessibilityHidden(true)
        Text(status == .notInstalled ? "GitHub CLI not found" : "GitHub CLI not signed in")
          .fontWeight(.medium)
        Spacer(minLength: 0)
      }
      .font(.callout)
      Text(
        status == .notInstalled
          ? "Install the gh command-line tool to see pull requests and CI status."
          : "Run \u{201C}gh auth login\u{201D} in a terminal to see pull requests and CI status."
      )
      .font(.footnote).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if status == .notInstalled, let url = URL(string: "https://cli.github.com") {
        Link("Install gh\u{2026}", destination: url).font(.footnote).help("Open cli.github.com")
      }
    }
    .padding(12)
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
    } else if let status, let pr = status.pr {
      prDetail(pr, status: status)
    } else {
      // Probed, no PR for this branch — the icon-first empty state used across the inspector.
      emptyState("arrow.triangle.branch", "No pull request")
    }
  }

  private func prDetail(_ pr: PullRequestInfo, status: WorkroomStatus) -> some View {
    let badge = PRPresentation.badge(pr)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: badge.symbol).foregroundStyle(badge.semantic.color)
        Text(badge.label).fontWeight(.medium).foregroundStyle(badge.semantic.color)
        Text("#\(pr.number)").foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .font(.callout)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(badge.label), pull request #\(pr.number)")
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
      .accessibilityLabel("\(pr.title), open in browser")
      if let review = PRPresentation.reviewLabel(pr.reviewDecision) {
        Text(review).font(.footnote).foregroundStyle(.secondary)
      }
      // CI checks for the PR's branch (GitHub Actions). Reached only when gh is available, so the
      // glyph never contradicts the gh-unavailable warning.
      if let ci = VCSStatusPresentation.ci(status) {
        HStack(spacing: 5) {
          Image(systemName: ci.symbol).foregroundStyle(ci.semantic.color)
          Text(ci.accessibility).foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ci.accessibility)
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
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
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
