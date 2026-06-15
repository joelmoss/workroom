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
      } else if let sid = store.selectedTargetID, sid.isStatusable {
        content(for: sid)
      } else {
        inspectorMessage("Select a workroom to see its pull request.")
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

  @ViewBuilder
  private func content(for sid: SidebarID) -> some View {
    let status = store.workroomStatuses[sid]
    if status?.prCheckedAt == nil {
      inspectorMessage("Checking\u{2026}")
    } else if let status {
      // GitHub status for the branch: the PR (or "no PR") *and* its CI checks, since CI exists for
      // a branch with or without a PR (this is its only home — it's not in the Changes section).
      VStack(alignment: .leading, spacing: 8) {
        if let pr = status.pr {
          prRows(pr)
        } else {
          noPullRequestRow
        }
        if let ci = VCSStatusPresentation.ci(status) {
          ciRow(ci)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func prRows(_ pr: PullRequestInfo) -> some View {
    let badge = PRPresentation.badge(pr)
    // Status + an open-in-browser affordance, linking to the PR. The number lives in the section
    // header badge now, so it's dropped here.
    Button {
      if let url = URL(string: pr.url) { openURL(url) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: badge.symbol).foregroundStyle(badge.semantic.color)
        Text(badge.label).fontWeight(.medium).foregroundStyle(badge.semantic.color)
        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .font(.callout)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Open pull request #\(pr.number) in browser")
    .accessibilityLabel("\(badge.label), pull request #\(pr.number), open in browser")
    Text(pr.title)
      .font(.callout)
      .foregroundStyle(.primary)
      .lineLimit(2).truncationMode(.tail)
    if let review = PRPresentation.reviewLabel(pr.reviewDecision) {
      Text(review).font(.footnote).foregroundStyle(.secondary)
    }
  }

  private var noPullRequestRow: some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.triangle.branch").font(.callout).foregroundStyle(.tertiary)
      Text("No pull request").font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("No pull request")
  }

  private func ciRow(_ ci: VCSStatusPresentation.CIGlyph) -> some View {
    HStack(spacing: 5) {
      Image(systemName: ci.symbol).foregroundStyle(ci.semantic.color)
      Text(ci.accessibility).foregroundStyle(.secondary)
    }
    .font(.callout)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(ci.accessibility)
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
