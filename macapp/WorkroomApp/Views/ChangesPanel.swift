import AppKit
import Defaults
import SwiftUI

/// The right inspector (issue #24). macOS 14 supports only one `.inspector` per view, so the
/// inspector composes three collapsible sections — **Changes** (the selected workroom's VCS
/// detail), **Files** (the repo tree), and **Pull Request** — rather than separate inspectors.
/// The toolbar `sidebar.right` toggle shows/hides the whole inspector; each section's disclosure
/// handles its own visibility (persisted). (Notifications moved to the left sidebar, issue #118.)
struct RightInspector: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.openURL) private var openURL
  /// A PR action awaiting confirmation (close), surfaced via a confirmation dialog.
  @State private var pendingConfirm: PendingPRAction?

  var body: some View {
    // The active activity-bar section decides which sub-sections this pane stacks (Changes stacks
    // Changes + Pull Request; Files is solo). Each sub-section's header + body are handed to the
    // NSSplitView bridge (see InspectorSplitView) as environment-injected AnyViews — the hosted tree
    // does NOT inherit our `@EnvironmentObject`s across NSHostingController. Collapse flags +
    // size-weights persist as full `InspectorSectionKind.allCases`-ordered vectors on the store; we
    // slice out — and write back — the entries for the sub-sections actually shown, by `storeIndex`.
    let subs = store.activeInspectorSection.subSections
    InspectorSplitView(
      headers: subs.map { sectionHeader(for: $0) },
      bodies: subs.map { sectionBody(for: $0) },
      collapsed: subs.map { collapsedValue(for: $0) },
      sectionKey: store.activeInspectorSection.rawValue,
      workroomKey: AppStore.targetIDString(for: store.selectedTargetID) ?? "",
      weights: subs.map { store.inspectorSizeWeights[$0.storeIndex] },
      onWeightsChanged: { shown in
        var full = store.inspectorSizeWeights
        for (index, sub) in subs.enumerated() where index < shown.count {
          full[sub.storeIndex] = shown[index]
        }
        store.updateInspectorSizeWeights(full)
      }
    )
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

  /// The live collapse value for a sub-section. A solo pane (Files, which stacks only itself) never
  /// collapses, so it reports expanded and its header shows no chevron.
  private func collapsedValue(for sub: InspectorSectionKind) -> Bool {
    switch sub {
    case .changes: return store.changesSectionCollapsed
    case .files: return false
    case .pullRequest: return store.prSectionCollapsed
    }
  }

  /// A sub-section's sticky header, environment-injected for the NSHostingController-hosted tree.
  /// Files passes a nil collapse binding (solo pane → no chevron).
  private func sectionHeader(for sub: InspectorSectionKind) -> AnyView {
    switch sub {
    case .changes:
      return AnyView(
        SectionHeader(
          title: "Changes", collapsed: $store.changesSectionCollapsed,
          indicator: changesIndicator, indicatorLabel: changesIndicatorLabel, shortcut: "⌥⌘C"
        ) {
          InspectorHeaderButton(systemImage: "arrow.clockwise", help: "Refresh workroom status") {
            store.refreshWorkroomStatuses(force: true)
          }
        }
        .environmentObject(store).environmentObject(notifications))
    case .files:
      return AnyView(
        SectionHeader(title: "Files", collapsed: nil, shortcut: "⌥⌘F") {
          InspectorHeaderButton(systemImage: "arrow.clockwise", help: "Refresh files") {
            store.fileTree.reload()
          }
        }
        .environmentObject(store).environmentObject(notifications))
    case .pullRequest:
      return AnyView(
        SectionHeader(title: "Pull Request", collapsed: $store.prSectionCollapsed, shortcut: "⌥⌘P")
        {
          prHeaderAccessory
        }
        .environmentObject(store).environmentObject(notifications))
    }
  }

  /// A sub-section's scrollable body, environment-injected for the hosted tree.
  private func sectionBody(for sub: InspectorSectionKind) -> AnyView {
    switch sub {
    case .changes:
      return AnyView(ChangesPanel().environmentObject(store).environmentObject(notifications))
    case .files:
      return AnyView(
        FilesPanel(model: store.fileTree).environmentObject(store).environmentObject(notifications))
    case .pullRequest:
      return AnyView(PullRequestPanel().environmentObject(store).environmentObject(notifications))
    }
  }

  /// The Pull Request header's trailing controls (issue #77): the PR number badge — a link to the
  /// PR, tinted by state and turning red when checks fail — then the actions menu. The draft-only
  /// "Ready for Review" button moved into the panel body (above the title) so it can't crowd the
  /// section title in a narrow inspector (issue #93 feedback). Order is left → right, so the ellipsis
  /// stays rightmost (matching the other section headers).
  @ViewBuilder private var prHeaderAccessory: some View {
    HStack(spacing: 6) {
      prNumberLink
      prActionsMenu
    }
  }

  /// The PR number badge, now a link that opens the PR in the browser (issue #77) — it replaces the
  /// in-panel status row's open-in-browser affordance, so the header always carries the link. Tinted
  /// by PR state (open/draft/merged/closed), but red when the PR's checks are failing.
  @ViewBuilder private var prNumberLink: some View {
    if store.githubCLIStatus == .available, let status = selectedStatus, let pr = status.pr {
      let badge = PRPresentation.badge(pr)
      // Failing checks only recolor an *open* PR — a merged (purple) / closed (red) badge shouldn't
      // be repainted by stale check history.
      let failing = pr.state == .open && PRPresentation.isFailing(status)
      let tint: Color = failing ? .red : badge.semantic.color
      let failSuffix = failing ? ", checks failing" : ""
      PRNumberBadge(
        number: pr.number, tint: tint, url: URL(string: pr.url),
        help: "Pull request #\(String(pr.number)): \(badge.label)\(failSuffix). Open in browser.",
        accessibility:
          "Pull request #\(String(pr.number)), \(badge.label)\(failSuffix), open in browser")
    }
  }

  /// The PR header menu: "Go to Pull Request" (always available when there's a PR), plus the
  /// state-dependent write actions (ready/draft, close, reopen — Phase 2b; destructive ones route
  /// through a confirmation dialog). Shown whenever there's a PR, so a merged/closed PR with no
  /// remaining actions can still be opened in the browser.
  @ViewBuilder private var prActionsMenu: some View {
    if store.githubCLIStatus == .available, let pr = selectedStatus?.pr,
      let sid = store.selectedTargetID
    {
      let actions = PRAction.available(for: pr)
      Menu {
        Button {
          if let url = URL(string: pr.url) { openURL(url) }
        } label: {
          Label("Go to Pull Request", systemImage: "arrow.up.right.square")
        }
        if !actions.isEmpty {
          Divider()
          ForEach(actions, id: \.self) { action in
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
        }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      // `.menuStyle(.button)` (NOT `.borderlessButton`) renders the trigger as a SwiftUI button, so
      // `InspectorMenuButtonStyle` can give it the same rounded hover fill + comfortable click
      // target as the other header buttons. A `.borderlessButton` menu is AppKit-backed and never
      // reports hover. Clicking still drops the native menu — consistent with the rest of the app.
      .menuStyle(.button)
      .buttonStyle(InspectorMenuButtonStyle())
      .menuIndicator(.hidden)
      .fixedSize()
      .disabled(store.prActionInFlight)
      .help("Pull request actions")
      .accessibilityLabel("Pull request actions")
    }
  }

  /// A 1px rule between sections so adjacent (especially collapsed) header bars stay separated.
  private var sectionRule: some View {
    ThemeService.shared.tokens.border.frame(height: 1)
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
}

/// A PR action awaiting user confirmation (the close action), carried by the confirmation dialog.
private struct PendingPRAction: Identifiable {
  let action: PRAction
  let number: Int
  let sid: SidebarID
  var id: String { "\(action.rawValue)-\(number)" }
}

/// The Pull Request section header's number badge (issue #77): a capsule "#N" link that opens the PR
/// in the browser, tinted by PR state (red when checks fail). A standalone view so it can carry its
/// own `@State` hover, which the `@ViewBuilder` accessory can't — the capsule fill deepens on hover.
private struct PRNumberBadge: View {
  let number: Int
  let tint: Color
  let url: URL?
  let help: String
  let accessibility: String
  @Environment(\.openURL) private var openURL
  @State private var hovering = false

  var body: some View {
    Button {
      if let url { openURL(url) }
    } label: {
      // `verbatim:` so the Int isn't run through LocalizedStringKey number formatting, which would
      // group it as "#1,042" — a PR number is an identifier, not a quantity.
      Text(verbatim: "#\(number)")
        .font(.caption2).fontWeight(.semibold).monospacedDigit()
        .foregroundStyle(tint)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(tint.opacity(hovering ? 0.34 : 0.22)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(accessibility)
  }
}

/// One changed-file row: a colored change-kind letter (M/A/D/…), the filename, then its parent
/// directory dimmed (issue #24 feedback). Clicking opens the file's diff in the workroom's tab strip
/// (issue #66): a single click opens it in preview mode (eagerly — the diff appears at once), a quick
/// double-click persists it. `source` is the row's group (git worktree / jj `@` / jj `@-`), so the
/// diff resolves against the right revision. The directory yields first when space is tight
/// (truncates from the head). The change kind is spelled out in the accessibility label.
private struct ChangedFileRow: View {
  let file: ChangedFile
  /// Which revision this row's diff comes from — the Changes group it's rendered under.
  let source: DiffSource
  @EnvironmentObject var store: AppStore
  /// Observed so the row's selected state tracks which diff tab is focused (the tab strip lives in
  /// a separate observation tree from the inspector).
  @ObservedObject var sessions: TerminalSessions
  @State private var hovering = false
  /// Time of the last click, so a quick second click promotes the preview tab to persisted (eager
  /// single/double discrimination — the single click never waits).
  @State private var lastClick: Date?
  /// Observed so the hover toolbar / context-menu "Open file in <editor>" label updates live when
  /// the user changes Settings → "Open file paths in" (issue #93); otherwise it'd be stale until an
  /// unrelated redraw.
  @Default(.filePathEditor) private var filePathEditorID
  private let theme = ThemeService.shared

  var body: some View {
    let (dir, name) = ChangesPanel.splitPath(file.path)
    HStack(spacing: 6) {
      Text(letter)
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(color)
        .frame(width: 14, alignment: .leading)
      Text(name)
        .font(.callout)
        .foregroundStyle(isSelected ? theme.tokens.accent : .primary)
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
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      // Square, full-width band (no corner radius): bleed past the section's 12pt inset so the
      // hover/selection highlight fills the inspector width edge-to-edge (issue #93 feedback).
      Rectangle()
        .fill(isSelected ? theme.tokens.rowSelection : (hovering ? theme.tokens.rowHover : .clear))
        .padding(.horizontal, -12)
    )
    // The row's tooltip describes its click action (open the diff). Applied BEFORE the hover overlay
    // so it scopes to the row content only — the trailing "Open file" button, painted on top, keeps
    // its OWN tooltip. A `.help` applied after the overlay covers the whole row and occludes the
    // button's, so hovering the button wrongly showed "Open diff for …" (issue #117 follow-up).
    .help("Open diff")
    // Hover toolbar (issue #93): a content-sized cluster pinned to the trailing edge, painted over
    // the path. Only the button area intercepts clicks (it opens the file) — the rest of the row
    // still opens the diff. Built only while hovering, so the editor-name lookup runs on hover only.
    .overlay(alignment: .trailing) { if hovering { rowToolbar } }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture {
      if NSEvent.modifierFlags.contains(.command) {
        store.openChangedFileInEditor(file)  // ⌘-click → open the file, not the diff (issue #93)
        lastClick = nil  // clear any pending double-click state so the next plain click is fresh
        return
      }
      let now = Date()
      if let last = lastClick, now.timeIntervalSince(last) < 0.35 {
        store.openDiffPersistent(file, source: source)  // quick second click → persist
        lastClick = nil
      } else {
        store.openDiffPreview(file, source: source)  // eager: open the preview immediately
        lastClick = now
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("changes.file.\(file.path)")
    .accessibilityLabel(
      dir.isEmpty
        ? "\(name), \(changeWord), open diff" : "\(name), \(changeWord), in \(dir), open diff"
    )
    // A non-pointer path to the open-file actions (the hover toolbar is mouse-only): keyboard /
    // VoiceOver reach them here. "Open File" opens the in-app viewer (issue #117); "Open File in …"
    // keeps the external-editor path (issue #93). Both no-op for a deleted file (no working copy).
    .contextMenu {
      Button {
        store.openChangedFileInApp(file)
      } label: {
        Label("Open File", systemImage: "doc.text")
      }
      .disabled(file.change == .deleted)
      Button {
        store.openChangedFileInEditor(file)
      } label: {
        Label("Open File in \(openFileEditorName)", systemImage: "arrow.up.forward.app")
      }
      .disabled(file.change == .deleted)
    }
  }

  /// The trailing hover toolbar: the in-app "Open File" button (extensible to more buttons; issue
  /// #117). Hidden for a deleted file — there's no working copy to open — so the toolbar renders
  /// nothing. Its backing is the same opaque `rowHover`/`rowSelection` token the row uses for its
  /// highlight, so the toolbar is solid (occludes the path text) and exactly the same colour as the row.
  @ViewBuilder private var rowToolbar: some View {
    if file.change != .deleted {
      HStack(spacing: 2) {
        TabToolbarButton(
          systemImage: "doc.text", help: "Open file",
          accessibilityLabel: "Open file",
          identifier: "changes.file.openFile.\(file.path)"
        ) {
          store.openChangedFileInApp(file)
        }
      }
      .padding(.horizontal, 2)
      .background(
        // The same opaque token the row fills its highlight with — solid (occludes the path text) and
        // identical in colour to the row by construction.
        RoundedRectangle(cornerRadius: 5)
          .fill(isSelected ? theme.tokens.rowSelection : theme.tokens.rowHover)
      )
      .fixedSize()
    }
  }

  /// Display name of the editor the "Open file in…" action targets — the Settings "Open file paths
  /// in" choice (`ExternalEditor.forFilePaths`), or "your default app" when unset. Recomputes when
  /// `filePathEditorID` changes (issue #93).
  private var openFileEditorName: String {
    ExternalEditor.forFilePaths?.name ?? "your default app"
  }

  /// True when the selected target's focused content tab is this row — either its diff (opened by a
  /// row click) or its file (opened by the in-app "Open File", issue #117) — so the row that's
  /// showing in the pane reads as selected. The file match ignores `source` since a file tab has no
  /// revision; the diff match keeps it so the same path under `@` vs `@-` selects the right row.
  private var isSelected: Bool {
    guard let target = store.selectedTarget, let tab = sessions.focusedTab(for: target)
    else { return false }
    switch tab.content {
    case .diff(let descriptor): return descriptor.path == file.path && descriptor.source == source
    case .file(let descriptor): return descriptor.path == file.path
    default: return false
    }
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
    case .added: return theme.tokens.diffAddFg
    case .deleted: return theme.tokens.diffRemoveFg
    case .conflicted: return theme.tokens.diffRemoveFg
    case .modified, .renamed: return theme.tokens.warning
    case .untracked, .other: return theme.tokens.fgMuted
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

/// One collapsible jj changes group (Working Copy `@` or Parent Commit `@-`): a disclosure header —
/// rotating chevron + title + the change-id/commit-id/bookmark chips + a trailing changed-file count
/// — over a body that's shown only when expanded. The chevron is a single rotated glyph (fixed
/// width, like `SectionHeader`) so the title never shifts. `meta == nil` renders just the title (the
/// merge/unavailable parent states, which carry no id/description); `count == nil` drops the count
/// chip. Tap anywhere on the header toggles `collapsed`.
private struct ChangesDisclosureGroup<Content: View>: View {
  let title: String
  let meta: JJCommitChanges?
  let count: Int?
  /// Accessibility id on the header button (so a UI test clicks the *header* to toggle, never a file
  /// row inside an expanded body).
  let identifier: String
  @Binding var collapsed: Bool
  @ViewBuilder var content: () -> Content
  private let theme = ThemeService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      if !collapsed { content() }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var countLabel: String? {
    guard let count else { return nil }
    return count == 1 ? "1 changed file" : "\(count) changed files"
  }

  private var header: some View {
    Button {
      collapsed.toggle()
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .frame(width: 12, alignment: .center)
          Text(title).font(.callout).fontWeight(.semibold)
          if let meta {
            if let changeID = meta.changeID {
              Text(changeID).font(.system(.callout, design: .monospaced)).foregroundStyle(.purple)
            }
            if let commitID = meta.commitID {
              Text(commitID).font(.system(.callout, design: .monospaced)).foregroundStyle(.blue)
            }
            ForEach(meta.refs, id: \.self) { ref in
              Text(ref).font(.callout).fontWeight(.medium)
                .foregroundStyle(theme.tokens.accent).lineLimit(1)
            }
          }
          Spacer(minLength: 4)
          if let count, let countLabel {
            Text("\(count)")
              .font(.caption).monospacedDigit().foregroundStyle(.secondary)
              .help(countLabel)
          }
        }
        // The change description (or its absence) on its own line, indented under the title.
        if let meta {
          if let desc = meta.description {
            Text(desc).font(.callout).foregroundStyle(.primary)
              .lineLimit(1).truncationMode(.tail).padding(.leading, 18)
          } else {
            Text("(no description set)").font(.footnote).foregroundStyle(.tertiary)
              .lineLimit(1).padding(.leading, 18)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(collapsed ? "Expand \(title)" : "Collapse \(title)")
    // Keep the Button a single, pressable accessibility element (like `SectionHeader`): an overriding
    // `accessibilityLabel` composes the phrase without `accessibilityElement(children: .ignore)`,
    // which would strip the press action (XCUITest can then neither type it as a button nor click it).
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(identifier)
  }

  /// One composed phrase, e.g. "Working Copy, expanded, change pw, commit 7d74470b, main, feat: …,
  /// 3 changed files" — rather than a row of cryptic tokens VoiceOver would read individually.
  private var accessibilityLabel: String {
    var parts: [String] = [title, collapsed ? "collapsed" : "expanded"]
    if let meta {
      if let c = meta.changeID { parts.append("change \(c)") }
      if let c = meta.commitID { parts.append("commit \(c)") }
      parts += meta.refs
      parts.append(meta.description ?? "no description set")
    }
    if let countLabel { parts.append(countLabel) }
    return parts.joined(separator: ", ")
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
  private let theme = ThemeService.shared

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11))
        .foregroundStyle(destructive && hovering ? Color.red : theme.tokens.fgMuted)
        .inspectorHeaderButtonChrome(hovering: hovering, destructive: destructive)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(help)
    .disabled(disabled)
  }
}

extension View {
  /// Shared chrome for the inspector's three section-header icon buttons — Changes' Refresh,
  /// Notifications' Clear (both `InspectorHeaderButton`), and Pull Request's actions menu
  /// (`InspectorMenuButtonStyle`). A **fixed** hover-fill size (not glyph + padding) keeps the fill
  /// identical across the differently-shaped glyphs (the wide ellipsis vs. the narrow refresh/trash),
  /// centred in a larger **fixed** click target so all three match exactly. `contentShape` makes the
  /// whole target clickable/hoverable, not just the glyph.
  fileprivate func inspectorHeaderButtonChrome(hovering: Bool, destructive: Bool = false)
    -> some View
  {
    self
      .frame(width: 22, height: 22)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(
            (destructive ? Color.red : ThemeService.shared.tokens.hover)
              .opacity(hovering ? (destructive ? 0.18 : 1) : 0))
      )
      .frame(width: 28, height: 26)
      .contentShape(Rectangle())
  }
}

/// Button style for the Pull Request header's actions `Menu`, used via `.menuStyle(.button)` so the
/// trigger is a SwiftUI button (a `.borderlessButton` menu is AppKit-backed and never reports
/// hover). It mirrors `InspectorHeaderButton`: a centred glyph, the same rounded hover fill, and the
/// same comfortable click target so all three header buttons match.
private struct InspectorMenuButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverFill(configuration: configuration)
  }

  private struct HoverFill: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .inspectorHeaderButtonChrome(hovering: hovering || configuration.isPressed)
        .onHover { hovering = $0 }
    }
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
      if let sid = store.selectedTargetID, sid.isStatusable {
        content(for: sid)
      } else {
        inspectorMessage("Select a workroom to see its changes.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func content(for sid: SidebarID) -> some View {
    let target = store.target(for: sid)
    let status = store.workroomStatuses[sid]
    if let target, target.isMissing {
      inspectorMessage("Directory not found.")
    } else if status == nil || status?.lastChecked == nil {
      inspectorMessage("Checking\u{2026}")
    } else if let status {
      // jj repos render two collapsible groups (working copy + parent); git keeps the flat list.
      // `jjWorkingCopy != nil` is the discriminator — a failed probe leaves it nil, so failures fall
      // to the git path (which renders the failure message under a branch header, as before).
      if let workingCopy = status.jjWorkingCopy {
        jjContent(workingCopy: workingCopy, parent: status.jjParent)
      } else {
        gitContent(sid: sid, status: status)
      }
    }
  }

  /// Git repos: the branch header, sync state, then the working-tree change list (or clean/failure).
  /// CI is GitHub-derived, so it lives in the Pull Request section — not here.
  @ViewBuilder
  private func gitContent(sid: SidebarID, status: WorkroomStatus) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Text(gitBranchLabel(sid: sid, status: status))
          .font(.body).fontWeight(.semibold)
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
      }
      if let sync = syncText(status) {
        Text(sync).font(.callout).foregroundStyle(.secondary)
      }
      Divider()
      if let failure = status.failure {
        inspectorMessage(failureText(failure))
      } else if status.isClean {
        cleanState
      } else {
        fileList(status.changedFiles ?? [], source: .gitWorktree)
      }
    }
    .padding(12)
  }

  /// jj repos: two collapsible groups — the working copy (`@`, expanded by default) and its parent
  /// (`@-`, collapsed by default), each with a changed-file count in its header.
  @ViewBuilder
  private func jjContent(workingCopy: JJCommitChanges, parent: JJParentState?) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ChangesDisclosureGroup(
        title: "Working Copy", meta: workingCopy, count: workingCopy.files.count,
        identifier: "changes.group.workingCopy", collapsed: $store.changesWorkingCopyCollapsed
      ) {
        if workingCopy.files.isEmpty {
          cleanState
        } else {
          fileList(workingCopy.files, source: .jjWorkingCopy)
        }
      }
      parentGroup(parent)
    }
    .padding(12)
  }

  /// The Parent Commit (`@-`) group. Each `JJParentState` renders explicitly so a merge or an
  /// unavailable probe is shown, never silently dropped; `.root`/`nil` hides the group entirely.
  @ViewBuilder
  private func parentGroup(_ parent: JJParentState?) -> some View {
    switch parent {
    case .changes(let commit):
      ChangesDisclosureGroup(
        title: "Parent Commit", meta: commit, count: commit.files.count,
        identifier: "changes.group.parentCommit", collapsed: $store.changesParentCommitCollapsed
      ) {
        if commit.files.isEmpty {
          parentMessage("No changes in this commit")
        } else {
          fileList(commit.files, source: .jjParent)
        }
      }
    case .merge(let n):
      ChangesDisclosureGroup(
        title: "Parent Commit", meta: nil, count: nil,
        identifier: "changes.group.parentCommit", collapsed: $store.changesParentCommitCollapsed
      ) {
        parentMessage("Parent is a merge of \(n) changes")
      }
    case .unavailable:
      ChangesDisclosureGroup(
        title: "Parent Commit", meta: nil, count: nil,
        identifier: "changes.group.parentCommit", collapsed: $store.changesParentCommitCollapsed
      ) {
        parentMessage("Parent changes unavailable")
      }
    case .root, .none:
      EmptyView()
    }
  }

  /// A muted single-line message for the parent group's non-list states (merge / unavailable / empty),
  /// indented to align under the disclosure title.
  private func parentMessage(_ text: String) -> some View {
    Text(text)
      .font(.callout).foregroundStyle(.secondary)
      .padding(.leading, 18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(text)
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
  private func fileList(_ files: [ChangedFile], source: DiffSource) -> some View {
    let shown = Array(files.prefix(renderCap))
    VStack(alignment: .leading, spacing: 1) {
      ForEach(shown) { file in
        ChangedFileRow(file: file, source: source, sessions: store.terminals)
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
    }
  }
}

extension SidebarID {
  /// A row whose VCS status the inspector can show: the project root or a workroom, but not the
  /// collapsed `.project` group header. Shared by the Changes and Pull Request panels.
  var isStatusable: Bool {
    if case .project = self { return false }
    return true
  }
}

/// The inspector's "nothing to show" placeholder line (e.g. "Select a workroom…"), shared by the
/// Changes and Pull Request panels so they read identically.
func inspectorMessage(_ text: String) -> some View {
  Text(text)
    .font(.body)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
}
