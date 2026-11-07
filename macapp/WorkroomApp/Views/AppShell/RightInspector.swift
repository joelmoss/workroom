import AppKit
import Defaults
import DesignSystem
import SwiftUI
import WorkroomDomain
import WorkroomVCS

/// The right inspector (issue #24). macOS 14 supports only one `.inspector` per view, so the
/// inspector composes four collapsible sections — **Changes** (the selected workroom's VCS detail),
/// **History** (its commit log), **Files** (the repo tree), and **Pull Request** — rather than
/// separate inspectors. The toolbar `sidebar.right` toggle shows/hides the whole inspector; each
/// section's disclosure handles its own visibility (persisted). (Notifications moved to the left
/// sidebar, issue #118.)
struct RightInspector: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var modals: ModalState
  @EnvironmentObject var vcsStatus: VCSStatusService
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.openURL) private var openURL
  @Environment(\.themeTokens) private var tokens
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
      // Above everything, in every pane: which workroom all of this is about.
      InspectorWorkroomHeader()
      Divider()
      // The VCS toolbar sits ABOVE the section stack, not inside a section, so it survives a collapsed
      // Changes section. Only for the Changes activity section: branch/remote state is what that section
      // is about, and showing it over the Files tree would jump the layout on every activity-bar click.
      if store.activeInspectorSection == .changes {
        VCSToolbar(model: store.remoteState)
      }
      if subs.isEmpty {
        // Details: drawn whole, under the workroom header that already names what it is about, so
        // a section header of its own would only repeat it.
        ScrollView { DetailsPanel() }
          .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      } else {
        inspectorSplit(subs: subs)
      }
    }
    // Bound to the window's `ModalState`, not a local `@State`: the gate that raises this lives in
    // `AppStore.performRemoteAction` so the Room menu's ⌥⇧⌘P goes through it too. When the
    // toolbar owned the gate, the shortcut autostashed a dirty tree with no warning at all.
    .confirmationDialog(
      modals.pendingRemoteConfirm.map { "\($0.action.label) with uncommitted changes?" } ?? "",
      isPresented: Binding(
        get: { modals.pendingRemoteConfirm != nil },
        set: { if !$0 { modals.pendingRemoteConfirm = nil } }),
      presenting: modals.pendingRemoteConfirm
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

  /// Whether the inspector's target has anything a commit could record.
  private var canCommitSelectedTarget: Bool { store.canCommit(store.inspectorTargetID) }

  private var commitButtonHelp: String {
    canCommitSelectedTarget ? "Commit changes…" : "Nothing to commit"
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
          HStack(spacing: 0) {
            InspectorHeaderButton(
              systemImage: "checkmark.circle", help: commitButtonHelp,
              disabled: !canCommitSelectedTarget
            ) {
              store.requestCommit(store.inspectorTargetID)
            }
            .accessibilityIdentifier("changes.commitButton")
            InspectorHeaderButton(systemImage: "arrow.clockwise", help: "Refresh workroom status") {
              vcsStatus.refreshWorkroomStatuses(force: true)
            }
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
      return AnyView(
        ChangesPanel(sessions: store.terminals)
          .environmentObject(store).environmentObject(vcsStatus)
          .environmentObject(notifications))
    case .files:
      return AnyView(
        FilesPanel(model: store.fileTree).environmentObject(store).environmentObject(notifications))
    case .pullRequest:
      return AnyView(
        PullRequestPanel().environmentObject(store).environmentObject(vcsStatus)
          .environmentObject(notifications))
    case .history:
      // `sessions:` is injected, not read from the store inside the panel, because the panel must
      // OBSERVE it (that is what replaced every row observing it — see `HistoryPanel`'s type doc).
      return AnyView(
        HistoryPanel(model: store.commitHistory, sessions: store.terminals)
          .environmentObject(store).environmentObject(notifications))
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
    if vcsStatus.githubCLIStatus == .available, let status = selectedStatus, let pr = status.pr {
      let badge = PRPresentation.badge(pr)
      // Failing checks only recolor an *open* PR — a merged (purple) / closed (red) badge shouldn't
      // be repainted by stale check history.
      let failing = pr.state == .open && PRPresentation.isFailing(status)
      let tint: Color = failing ? tokens.failure : badge.semantic.color(tokens)
      // The traffic-light states draw their number over a wash of the same colour, so it is made
      // readable on that wash; merged (purple) and draft (secondary) keep their colour.
      let text = PRNumberBadge.trafficColor(badge.semantic, failing: failing, tokens).map {
        Color(nsColor: tokens.readableOnOwnWash($0, washes: PRNumberBadge.washes))
      }
      let failSuffix = failing ? ", checks failing" : ""
      PRNumberBadge(
        number: pr.number, tint: tint, text: text ?? tint, url: URL(string: pr.url),
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
    if vcsStatus.githubCLIStatus == .available, let pr = selectedStatus?.pr,
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
    tokens.border.frame(height: 1)
  }

  /// The selected workroom's status, or nil when a non-target (project) or nothing is selected —
  /// drives the header indicators so a collapsed section still shows state.
  private var selectedStatus: WorkroomStatus? {
    guard let sid = store.inspectorTargetID else { return nil }
    if case .project = sid { return nil }
    return vcsStatus.workroomStatuses[sid]
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
    // Matches the rows rendered below.
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
            .font(.system(size: 9)).foregroundStyle(tokens.failure)
        }
        if files > 0 { ChangedFileCountBadge(count: files) }
        if let countsHelp {
          HStack(spacing: 5) {
            if ins > 0 { Text("+\(ins)").foregroundStyle(tokens.success) }
            if del > 0 { Text("-\(del)").foregroundStyle(tokens.failure) }
          }
          .help(countsHelp)
        }
        if let dot {
          Image(systemName: dot.symbol).font(.system(size: 9))
            .foregroundStyle(dot.semantic.color(tokens))
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
  /// The capsule's tint at rest and on hover.
  static let washes: [CGFloat] = [0.22, 0.34]

  /// The traffic-light token behind a state's tint, or nil for merged and draft.
  static func trafficColor(
    _ semantic: PRPresentation.Semantic, failing: Bool, _ tokens: ThemeTokens
  ) -> NSColor? {
    if failing { return tokens.nsFailure }
    switch semantic {
    case .open: return tokens.nsSuccess
    case .closed: return tokens.nsFailure
    case .draft, .merged: return nil
    }
  }

  let number: Int
  let tint: Color
  let text: Color
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
        .foregroundStyle(text)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(tint.opacity(hovering ? Self.washes[1] : Self.washes[0])))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(accessibility)
  }
}

/// A compact section-header action button matching the sidebar row-button convention: an SF
/// Symbol with a subtle rounded hover fill. `destructive` tints red on hover (like the row
/// delete button); neutral uses a faint primary fill (like the new-workroom button). `compact` is
/// the smaller form for an action inside a body row (a copy button beside a value), not a header.
struct InspectorHeaderButton: View {
  let systemImage: String
  let help: String
  var destructive: Bool = false
  var disabled: Bool = false
  var compact: Bool = false
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: compact ? 9 : 11))
        .foregroundStyle(destructive && hovering ? tokens.failure : tokens.fgMuted)
        .inspectorHeaderButtonChrome(hovering: hovering, destructive: destructive, compact: compact)
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
  fileprivate func inspectorHeaderButtonChrome(
    hovering: Bool, destructive: Bool = false, compact: Bool = false
  ) -> some View {
    modifier(
      InspectorHeaderButtonChrome(hovering: hovering, destructive: destructive, compact: compact))
  }
}

private struct InspectorHeaderButtonChrome: ViewModifier {
  let hovering: Bool
  let destructive: Bool
  let compact: Bool
  @Environment(\.themeTokens) private var tokens

  func body(content: Content) -> some View {
    content
      .frame(width: compact ? 16 : 22, height: compact ? 16 : 22)
      .background(
        RoundedRectangle(cornerRadius: compact ? 4 : 5)
          .fill(
            (destructive ? tokens.failure : tokens.hover)
              .opacity(hovering ? (destructive ? 0.18 : 1) : 0))
      )
      .frame(width: compact ? 20 : 28, height: compact ? 18 : 26)
      .contentShape(Rectangle())
  }
}

/// Button style for the Pull Request header's actions `Menu`, used via `.menuStyle(.button)` so the
/// trigger is a SwiftUI button (a `.borderlessButton` menu is AppKit-backed and never reports
/// hover). It mirrors `InspectorHeaderButton`: a centred glyph, the same rounded hover fill, and the
/// same comfortable click target so all three header buttons match.
struct InspectorMenuButtonStyle: ButtonStyle {
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
