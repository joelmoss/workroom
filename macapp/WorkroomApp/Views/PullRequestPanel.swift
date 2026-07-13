import Defaults
import SwiftUI

/// The "Pull Request" inspector section (issue #24, Phase 2): the pull request for the selected
/// workroom's branch — its full (wrapping) title, review decision, per-reviewer rows, and CI
/// checks. The PR's state + number + open-in-browser link live in the section header's number badge
/// (see `RightInspector.prNumberLink`, issue #77), not here. Reads
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
      } else if let sid = store.inspectorTargetID, sid.isStatusable {
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
      // GitHub status for the branch: the PR (or "no PR"), and — only when there's an actual PR —
      // its CI checks: a summary line plus one row per individual check (issue #75). A branch with
      // no PR shows just "No pull request" (no CI rows).
      VStack(alignment: .leading, spacing: 8) {
        if let pr = status.pr {
          readyForReviewButton(pr: pr, sid: sid)
          mergeButton(pr: pr, sid: sid)
          prRows(pr)
          // Summary glyph, tappable → the PR's "/checks" tab. Derived from the loaded per-check list
          // so it can't contradict the rows below; falls back to the branch CI aggregate
          // (`WorkroomStatus.ci`) only before checks have loaded (see `checksSummaryGlyph`).
          if let summary = checksSummaryGlyph(status) {
            ciRow(summary, checksURL: URL(string: pr.url + "/checks"))
          }
          checkRows(status)
        } else {
          noPullRequestRow
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// A draft-only "Ready for Review" shortcut (issue #77), at the top of the panel body above the PR
  /// title (moved out of the section header, where it crowded the title — issue #93 feedback). Gated
  /// on `PRAction.available` so it mirrors the actions menu's own ready action exactly.
  @ViewBuilder
  private func readyForReviewButton(pr: PullRequestInfo, sid: SidebarID) -> some View {
    if PRAction.available(for: pr).contains(.markReady) {
      ReadyForReviewButton(pr: pr, sid: sid)
    }
  }

  /// The split "Merge" button (issue #88), shown at the top of the panel body only when the PR can
  /// actually be merged (`PullRequestInfo.canMerge`). Mutually exclusive with the draft-only Ready
  /// button (a draft can't merge), so the two never stack.
  @ViewBuilder
  private func mergeButton(pr: PullRequestInfo, sid: SidebarID) -> some View {
    if pr.canMerge {
      MergeButton(pr: pr, sid: sid)
    }
  }

  @ViewBuilder
  private func prRows(_ pr: PullRequestInfo) -> some View {
    // Full PR title, wrapping onto as many lines as it needs (issue #77). The PR's state and the
    // open-in-browser link now live in the section-header number badge, so the panel leads with the
    // title rather than repeating a status label/link here.
    Text(pr.title)
      .font(.callout)
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    // Aggregate decision header (issue #52): always shown when GitHub reports one, so a
    // branch-protected PR that's REVIEW_REQUIRED with no named reviewers still shows a signal.
    if let review = PRPresentation.reviewLabel(pr.reviewDecision) {
      Text(review).font(.footnote).foregroundStyle(.secondary)
    }
    // One row per reviewer: state glyph + name + state label (e.g. "Copilot in progress",
    // "iainad approved"). Glyph + label carry the meaning without relying on color. A reviewer who
    // has *submitted* a review carries its permalink, so the whole row is tappable and jumps to their
    // comment (no chevron — the row itself is the tap target).
    ForEach(PRPresentation.reviewers(pr)) { reviewer in
      if let url = reviewer.url.flatMap(URL.init(string:)) {
        Button {
          openURL(url)
        } label: {
          reviewerRow(reviewer)
        }
        .buttonStyle(.plain)
        .help("Open \(reviewer.displayName)\u{2019}s review on GitHub")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reviewer.accessibility), open review on GitHub")
      } else {
        reviewerRow(reviewer)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(reviewer.accessibility)
      }
    }
  }

  /// A single reviewer row: state glyph + name + state label. No open-in-browser chevron — when the
  /// reviewer has a permalink the whole row is the tap target (see the `Button` wrap above).
  private func reviewerRow(_ reviewer: PRPresentation.ReviewerBadge) -> some View {
    HStack(spacing: 6) {
      Image(systemName: reviewer.symbol).foregroundStyle(reviewer.semantic.color)
      Text(reviewer.displayName).font(.footnote).lineLimit(1).truncationMode(.tail)
      Text(reviewer.stateLabel).font(.footnote).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
  }

  /// The summary CI glyph for the panel: derived from the loaded per-check list (so it never
  /// contradicts the rows), falling back to the branch CI aggregate (`WorkroomStatus.ci`) only before checks load.
  /// `checksCheckedAt` is the loaded marker — once set, the (possibly empty) `checks` is authoritative.
  private func checksSummaryGlyph(_ s: WorkroomStatus) -> VCSStatusPresentation.CIGlyph? {
    if s.checksCheckedAt != nil {
      return PRPresentation.checksSummary(s.checks ?? [])
    }
    return VCSStatusPresentation.ci(s)
  }

  @ViewBuilder
  private func checkRows(_ status: WorkroomStatus) -> some View {
    ForEach(PRPresentation.checks(status.checks ?? [])) { check in
      if let url = check.link.flatMap(URL.init(string:)) {
        Button {
          openURL(url)
        } label: {
          checkRow(check)
        }
        .buttonStyle(.plain)
        .help("Open \(check.name) check on GitHub")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.accessibility), open check on GitHub")
      } else {
        checkRow(check)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(check.accessibility)
      }
    }
  }

  /// A single CI-check row: just the status glyph + the check name. The glyph alone carries the
  /// state (the per-state label is redundant), and no open-in-browser chevron — the whole row is the
  /// tap target. VoiceOver still gets the state via the row's `accessibilityLabel`.
  private func checkRow(_ check: PRPresentation.CheckBadge) -> some View {
    HStack(spacing: 6) {
      Image(systemName: check.symbol).foregroundStyle(check.semantic.color)
      Text(check.name).font(.footnote).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
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

  @ViewBuilder
  private func ciRow(_ ci: VCSStatusPresentation.CIGlyph, checksURL: URL?) -> some View {
    if let checksURL {
      // Tappable like the PR status row above — opens the Checks tab in the browser, with the same
      // open-in-browser chevron affordance.
      Button {
        openURL(checksURL)
      } label: {
        HStack(spacing: 5) {
          Image(systemName: ci.symbol).foregroundStyle(ci.semantic.color)
          Text(ci.accessibility).foregroundStyle(.secondary)
          Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .font(.callout)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open CI checks in browser")
      .accessibilityLabel("\(ci.accessibility), open checks in browser")
    } else {
      HStack(spacing: 5) {
        Image(systemName: ci.symbol).foregroundStyle(ci.semantic.color)
        Text(ci.accessibility).foregroundStyle(.secondary)
      }
      .font(.callout)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(ci.accessibility)
    }
  }

}

/// The draft-only "Ready for Review" button (issue #77). A standalone view so it can carry its own
/// `@State` hover, which a `@ViewBuilder` helper can't — the accent capsule deepens on hover.
private struct ReadyForReviewButton: View {
  let pr: PullRequestInfo
  let sid: SidebarID
  @EnvironmentObject var store: AppStore
  @State private var hovering = false

  var body: some View {
    Button {
      store.performPRAction(.markReady, number: pr.number, on: sid)
    } label: {
      Text("Ready for Review")
        .font(.callout).fontWeight(.medium)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .foregroundStyle(Color.accentColor)
        .background(Capsule().fill(Color.accentColor.opacity(hovering ? 0.28 : 0.15)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .disabled(store.prActionInFlight)
    .help("Mark pull request #\(String(pr.number)) ready for review")
    .accessibilityLabel("Ready for review")
  }
}

/// The split "Merge" button (issue #88): the primary area merges with the persisted method; the
/// trailing dropdown picks the method ("Create a merge commit" / "Squash and merge" /
/// "Rebase and merge") and relabels the button. The chosen method is stored globally
/// (`Defaults[.prMergeMethod]`), so it persists across projects and restarts. Merging is
/// outward-facing and effectively irreversible, so the primary click confirms first — matching
/// GitHub's own two-step "Merge → Confirm merge". A standalone view so it can own its `@State`.
///
/// Drawn manually (a green primary `Button` + a chevron `Menu`, joined on one fill) rather than a
/// `Menu(primaryAction:)` with `.buttonStyle(.borderedProminent).tint(.green)`: macOS does NOT
/// honor a prominent/tinted button style on a `.menuStyle(.button)` split menu (it renders the
/// default gray), so the fill has to be ours to guarantee GitHub's green.
private struct MergeButton: View {
  let pr: PullRequestInfo
  let sid: SidebarID
  @EnvironmentObject var store: AppStore
  @Default(.prMergeMethod) private var method
  @State private var confirming = false
  @State private var hovering = false

  private let corner: CGFloat = 5

  var body: some View {
    HStack(spacing: 0) {
      // Primary: merge with the current method (confirms first).
      Button {
        confirming = true
      } label: {
        Text(method.buttonLabel)
          .font(.caption).fontWeight(.medium)
          .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 3)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Merge pull request #\(String(pr.number)) (\(method.buttonLabel))")
      .accessibilityLabel("\(method.buttonLabel), pull request #\(String(pr.number))")

      // Hairline divider between the two halves (GitHub's split seam).
      Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1).padding(.vertical, 3)

      // Dropdown: pick the merge method (relabels the button; persists globally).
      Menu {
        ForEach(PRMergeMethod.allCases, id: \.self) { option in
          Button {
            method = option
          } label: {
            // A checkmark marks the current selection (GitHub's menu convention). SwiftUI omits the
            // symbol space for unselected rows, so their labels align under the checked one.
            if option == method {
              Label(option.menuLabel, systemImage: "checkmark")
            } else {
              Text(option.menuLabel)
            }
          }
        }
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .padding(.horizontal, 6).padding(.vertical, 4)
          .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Choose merge method")
      .accessibilityLabel("Choose merge method")
    }
    .foregroundStyle(.white)
    .background(
      RoundedRectangle(cornerRadius: corner)
        .fill(Color.green.opacity(hovering ? 1 : 0.9))
    )
    .fixedSize()
    .onHover { hovering = $0 }
    .disabled(store.prActionInFlight)
    .opacity(store.prActionInFlight ? 0.5 : 1)
    .confirmationDialog(
      "\(method.buttonLabel)?", isPresented: $confirming, titleVisibility: .visible
    ) {
      Button(method.buttonLabel) {
        store.performMerge(method, number: pr.number, on: sid)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This merges pull request #\(String(pr.number)) into its base branch on GitHub.")
    }
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

extension PRPresentation.ReviewSemantic {
  /// Semantic → SwiftUI color for a per-reviewer row glyph. Mirrors GitHub: approved green,
  /// changes-requested red, pending amber; commented/dismissed stay quiet (the glyph carries it).
  var color: Color {
    switch self {
    case .approved: return .green
    case .changesRequested: return .red
    case .requested: return .orange
    case .commented: return .secondary
    case .dismissed: return .secondary
    }
  }
}

extension PRPresentation.CheckSemantic {
  /// Semantic → SwiftUI color for a per-check row glyph. Mirrors GitHub: passing green, failing red,
  /// pending amber; skipped/cancelled stay quiet (the glyph carries it). Plain colors (like the
  /// reviewer rows), so the two row kinds read consistently.
  var color: Color {
    switch self {
    case .passing: return .green
    case .failing: return .red
    case .pending: return .orange
    case .skipped: return .secondary
    case .cancelled: return .secondary
    }
  }
}
