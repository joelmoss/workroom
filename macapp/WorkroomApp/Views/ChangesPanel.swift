import AppKit
import Defaults
import SwiftUI

/// The right inspector (issue #24). macOS 14 supports only one `.inspector` per view, so the
/// inspector composes four collapsible sections — **Changes** (the selected workroom's VCS detail),
/// **History** (its commit log), **Files** (the repo tree), and **Pull Request** — rather than
/// separate inspectors. The toolbar `sidebar.right` toggle shows/hides the whole inspector; each
/// section's disclosure handles its own visibility (persisted). (Notifications moved to the left
/// sidebar, issue #118.)
struct RightInspector: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.openURL) private var openURL
  /// A PR action awaiting confirmation (close), surfaced via a confirmation dialog.
  @State private var pendingConfirm: PendingPRAction?

  var body: some View {
    // The active activity-bar section decides which sub-sections this pane stacks (Changes stacks
    // Changes + History + Pull Request; Files is solo). Each sub-section's header + body are handed
    // to the NSSplitView bridge (see InspectorSplitView) as environment-injected AnyViews — the tree
    // does NOT inherit our `@EnvironmentObject`s across NSHostingController. Collapse flags +
    // size-weights persist as full `InspectorSectionKind.allCases`-ordered vectors on the store; we
    // slice out — and write back — the entries for the sub-sections actually shown, by `storeIndex`.
    let subs = store.activeInspectorSection.subSections
    VStack(spacing: 0) {
      // The VCS toolbar sits ABOVE the section stack, not inside a section, so it survives a collapsed
      // Changes section. Only for the Changes activity section: branch/remote state is what that section
      // is about, and showing it over the Files tree would jump the layout on every activity-bar click.
      if store.activeInspectorSection == .changes {
        VCSToolbar(model: store.remoteState)
      }
      inspectorSplit(subs: subs)
    }
    // Bound to the STORE, not a local `@State`: the gate that raises this lives in
    // `AppStore.performRemoteAction` so the Source Control menu's ⌥⇧⌘P goes through it too. When the
    // toolbar owned the gate, the shortcut autostashed a dirty tree with no warning at all.
    .confirmationDialog(
      store.pendingRemoteConfirm.map { "\($0.action.label) with uncommitted changes?" } ?? "",
      isPresented: Binding(
        get: { store.pendingRemoteConfirm != nil },
        set: { if !$0 { store.pendingRemoteConfirm = nil } }),
      presenting: store.pendingRemoteConfirm
    ) { item in
      // `runRemoteAction(on:)`, which re-checks `item.sid` — the dialog isn't modal to the sidebar, so
      // the selection can move while it's open and `performRemoteAction` would re-derive the target.
      Button(item.action.label) { store.runRemoteAction(item.action, on: item.sid) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Your uncommitted changes will be stashed and reapplied after the rebase.")
    }
  }

  @ViewBuilder private func inspectorSplit(subs: [InspectorSectionKind]) -> some View {
    InspectorSplitView(
      headers: subs.map { sectionHeader(for: $0) },
      bodies: subs.map { sectionBody(for: $0) },
      collapsed: subs.map { collapsedValue(for: $0) },
      // History hosts its body in fill mode (it scrolls itself via SwiftUI) so its divergence
      // expander animates cleanly; the other sections keep the default NSScrollView hosting.
      fills: subs.map { $0 == .history },
      sectionKey: store.activeInspectorSection.rawValue,
      // The section layout is GLOBAL, not per-workroom, so this key is constant: switching workrooms
      // must not trigger the controller's workroom-switch redistribute (only a section change, via
      // `sectionKey`, or a genuine collapse/drag re-lays out the panes).
      workroomKey: "global",
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
    case .history: return store.historySectionCollapsed
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
    case .history:
      return AnyView(
        SectionHeader(
          title: "History", collapsed: $store.historySectionCollapsed, shortcut: "⌥⌘Y"
        ) {
          // Disabled while collapsed: a collapsed section deliberately stops tracking the selection
          // (`historySectionShown` gates the re-point), so the model still points at whatever workroom
          // was selected when it shut — clicking Refresh there would read THAT repo's log, not the
          // selected one, for a list nobody can see. Expanding re-points first, then loads.
          InspectorHeaderButton(
            systemImage: "arrow.clockwise", help: "Refresh history",
            disabled: store.historySectionCollapsed
          ) {
            store.commitHistory.refresh()
          }
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
    case .history:
      return AnyView(
        HistoryPanel(model: store.commitHistory).environmentObject(store).environmentObject(
          notifications))
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
    guard let sid = store.inspectorTargetID else { return nil }
    if case .project = sid { return nil }
    return store.workroomStatuses[sid]
  }

  /// Changes header indicator: how many files changed (a capsule count) and the working-tree line counts
  /// (`+N` green / `-M` red) when there's a delta. Nothing at all if clean.
  ///
  /// The file count is deliberately NOT inside the line-counts branch. `lineCountsHelp` is nil for an
  /// untracked-only dirty tree, which is exactly a case where files changed and no `+/−` can be
  /// computed — the count is the only thing there is to say, so it has to render on its own.
  ///
  /// **The dirty dot is gone; the unknown one is not.** `VCSStatusPresentation.dot` answers three
  /// different questions, and the count only replaces one of them. Its `.dirty` circle said "this tree
  /// has changes", which is now the capsule beside it saying so with a number; its conflict triangle is
  /// already rendered here in its own right. But its `questionmark.circle` says the probe FAILED —
  /// timed out, busy, not a repository — and a failed probe reports no files and no line counts, so
  /// dropping it wholesale would render "status unavailable" identically to "clean". That case keeps its
  /// glyph, and with it the specific reason in the tooltip.
  private var changesIndicator: AnyView {
    guard let s = selectedStatus else { return AnyView(EmptyView()) }
    let ins = s.insertions ?? 0
    let del = s.deletions ?? 0
    // `changedFiles` mirrors `jjWorkingCopy?.files` for jj (both come from the one summary probe), so
    // this is the same number for both backends and matches the rows rendered below.
    let files = s.changedFiles?.count ?? 0
    let countsHelp = VCSStatusPresentation.lineCountsHelp(s)
    // `!s.conflicted` because `dot` checks conflict FIRST and would hand back the triangle this row
    // already draws — a status that is both conflicted and unreadable would otherwise show two.
    let dot = s.isUnknown && !s.conflicted ? VCSStatusPresentation.dot(s) : nil
    if files == 0, countsHelp == nil, dot == nil { return AnyView(EmptyView()) }
    return AnyView(
      HStack(spacing: 5) {
        if s.conflicted {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 9)).foregroundStyle(Color.red)
        }
        if files > 0 { ChangedFileCountBadge(count: files) }
        if let countsHelp {
          HStack(spacing: 5) {
            if ins > 0 { Text("+\(ins)").foregroundStyle(.green) }
            if del > 0 { Text("-\(del)").foregroundStyle(.red) }
          }
          .help(countsHelp)
        }
        if let dot {
          Image(systemName: dot.symbol).font(.system(size: 9)).foregroundStyle(dot.semantic.color)
            .help(dot.accessibility)
        }
      }
      .font(.caption).monospacedDigit())
  }

  // VoiceOver text for each header indicator (the visual badge can't be read through the collapse
  // button's own label), appended to the section's accessibility label.

  private var changesIndicatorLabel: String {
    guard let s = selectedStatus else { return "" }
    // The capsule count is a `Text` inside the combined header element, so it never reaches the
    // accessibility tree on its own — it has to be spoken here or not at all.
    // `> 0` so this tracks the badge exactly — a clean tree renders no capsule and must speak none.
    let files = (s.changedFiles?.count).flatMap {
      $0 > 0 ? ChangedFileCountBadge.phrase(count: $0) : nil
    }
    // Mirrors what the row now draws: line counts, or the unavailable reason, and no longer "working
    // tree has changes" — the count phrase above already says that, in files rather than in prose.
    let detail =
      VCSStatusPresentation.lineCountsHelp(s)
      ?? (s.isUnknown ? VCSStatusPresentation.dot(s)?.accessibility : nil)
    return [files, detail].compactMap { $0 }.joined(separator: ", ")
  }
}

/// A PR action awaiting user confirmation (the close action), carried by the confirmation dialog.
private struct PendingPRAction: Identifiable {
  let action: PRAction
  let number: Int
  let sid: SidebarID
  var id: String { "\(action.rawValue)-\(number)" }
}

/// The Changes section header's changed-file count.
///
/// Geometry and type are `PRNumberBadge`'s, so the two section headers' badges match — but this one is
/// not a `Button` and takes no hover: it's a quantity, not a link. The neutral `.quaternary` fill is the
/// same capsule the ref chips in the body use, deliberately not a tinted one — the severity signal in
/// this header is the conflict glyph and the `+/−` colours beside it, and a coloured count would compete
/// with them for the same meaning.
private struct ChangedFileCountBadge: View {
  let count: Int

  /// Also spoken by the section's accessibility label, which is why it's a static rather than inline.
  static func phrase(count: Int) -> String {
    count == 1 ? "1 changed file" : "\(count) changed files"
  }

  var body: some View {
    // `verbatim:` for the same reason `PRNumberBadge` uses it — no LocalizedStringKey digit grouping.
    Text(verbatim: "\(count)")
      .font(.caption2).fontWeight(.semibold).monospacedDigit()
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5).padding(.vertical, 1)
      .background(.quaternary, in: Capsule())
      .help(Self.phrase(count: count))
  }
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
    // Baseline-aligned, not centered: the path is a smaller face than the filename, so centering
    // would float it off the name's baseline.
    HStack(alignment: .firstTextBaseline, spacing: 6) {
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
        // Same face as the History detail file list's path line (`ChangesetDetailView.fileRow`):
        // caption, monospaced, `.tertiary`. Matching the tint matters — the two panels sit one tab
        // apart, and `.secondary` beside `.tertiary` reads as two different kinds of text rather
        // than the same one.
        //
        // Truncation is the one thing that deliberately differs. History stacks the full path UNDER
        // the name and truncates it in the middle; here the directory sits INLINE before a
        // `layoutPriority(1)` name, where the tail (the directory the file is actually in) is the
        // part that identifies it — so it truncates from the head. Middle-truncation on a one-line
        // inline dir would clip both ends and leave the least useful segment.
        Text(dir)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.tertiary)
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
    // A moved file's old path has nowhere to go in this single-line row, so the tooltip carries it
    // (`old → new`); the wider changeset detail list shows it inline.
    .help(file.oldPath == nil ? "Open diff" : "Open diff — \(renamePath)")
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
      accessibilityLabel(name: name, dir: dir)
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

  // Letter / colour / word live in `ChangeBadge` (Core) so the mapping is unit-testable — see its
  // doc for why `.conflicted` is `"!"` in its own colour rather than `"C"` in deletion's red.
  private var letter: String { ChangeBadge.letter(file.change) }
  private var color: Color { ChangeBadge.color(file.change, theme.tokens) }
  private var changeWord: String { ChangeBadge.word(file.change) }
  /// `old → new`, for the tooltip and accessibility label of a moved file.
  private var renamePath: String {
    ChangeBadge.pathLine(path: file.path, oldPath: file.oldPath)
  }

  /// The row's spoken label. A moved file says where it came from — VoiceOver has no tooltip to fall
  /// back on, and the row only shows the new path.
  private func accessibilityLabel(name: String, dir: String) -> String {
    let place = dir.isEmpty ? "" : ", in \(dir)"
    let from = file.oldPath.map { ", from \($0)" } ?? ""
    return "\(name), \(changeWord)\(place)\(from), open diff"
  }
}

/// Applies `accessibilityElement(children: .combine)` + an identifier only when `identifier` is
/// non-nil, so the jj Changes header becomes one queryable a11y element (the panel's render sentinel,
/// `changes.workingCopy`) while the git header — which no UI test waits on — stays untouched.
private struct CombinedA11y: ViewModifier {
  let identifier: String?
  func body(content: Content) -> some View {
    if let identifier {
      content.accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
    } else {
      content
    }
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
  private let theme = ThemeService.shared
  /// Hard cap on rendered rows so a huge change set can't blow up the list (the underlying
  /// output is already byte-capped by `StatusCommandRunner`).
  private let renderCap = 200

  var body: some View {
    Group {
      if let sid = store.inspectorTargetID, sid.isStatusable {
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
      // The branch/bookmark name is NOT repeated here — the VCS toolbar above this section shows it,
      // through the same `AppStore.branchName(for:)` accessor this panel used to read, so the pill was
      // saying the same thing twice about 40pt apart. What's left is backend-shaped: git's working tree
      // carries no metadata of its own, so it renders as a bare change list, while jj's `@` IS a commit
      // and keeps its change-id/commit-id/refs + description header. `jjWorkingCopy != nil` is the
      // discriminator — a failed probe leaves it nil, so failures fall to the git path.
      if let workingCopy = status.jjWorkingCopy {
        jjContent(workingCopy: workingCopy, sid: sid)
      } else {
        gitContent(status: status)
      }
    }
  }

  /// Git repos: just the working-tree change list (or clean/failure). No header — git's working tree
  /// isn't a commit, so with the branch name moved to the toolbar there is nothing left to head it with,
  /// and the divider went with it rather than ruling off an empty row. CI is GitHub-derived, so it lives
  /// in the Pull Request section — not here.
  @ViewBuilder
  private func gitContent(status: WorkroomStatus) -> some View {
    VStack(alignment: .leading, spacing: 10) {
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

  /// jj repos: the working copy (`@`) — because `@` is itself a commit, its change-id/commit-id/refs
  /// and description — over the flat change list. The working copy's parent (`@-`) is no longer shown
  /// here; the History panel now surfaces it.
  @ViewBuilder
  private func jjContent(workingCopy: JJCommitChanges, sid: SidebarID) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      changesHeader(meta: workingCopy, identifier: "changes.workingCopy", sid: sid)
      Divider()
      if workingCopy.files.isEmpty {
        cleanState
      } else {
        fileList(workingCopy.files, source: .jjWorkingCopy)
      }
    }
    .padding(12)
  }

  /// The jj working copy's header: `@`'s change-id (purple) / commit-id (blue) / its bookmarks, and the
  /// description line. **jj only** — git's working tree isn't a commit, so it carries no refs and no
  /// message and now renders headerless. `identifier` combines this into one a11y element; it is also
  /// the panel's render sentinel, which a dozen UI tests wait on before asserting anything else.
  /// The refs worth chipping: every bookmark on `@` EXCEPT the one the toolbar's bookmark segment is
  /// already showing, which is the only one most workrooms have.
  ///
  /// Filtered against `branchName(for:)` — the same accessor the toolbar reads — rather than against
  /// `meta.refs.first`, so the two can't disagree about which chip is the redundant one. A commit can
  /// carry several bookmarks and the toolbar names exactly one, so the rest still chip here; this
  /// removes a duplicate, not the information.
  private func extraRefs(_ meta: JJCommitChanges, sid: SidebarID) -> [String] {
    guard let shown = store.branchName(for: sid) else { return meta.refs }
    return meta.refs.filter { $0 != shown }
  }

  @ViewBuilder
  private func changesHeader(meta: JJCommitChanges, identifier: String?, sid: SidebarID)
    -> some View
  {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if let changeID = meta.changeID {
          Text(changeID).font(.system(.callout, design: .monospaced))
            .foregroundStyle(.purple).help("Change ID")
        }
        if let commitID = meta.commitID {
          Text(commitID).font(.system(.callout, design: .monospaced))
            .foregroundStyle(.blue).help("Commit ID")
        }
        // The bookmark the toolbar shows does NOT chip here — see `extraRefs`. jj reports a bookmarked
        // `@`'s name twice (as the status' `branchForCI` and again in `refs`), so this row has always
        // needed a filter to avoid one bookmark reading as two capsules; what changed is the reference
        // point. It used to be the branch-name pill that stood to the left of these chips. That pill is
        // gone, and for one commit in between so was the filter — which put the bookmark back on screen
        // twice, ~40pt below the toolbar segment that names it. Now it's the toolbar's own answer.
        //
        // The same gray capsules the History list rows and changeset header use, one step down from
        // the ids beside them (`.caption` under `.callout`, as the list's `.caption2` sits under its
        // `.caption`) so a pill doesn't outweigh this header's larger type.
        ForEach(extraRefs(meta, sid: sid), id: \.self) { ref in
          Text(ref).font(.caption)
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help("Bookmark / branch")
        }
        Spacer(minLength: 0)
      }
      if let desc = meta.description {
        Text(desc).font(.callout).foregroundStyle(.primary)
          .lineLimit(1).truncationMode(.tail)
      } else {
        Text("(no description set)").font(.footnote).foregroundStyle(.tertiary).lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(CombinedA11y(identifier: identifier))
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
    case .busy: return "Repository is busy — another VCS command is running."
    case .staleWorkingCopy: return "Working copy is out of date. Run `jj workspace update-stale`."
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
