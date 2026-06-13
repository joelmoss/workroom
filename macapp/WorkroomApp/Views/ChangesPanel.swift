import SwiftUI

/// The right inspector (issue #24). macOS 14 supports only one `.inspector` per view, so the
/// inspector composes two collapsible sections — **Changes** (the selected workroom's VCS
/// detail) on top, **Notifications** (the existing session history) below — rather than two
/// inspectors. The toolbar bell toggles the whole inspector; each section's disclosure handles
/// its own visibility (persisted). The Clear-notifications action rides the inspector toolbar.
struct RightInspector: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  /// A PR action awaiting confirmation (close), surfaced via a confirmation dialog.
  @State private var pendingConfirm: PendingPRAction?

  var body: some View {
    // Each section owns its action in its own header (issue #24 feedback): Refresh in Changes,
    // Clear in Notifications. Collapse state lives on `store` (not `@Default`) so toggling it
    // reliably re-renders this inspector content — see AppStore.
    VStack(spacing: 0) {  // sections are flush; a 1px rule separates them
      InspectorSection(
        title: "Changes", collapsed: $store.changesSectionCollapsed, indicator: changesIndicator,
        indicatorLabel: changesIndicatorLabel
      ) {
        InspectorHeaderButton(systemImage: "arrow.clockwise", help: "Refresh workroom status") {
          store.refreshWorkroomStatuses(force: true)
        }
      } content: {
        ChangesPanel()
      }
      sectionRule
      InspectorSection(
        title: "Pull Request", collapsed: $store.prSectionCollapsed, indicator: prIndicator,
        indicatorLabel: prIndicatorLabel
      ) {
        prActionsMenu
      } content: {
        PullRequestPanel()
      }
      sectionRule
      InspectorSection(
        title: "Notifications", collapsed: $store.notificationsSectionCollapsed, fill: true,
        indicator: notificationsIndicator, indicatorLabel: notificationsIndicatorLabel
      ) {
        InspectorHeaderButton(
          systemImage: "trash", help: "Clear notifications", destructive: true,
          disabled: notifications.items.isEmpty
        ) {
          notifications.clear()
        }
      } content: {
        NotificationsList()
      }
    }
    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .confirmationDialog(
      pendingConfirm.map { "\($0.action.label)?" } ?? "",
      isPresented: Binding(
        get: { pendingConfirm != nil }, set: { if !$0 { pendingConfirm = nil } }),
      presenting: pendingConfirm
    ) { item in
      Button(item.action.label, role: .destructive) {
        store.performPRAction(item.action, number: item.number, on: item.sid)
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  /// The PR write-actions menu (Phase 2b), shown in the Pull Request header. State-dependent
  /// (ready/draft, close, reopen); destructive actions route through a confirmation dialog.
  @ViewBuilder private var prActionsMenu: some View {
    if store.githubCLIStatus == .available, let pr = selectedStatus?.pr,
      let sid = store.selectedTargetID, !PRAction.available(for: pr).isEmpty
    {
      Menu {
        ForEach(PRAction.available(for: pr), id: \.self) { action in
          Button(role: action.isDestructive ? .destructive : nil) {
            if action.needsConfirmation {
              pendingConfirm = PendingPRAction(action: action, number: pr.number, sid: sid)
            } else {
              store.performPRAction(action, number: pr.number, on: sid)
            }
          } label: {
            Label(action.label, systemImage: action.systemImage)
          }
        }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .disabled(store.prActionInFlight)
      .help("Pull request actions")
      .accessibilityLabel("Pull request actions")
    }
  }

  /// A 1px rule between sections so adjacent (especially collapsed) header bars stay separated.
  private var sectionRule: some View {
    Color.primary.opacity(0.15).frame(height: 1)
  }

  /// The selected workroom's status, or nil when a non-target (project) or nothing is selected —
  /// drives the header indicators so a collapsed section still shows state.
  private var selectedStatus: WorkroomStatus? {
    guard let sid = store.selectedTargetID else { return nil }
    if case .project = sid { return nil }
    return store.workroomStatuses[sid]
  }

  /// Changes header indicator: the working-tree line counts (`+N` green / `-M` red) when there's a
  /// delta; otherwise the status dot (untracked-only dirty, conflict, or unknown); nothing if clean.
  private var changesIndicator: AnyView {
    guard let s = selectedStatus else { return AnyView(EmptyView()) }
    let ins = s.insertions ?? 0
    let del = s.deletions ?? 0
    if ins > 0 || del > 0 {
      var help = ""
      if s.conflicted { help += "conflicted, " }
      help += "\(ins) insertions, \(del) deletions"
      return AnyView(
        HStack(spacing: 5) {
          if s.conflicted {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 9)).foregroundStyle(Color.red)
          }
          if ins > 0 { Text("+\(ins)").foregroundStyle(.green) }
          if del > 0 { Text("-\(del)").foregroundStyle(.red) }
        }
        .font(.caption).monospacedDigit()
        .help(help))
    }
    guard let dot = VCSStatusPresentation.dot(s) else { return AnyView(EmptyView()) }
    return AnyView(
      Image(systemName: dot.symbol).font(.system(size: 9)).foregroundStyle(dot.semantic.color)
        .help(dot.accessibility))
  }

  /// Pull Request header badge: the PR number in a pill tinted by the PR state (open/draft/merged/
  /// closed). Nothing when there's no PR or gh is unavailable.
  private var prIndicator: AnyView {
    guard store.githubCLIStatus == .available, let pr = selectedStatus?.pr else {
      return AnyView(EmptyView())
    }
    let badge = PRPresentation.badge(pr)
    // Status color as text on a subtle tint of itself (GitHub-label style) — white-on-color was
    // illegible on the light states (e.g. green). Readable across open/draft/merged/closed.
    return AnyView(
      Text("#\(pr.number)")
        .font(.caption2).fontWeight(.semibold).monospacedDigit()
        .foregroundStyle(badge.semantic.color)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(badge.semantic.color.opacity(0.22)))
        .help("Pull request #\(pr.number): \(badge.label)"))
  }

  /// Notifications header count badge, with a tooltip.
  private var notificationsIndicator: AnyView {
    let count = notifications.items.count
    return AnyView(
      UnreadBadge(count: count)
        .help(count == 1 ? "1 notification" : "\(count) notifications"))
  }

  // VoiceOver text for each header indicator (the visual badge can't be read through the collapse
  // button's own label), appended to the section's accessibility label.

  private var changesIndicatorLabel: String {
    guard let s = selectedStatus else { return "" }
    let ins = s.insertions ?? 0
    let del = s.deletions ?? 0
    if ins > 0 || del > 0 {
      return (s.conflicted ? "conflicted, " : "") + "\(ins) insertions, \(del) deletions"
    }
    return VCSStatusPresentation.dot(s)?.accessibility ?? ""
  }

  private var prIndicatorLabel: String {
    guard store.githubCLIStatus == .available, let pr = selectedStatus?.pr else { return "" }
    return "pull request #\(pr.number), \(PRPresentation.badge(pr).label)"
  }

  private var notificationsIndicatorLabel: String {
    let count = notifications.items.count
    if count == 0 { return "" }
    return count == 1 ? "1 notification" : "\(count) notifications"
  }
}

/// A PR action awaiting user confirmation (the close action), carried by the confirmation dialog.
private struct PendingPRAction: Identifiable {
  let action: PRAction
  let number: Int
  let sid: SidebarID
  var id: String { "\(action.rawValue)-\(number)" }
}

/// One changed-file row: a colored change-kind letter (M/A/D/…), the filename, then its parent
/// directory dimmed (issue #24 feedback). Clicking opens the file in the configured app (Settings →
/// "Open file paths in"; falls back to the file's default app), resolving the repo-relative path
/// against the workroom directory. The directory yields first when space is tight (truncates from
/// the head). The change kind is spelled out in the accessibility label so it isn't color-only.
private struct ChangedFileRow: View {
  let file: ChangedFile
  /// The workroom directory the repo-relative `file.path` is resolved against. `nil` ⇒ not openable.
  let directory: String?
  @State private var hovering = false

  var body: some View {
    let (dir, name) = ChangesPanel.splitPath(file.path)
    Button {
      if let directory { TerminalLinkOpener.handleCmdClickFile(file.path, cwd: directory) }
    } label: {
      HStack(spacing: 6) {
        Text(letter)
          .font(.system(.callout, design: .monospaced))
          .foregroundStyle(color)
          .frame(width: 14, alignment: .leading)
        Text(name)
          .font(.callout)
          .lineLimit(1).truncationMode(.middle)
          .layoutPriority(1)
        if !dir.isEmpty {
          Text(dir)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.head)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 2)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(Color.primary.opacity(hovering && directory != nil ? 0.08 : 0))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .disabled(directory == nil)
    .help(directory == nil ? "" : "Open \(file.path)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      dir.isEmpty
        ? "\(name), \(changeWord), open" : "\(name), \(changeWord), in \(dir), open")
  }

  private var letter: String {
    switch file.change {
    case .modified: return "M"
    case .added: return "A"
    case .deleted: return "D"
    case .renamed: return "R"
    case .untracked: return "?"
    case .conflicted: return "C"
    case .other: return "\u{2022}"
    }
  }

  private var color: Color {
    switch file.change {
    case .added: return .green
    case .deleted: return .red
    case .conflicted: return .red
    case .modified, .renamed: return .orange
    case .untracked, .other: return .secondary
    }
  }

  private var changeWord: String {
    switch file.change {
    case .modified: return "modified"
    case .added: return "added"
    case .deleted: return "deleted"
    case .renamed: return "renamed"
    case .untracked: return "untracked"
    case .conflicted: return "conflicted"
    case .other: return "changed"
    }
  }
}

/// A collapsible section header + body for the composed inspector. `fill: true` makes the
/// expanded body grab the remaining vertical space (used by Notifications so its list fills
/// below the intrinsic-height Changes section).
struct InspectorSection<Accessory: View, Content: View>: View {
  let title: String
  @Binding var collapsed: Bool
  var fill: Bool = false
  /// A small status indicator shown right after the title (a dot / count badge), so a *collapsed*
  /// section still conveys its state. Non-interactive, so it rides inside the collapse button.
  var indicator: AnyView = AnyView(EmptyView())
  /// VoiceOver text for `indicator` — appended to the header's accessibility label, since the
  /// collapse button's explicit label would otherwise swallow the indicator's own a11y.
  var indicatorLabel: String = ""
  /// Trailing header action — overlaid on top of the full-width collapse button so tapping it
  /// fires the action without also toggling the section.
  @ViewBuilder var accessory: () -> Accessory
  @ViewBuilder var content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      // The ENTIRE header bar toggles collapse — the padding lives *inside* the button's content
      // shape, so there are no dead zones around the title. The trailing action button is overlaid
      // on top so it still gets its own taps.
      Button {
        if reduceMotion {
          collapsed.toggle()
        } else {
          withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            // Fixed width: chevron.right and chevron.down differ in glyph width, which would
            // otherwise nudge the title sideways on every toggle.
            .frame(width: 12, alignment: .center)
          Text(title).font(.headline)
          indicator
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        "\(title) section, \(collapsed ? "collapsed" : "expanded")"
          + (indicatorLabel.isEmpty ? "" : ", \(indicatorLabel)")
      )
      .help(collapsed ? "Expand \(title)" : "Collapse \(title)")
      // Solid header bar so the sections read as distinct blocks (issue #24 polish).
      .background(Color.primary.opacity(0.08))
      .overlay(alignment: .trailing) {
        accessory().padding(.trailing, 12)
      }

      if !collapsed {
        content()
          .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .top)
      }
    }
    .frame(maxHeight: fill && !collapsed ? .infinity : nil, alignment: .top)
  }
}

/// A compact section-header action button matching the sidebar row-button convention: an SF
/// Symbol with a subtle rounded hover fill. `destructive` tints red on hover (like the row
/// delete button); neutral uses a faint primary fill (like the new-workroom button).
struct InspectorHeaderButton: View {
  let systemImage: String
  let help: String
  var destructive: Bool = false
  var disabled: Bool = false
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11))
        .foregroundStyle(destructive && hovering ? Color.red : Color.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(
              (destructive ? Color.red : Color.primary)
                .opacity(hovering ? (destructive ? 0.18 : 0.1) : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(help)
    .disabled(disabled)
  }
}

/// The Changes section body: the selected workroom's branch, sync state, working-tree changes
/// (relative to HEAD), and CI. Reads `store.selectedTargetID` + `store.workroomStatuses`.
/// Covers the empty/edge states the design review enumerated: nothing selected, a project
/// (non-target), missing directory, still-loading, unknown (probe failed), and clean.
struct ChangesPanel: View {
  @EnvironmentObject var store: AppStore
  /// Hard cap on rendered rows so a huge change set can't blow up the list (the underlying
  /// output is already byte-capped by `StatusCommandRunner`).
  private let renderCap = 200

  var body: some View {
    Group {
      if let sid = store.selectedTargetID, isStatusable(sid) {
        content(for: sid)
      } else {
        message("Select a workroom to see its changes.")
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
    let target = store.target(for: sid)
    let status = store.workroomStatuses[sid]
    if let target, target.isMissing {
      message("Directory not found.")
    } else if status == nil || status?.lastChecked == nil {
      message("Checking\u{2026}")
    } else if let status {
      VStack(alignment: .leading, spacing: 10) {
        header(sid: sid, status: status)
        if let sync = syncText(status) {
          Text(sync).font(.callout).foregroundStyle(.secondary)
        }
        Divider()
        if let failure = status.failure {
          message(failureText(failure))
        } else if status.isClean {
          cleanState
        } else {
          fileList(status.changedFiles ?? [], in: target?.path)
        }
        // CI is GitHub-derived, so it lives in the Pull Request section (with or without a PR) —
        // not here in the local working-tree view.
      }
      .padding(12)
    }
  }

  /// Header — no repo/workroom name (issue #24 feedback). Git shows the branch; jj shows the
  /// working copy's jj-log header (change-id + commit-id + bookmarks/tags) with the description on
  /// its own line below.
  @ViewBuilder
  private func header(sid: SidebarID, status: WorkroomStatus) -> some View {
    if status.jjRefs != nil {
      jjHeader(status)
    } else {
      HStack(spacing: 6) {
        Text(gitBranchLabel(sid: sid, status: status))
          .font(.body).fontWeight(.semibold)
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
      }
    }
  }

  /// The jj working-copy header: change-id + commit-id + bookmarks/tags on the first line, the
  /// description on its own line below (issue #24 feedback).
  private func jjHeader(_ status: WorkroomStatus) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if let changeID = status.jjChangeID {
          // Change-id: just the shortest unique prefix, no dimmed padding.
          Text(changeID).font(.system(.callout, design: .monospaced)).foregroundStyle(.purple)
        }
        if let commitID = status.jjCommitID {
          Text(commitID).font(.system(.callout, design: .monospaced)).foregroundStyle(.blue)
        }
        ForEach(status.jjRefs ?? [], id: \.self) { ref in
          Text(ref).font(.callout).fontWeight(.medium).foregroundStyle(Color.accentColor)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      if let desc = status.jjDescription {
        Text(desc).font(.callout).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
      } else {
        // No description: a smaller, dimmer placeholder so it reads as absent, not a real subject.
        Text("(no description set)").font(.footnote).foregroundStyle(.tertiary).lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Read as one phrase ("change pw, commit 7d74470b, feature/login, feat: …") rather than four
    // cryptic tokens.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(jjHeaderAccessibility(status))
  }

  /// Composed VoiceOver phrase for the jj header.
  private func jjHeaderAccessibility(_ status: WorkroomStatus) -> String {
    var parts: [String] = []
    if let change = status.jjChangeID { parts.append("change \(change)") }
    if let commit = status.jjCommitID { parts.append("commit \(commit)") }
    parts += status.jjRefs ?? []
    parts.append(status.jjDescription ?? "no description set")
    return parts.joined(separator: ", ")
  }

  private func gitBranchLabel(sid: SidebarID, status: WorkroomStatus) -> String {
    if let branch = status.branchForCI { return branch }
    if case .root(let p) = sid {
      return RootPresentation.make(store.rootRefs[p] ?? .unresolved).label
    }
    return "detached"
  }

  /// Ahead/behind summary, or nil when there's no upstream info (git no-upstream, or jj which
  /// omits ahead/behind in Phase 1 — both leave the counts nil, so we say nothing rather than
  /// claim "no upstream" misleadingly).
  private func syncText(_ s: WorkroomStatus) -> String? {
    guard s.hasUpstream else { return nil }
    let a = s.ahead ?? 0
    let b = s.behind ?? 0
    if a == 0 && b == 0 { return "Up to date with upstream" }
    var parts: [String] = []
    if a != 0 { parts.append("\u{2191}\(a)") }
    if b != 0 { parts.append("\u{2193}\(b)") }
    return parts.joined(separator: " ") + " vs upstream"
  }

  /// The clean (no working-tree changes) state, styled like the Notifications empty state (issue
  /// #24 feedback): a small, dim, icon-first line rather than a full-size centered message.
  private var cleanState: some View {
    HStack(spacing: 6) {
      Image(systemName: "checkmark.circle").font(.callout).foregroundStyle(.tertiary)
      Text("No uncommitted changes").font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("No uncommitted changes")
  }

  @ViewBuilder
  private func fileList(_ files: [ChangedFile], in directory: String?) -> some View {
    let shown = Array(files.prefix(renderCap))
    VStack(alignment: .leading, spacing: 1) {
      ForEach(shown) { file in
        ChangedFileRow(file: file, directory: directory)
      }
      if files.count > shown.count {
        Text("Showing first \(shown.count) of \(files.count)")
          .font(.footnote).foregroundStyle(.tertiary)
      }
    }
  }

  /// Split a repo-relative path into (directory, filename). A root-level file → empty directory.
  static func splitPath(_ path: String) -> (dir: String, name: String) {
    guard let slash = path.lastIndex(of: "/") else { return ("", path) }
    return (String(path[..<slash]), String(path[path.index(after: slash)...]))
  }

  private func failureText(_ f: VCSStatusFailure) -> String {
    switch f {
    case .missingPath: return "Directory not found."
    case .notRepository: return "Not a repository."
    case .timeout: return "Status unavailable (timed out)."
    case .parseError: return "Status unavailable."
    }
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(.body)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
  }
}
