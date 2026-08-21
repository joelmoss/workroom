import SwiftUI

/// A status bar pinned to the bottom of a single pane (issue #49). Part of the pane itself, so every
/// pane in a split carries its own — it reflects THAT pane's tab: the open file's path (a file or
/// diff pane, issue #136) or the cwd (a terminal), the branch/bookmark, the run command's state
/// (only on the run tab), and the inline agent's diagnosis. Themed to match
/// the terminal (same background + foreground palette) so it reads as the pane's own chrome.
///
/// The diagnosis is a compact indicator that opens the full `TerminalAgentBanner` in a POPOVER — not
/// an overlay. A SwiftUI overlay's controls sit over the terminal's Metal `NSView`, which wins AppKit
/// hit-testing, so overlay buttons silently swallow clicks; a popover lives in its own window.
struct TerminalStatusBar: View {
  let target: TerminalTarget
  let tabID: TerminalTab.ID
  /// The pane's terminal, or nil for a non-terminal (diff / file / changeset) pane — which shows no
  /// cwd, run state or diagnosis, only the path (where there is one) and the branch.
  let state: TerminalState?
  /// The repo-relative path of the file this pane shows (issue #136), or nil for a pane that isn't
  /// a file: a terminal (which shows its cwd instead) or a changeset (whose in-pane `DiffViewer`
  /// header already carries the path). Supplied by `PaneLeafView` from `TabContent.filePath`.
  /// Defaulted, so the terminal mount doesn't have to say `filePath: nil`.
  var filePath: String? = nil
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var agentManager: TerminalAgentManager
  @EnvironmentObject var agentUsage: AgentUsageMonitor
  @EnvironmentObject var claudeUsageBridge: ClaudeUsageBridge
  /// Observed here too (`DetachedSessionsButton` already observes it) so a divider next to that
  /// button can know whether it's actually showing anything.
  @ObservedObject private var sessionsStore = TerminalSessionsStore.shared
  @State private var showingDiagnosis = false
  /// Set by a click, and survives the mouse leaving the segment — the detail view stays open until
  /// dismissed (another click, or clicking elsewhere) rather than closing the instant hover ends.
  @State private var usageDetailPinned = false
  /// Set after a short hover delay (`usageHoverRevealDelay`), so a mouse merely passing over the
  /// segment doesn't pop a popover; cleared the instant the mouse leaves, independent of
  /// `usageDetailPinned`.
  @State private var usageDetailHovering = false
  @State private var usageHoverRevealWorkItem: DispatchWorkItem?
  @State private var confirmingClaudeUsage = false
  @State private var claudeBridgeError: String?
  /// The AppKit view the cwd menu pops out of — see `MenuAnchor`.
  @State private var cwdMenuAnchor: NSView?

  private let theme = ThemeService.shared
  private let usageHoverRevealDelay: TimeInterval = 0.4

  /// This pane's live cwd (observed state first, then the surface's last-known); nil for a diff pane.
  private var cwd: String? { state.flatMap { $0.cwd ?? $0.view.lastKnownCwd } }

  private var isRunTab: Bool { state != nil && store.runTabID(for: target.id) == tabID }

  private var diagnosis: AgentBannerState? { state == nil ? nil : agentManager.banners[tabID] }

  private var activeAgent: AgentBackend? {
    state?.activeAgentBackend
  }

  var body: some View {
    // Computed once per render so a divider between two segments only appears when BOTH sides are
    // actually showing something — each segment is independently optional.
    let hasLeading = filePath != nil || cwd != nil
    let hasBranch = store.branchLabel(for: target) != nil
    let hasDiagnosis = diagnosis != nil
    let hasDetached = !sessionsStore.detached(for: target.id).isEmpty
    let hasRun = isRunTab && runStatePresentation != nil
    let hasAgentUsage = activeAgent != nil

    HStack(spacing: 12) {
      // Path and cwd are mutually exclusive in practice — a content pane has no cwd, a terminal has
      // no file — so they share the leading slot, ahead of the branch.
      pathSegment
      cwdSegment
      if hasLeading, hasBranch { statusBarDivider }
      branchSegment
      // Diagnosis sits left-aligned right after the branch, not pushed to the far edge.
      if hasLeading || hasBranch, hasDiagnosis { statusBarDivider }
      if let diagnosis { diagnosisSegment(diagnosis) }
      Spacer(minLength: 8)
      DetachedSessionsButton(target: target)
      if hasDetached, hasRun { statusBarDivider }
      if isRunTab, let run = runStatePresentation { runSegment(run) }
      if hasDetached || hasRun, hasAgentUsage { statusBarDivider }
      if let activeAgent { agentUsageSegment(activeAgent) }
    }
    // `.subheadline` (11pt) — the middle of the two sizes this bar has worn. `.caption` (10pt) was
    // too small to read at a glance for what the bar carries (a pane's identity: path, branch, run
    // state); `.callout` (12pt) read as content rather than chrome.
    .font(.subheadline)
    .foregroundStyle(theme.tokens.fgMuted)
    .lineLimit(1)
    .padding(.horizontal, 10)
    // Fixed, not vertical padding: the bar's height must not vary with its content (an icon, a
    // `ProgressView`) or a pane would resize as a diagnosis arrives. Held at 28pt across the font
    // change so panes don't reflow — the 11pt text just sits in a little more air.
    .frame(height: 28)
    .frame(maxWidth: .infinity)
    // `panel` (bg blended 5.5% toward fg), not the raw terminal `bg`: the bar reads as chrome rather
    // than as more terminal. Opaque and theme-derived, so it lifts by the same amount on a light or a
    // dark theme — a fixed white/black wash would invert on one of them.
    .background(theme.tokens.panel)
    .overlay(alignment: .top) { theme.tokens.border.frame(height: 1) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal.statusBar")
    .task(id: activeAgent) {
      if activeAgent != nil { agentUsage.refresh() }
    }
    .alert("Enable Claude usage?", isPresented: $confirmingClaudeUsage) {
      Button("Cancel", role: .cancel) {}
      Button("Enable") {
        do {
          try claudeUsageBridge.enable()
          agentUsage.refresh()
        } catch {
          claudeBridgeError = error.localizedDescription
        }
      }
    } message: {
      Text(
        "Workroom will update ~/.claude/settings.json to run its status-line wrapper. The wrapper "
          + "stores only Claude's rate_limits data, then passes the original status-line input "
          + "unchanged to your current command. You can disable this from Agent Settings."
      )
    }
    .alert("Claude usage wasn’t enabled", isPresented: bridgeErrorPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(claudeBridgeError ?? "The Claude status-line bridge could not be installed.")
    }
  }

  /// A thin vertical rule between two segments, shorter than the 28pt bar so it reads as a
  /// separator rather than a full-height rail.
  private var statusBarDivider: some View {
    theme.tokens.border.frame(width: 1, height: 14)
  }

  private var bridgeErrorPresented: Binding<Bool> {
    Binding(
      get: { claudeBridgeError != nil },
      set: { if !$0 { claudeBridgeError = nil } })
  }

  /// True while pinned (clicked) OR hovering — a system dismissal (clicking outside the popover, or
  /// Escape) clears both, so a pin doesn't linger open after the platform already closed it.
  private var usageDetailPresented: Binding<Bool> {
    Binding(
      get: { usageDetailPinned || usageDetailHovering },
      set: { presented in
        if !presented {
          usageDetailPinned = false
          usageDetailHovering = false
        }
      })
  }

  // MARK: Agent quota

  @ViewBuilder private func agentUsageSegment(_ backend: AgentBackend) -> some View {
    if backend == .claude, claudeUsageBridge.state == .disabled {
      Button("Enable Claude usage…") { confirmingClaudeUsage = true }
        .buttonStyle(StatusBarSegmentButtonStyle())
        .foregroundStyle(theme.tokens.accent)
        .help("Enable the opt-in Claude status-line bridge")
        .accessibilityIdentifier("terminal.statusBar.agentUsage.enableClaude")
    } else if let snapshot = agentUsage.snapshot(for: backend) {
      let label = quotaAccessibilityLabel(snapshot)
      Button {
        usageDetailPinned.toggle()
        // The mouse is still over the segment right after this click, so `.onHover` never fires an
        // exit — without this, unpinning while hovering left `usageDetailPinned || usageDetailHovering`
        // true and the popover never actually closed.
        if !usageDetailPinned { usageDetailHovering = false }
      } label: {
        ViewThatFits(in: .horizontal) {
          quotaFull(snapshot)
          quotaCompact(snapshot)
        }
        .fixedSize(horizontal: true, vertical: false)
      }
      .buttonStyle(StatusBarSegmentButtonStyle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(label)
      .accessibilityIdentifier("terminal.statusBar.agentUsage")
      .onHover { hovering in
        usageHoverRevealWorkItem?.cancel()
        if hovering {
          let workItem = DispatchWorkItem { usageDetailHovering = true }
          usageHoverRevealWorkItem = workItem
          DispatchQueue.main.asyncAfter(deadline: .now() + usageHoverRevealDelay, execute: workItem)
        } else {
          usageDetailHovering = false
        }
      }
      .popover(isPresented: usageDetailPresented, arrowEdge: .bottom) {
        AgentUsageDetailView(snapshot: snapshot, now: Date())
          .frame(width: AgentUsageDetailView.popoverWidth)
      }
    } else {
      let isLoading = agentUsage.loading.contains(backend)
      HStack(spacing: 4) {
        if isLoading { ProgressView().controlSize(.mini) }
        Text(
          isLoading
            ? "Loading \(backend.displayName) usage…" : "\(backend.displayName) usage unavailable")
      }
      .foregroundStyle(theme.tokens.fgDim)
      .help("Waiting for a fresh local \(backend.displayName) quota snapshot")
      .accessibilityLabel(
        isLoading
          ? "Loading \(backend.displayName) quota usage"
          : "\(backend.displayName) quota usage unavailable"
      )
      .accessibilityIdentifier("terminal.statusBar.agentUsage.unavailable")
    }
  }

  /// One concatenated `Text` (not an `HStack` of separate `Text`s, like `quotaCompact` below) because
  /// the pace figure needs its own color run inline within a window's segment. Shown, and colored,
  /// only in deficit — under-pace/on-pace is the unremarkable case and stays silent.
  private func quotaFull(_ snapshot: AgentQuotaSnapshot) -> Text {
    let now = Date()
    // A single window needs no "5h"/"wk" prefix to disambiguate from — there's nothing else in the
    // segment it could be confused with (e.g. Codex, which only ever reports one window).
    let showsWindowKind = snapshot.windows.count > 1
    return snapshot.windows.reduce(Text(snapshot.backend.displayName)) { text, window in
      let used = Int(window.usedPercentage.rounded())
      let usedText = showsWindowKind ? "\(window.kind.compactLabel) \(used)%" : "\(used)%"
      var windowText = Text(" · \(usedText)")
      let pace = window.pace(at: now)
      if pace.isOver {
        let paceText = Text(" (\(pace.compactDescription))").foregroundColor(paceColor(pace))
        windowText = windowText + paceText
      }
      return text + windowText
    }
  }

  private func quotaCompact(_ snapshot: AgentQuotaSnapshot) -> some View {
    let showsWindowKind = snapshot.windows.count > 1
    return HStack(spacing: 5) {
      ForEach(snapshot.windows) { window in
        let used = Int(window.usedPercentage.rounded())
        Text(showsWindowKind ? "\(window.kind.compactLabel) \(used)%" : "\(used)%")
      }
    }
  }

  /// Only reached for a window already confirmed `pace.isOver` (in deficit) — a deeper deficit reads
  /// as failure, a shallower one as warning. Independent of the popover's marker, which only
  /// distinguishes over/under pace, not degree.
  private func paceColor(_ pace: AgentPace) -> Color {
    pace.percentagePoints > 15 ? theme.tokens.failure : theme.tokens.warning
  }

  private func quotaAccessibilityLabel(_ snapshot: AgentQuotaSnapshot) -> String {
    let now = Date()
    let windows = snapshot.windows.map { window in
      let used = Int(window.usedPercentage.rounded())
      let pace = used == 0 ? "" : ", \(window.pace(at: now).accessibilityDescription)"
      return
        "\(window.kind.compactLabel) quota \(used)% used\(pace), \(window.resetDescription(at: now))"
    }
    return "\(snapshot.backend.displayName) quota. " + windows.joined(separator: ". ")
  }

  // MARK: File path / branch / cwd

  /// The open file's repo-relative path (issue #136) — the pane's identity, which the tab chip can't
  /// carry (it shows only the basename, so two `user.rb` tabs read the same). Tooltip resolves it
  /// absolutely against the workroom directory.
  ///
  /// Two modifiers here are decisions, not defaults:
  ///
  /// - `.head`, unlike the `.middle` its neighbours use. A repo-relative path's discriminating part
  ///   is its TAIL: middle-truncating `app/models/user.rb` and `app/views/user.rb` elides exactly the
  ///   component that tells them apart, which is the bug this segment exists to fix. Head truncation
  ///   drops the shared prefix and keeps the immediate directory plus the filename.
  /// - `.layoutPriority(1)`, so the branch yields first when the bar is squeezed. Content panes are
  ///   exempt from the pane-width floor (`TerminalSessions.fits` returns true with no surface), so a
  ///   split diff pane can be ~198pt wide; without a priority SwiftUI shrinks both labels
  ///   proportionally. The path is this pane's identity, while the branch is the same on every pane
  ///   of the workroom and already shown in the sidebar.
  @ViewBuilder private var pathSegment: some View {
    if let filePath {
      Label {
        Text(filePath).truncationMode(.head)
      } icon: {
        Image(systemName: "doc")
      }
      .labelStyle(.titleAndIcon)
      .layoutPriority(1)
      .help((target.path as NSString).appendingPathComponent(filePath))
      .accessibilityLabel("File \(filePath)")
      .accessibilityIdentifier("terminal.statusBar.path")
    }
  }

  @ViewBuilder private var branchSegment: some View {
    if let branch = store.branchLabel(for: target) {
      Label {
        Text(branch).truncationMode(.middle)
      } icon: {
        Image(systemName: "arrow.triangle.branch")
      }
      .labelStyle(.titleAndIcon)
      .help("Current branch / bookmark")
      .accessibilityLabel("Branch \(branch)")
    }
  }

  /// The pane's cwd, and the two things you want from a path you can see: copy it, or reveal it
  /// (issue #143). Clicking drops the menu; the segment carries a hover well so it reads as clickable
  /// (the path and branch segments, which do nothing, deliberately don't).
  ///
  /// A plain `Button` popping an `NSMenu` by hand, NOT a SwiftUI `Menu`. A `Menu`'s dropped list
  /// inherits its TRIGGER's width, and this trigger is a whole filesystem path — so two short items
  /// rendered in a menu as wide as the pane. An `NSMenu` we pop ourselves sizes to its own items.
  /// (`.menuStyle(.borderlessButton)` wouldn't have helped either: it's AppKit-backed, never reports
  /// hover, so the well would be impossible.) The label stays squeezable — no `.fixedSize()` — so
  /// `.middle` truncation still fires in a narrow split pane.
  ///
  /// The items are a menu rather than a selectable label because `.textSelection(.enabled)` swallows
  /// real mouseDown, which would kill the click this segment now exists to answer.
  @ViewBuilder private var cwdSegment: some View {
    if let cwd {
      Button {
        popCwdMenu(cwd)
      } label: {
        Label {
          Text(Self.abbreviate(cwd)).truncationMode(.middle)
        } icon: {
          Image(systemName: "folder")
        }
        .labelStyle(.titleAndIcon)
        // Explicit, not inherited: a `Button`'s label doesn't pick up the bar's ambient
        // `foregroundStyle`, so without this the segment reads brighter than its neighbours.
        .foregroundStyle(theme.tokens.fgMuted)
      }
      .buttonStyle(StatusBarSegmentButtonStyle())
      .background(MenuAnchor(view: $cwdMenuAnchor))
      .help(cwd)
      .accessibilityLabel("Working directory \(cwd)")
      .accessibilityIdentifier("terminal.statusBar.cwd")
    }
  }

  private func popCwdMenu(_ cwd: String) {
    let menu = NSMenu()
    menu.addItem(
      ClosureMenuItem(title: "Copy to Clipboard") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cwd, forType: .string)
      })
    // `activateFileViewerSelecting`, matching the wording and the File menu's own "Reveal in Finder"
    // (which reveals the selected target's directory the same way): the directory comes up selected in
    // its parent. `NSWorkspace.open` would open the folder's own window instead — a different verb
    // than the one this item promises.
    menu.addItem(
      ClosureMenuItem(title: "Reveal in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
      })
    // At the cursor, like a context menu — but popped out of a real view rather than the tempting
    // `at: NSEvent.mouseLocation, in: nil` (screen coordinates, no anchor needed). That form does
    // nothing at all when the click is synthesized: `StatusBarCwdUITests` clicked the segment and no
    // menu ever appeared. Anchored to a view it opens either way, so the cursor's screen point is
    // converted into the anchor's own coordinates instead.
    if let anchor = cwdMenuAnchor, let window = anchor.window {
      let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
      menu.popUp(positioning: nil, at: anchor.convert(inWindow, from: nil), in: anchor)
    } else {
      menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
  }

  /// `~`-abbreviate a home-relative path; leave others untouched. Truncation is left to the label.
  static func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }

  // MARK: Run state (run tab only)

  private func runSegment(_ run: RunPresentation) -> some View {
    Label {
      Text(run.text)
    } icon: {
      Image(systemName: run.icon)
    }
    .labelStyle(.titleAndIcon)
    .foregroundStyle(run.color ?? AnyShapeStyle(theme.tokens.fgMuted))
    .help("Run command: \(run.text)")
    .accessibilityLabel("Run command \(run.text)")
  }

  private struct RunPresentation {
    let icon: String
    let text: String
    /// A tint for a notable state (running/failed); nil inherits the bar's muted foreground.
    let color: AnyShapeStyle?
  }

  private var runStatePresentation: RunPresentation? {
    guard let state = store.runStates[target.id] else { return nil }
    switch state {
    case .armed:
      return nil
    case .running:
      return RunPresentation(
        icon: "play.fill", text: "Running", color: AnyShapeStyle(theme.tokens.accent))
    case .restarting:
      return RunPresentation(
        icon: "arrow.clockwise", text: "Restarting", color: AnyShapeStyle(theme.tokens.warning))
    case .stopped:
      switch store.runOutcomes[target.id] {
      case .exited(let code) where code != 0:
        return RunPresentation(
          icon: "xmark.octagon.fill", text: "Failed (exit \(code))",
          color: AnyShapeStyle(theme.tokens.failure))
      case .exited:
        return RunPresentation(icon: "checkmark.circle", text: "Exited", color: nil)
      case .failedToStart:
        return RunPresentation(
          icon: "xmark.octagon.fill", text: "Failed to start",
          color: AnyShapeStyle(theme.tokens.failure))
      case .stoppedByUser, .none:
        return RunPresentation(icon: "stop.fill", text: "Stopped", color: nil)
      }
    }
  }

  // MARK: Diagnosis

  private func diagnosisSegment(_ bannerState: AgentBannerState) -> some View {
    let model = AgentBannerViewModel(state: bannerState)
    let tint = diagnosisTint(model.style)
    return Button {
      showingDiagnosis.toggle()
    } label: {
      HStack(spacing: 4) {
        diagnosisIcon(model.style)
        Text(model.headline).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading)
      }
      // A diagnosis means a command FAILED — colour it red on any tab (not only the run tab's run
      // state), so a failure reads red everywhere.
      .foregroundStyle(tint)
    }
    .buttonStyle(.plain)
    .help("Show the agent's diagnosis")
    .accessibilityLabel("Diagnosis: \(model.headline)")
    .accessibilityIdentifier("terminal.statusBar.diagnosis")
    .popover(isPresented: $showingDiagnosis, arrowEdge: .bottom) {
      TerminalAgentBanner(
        state: bannerState,
        onDiagnose: { agentManager.diagnose(tab: tabID, target: target.id) },
        onInsertFix: { fix in
          state?.view.sendText(fix)
          showingDiagnosis = false
        },
        onInvestigate: {
          _ = store.startInvestigate(bannerState: bannerState, target: target, surface: state?.view)
          agentManager.dismiss(tab: tabID)
          showingDiagnosis = false
        },
        onDismiss: {
          agentManager.dismiss(tab: tabID)
          showingDiagnosis = false
        }
      )
      .frame(width: 380)
    }
  }

  /// Foreground for the diagnosis indicator: red for the command-failure states (a diagnosis exists
  /// because a command failed), muted for the transient/neutral ones.
  private func diagnosisTint(_ style: AgentBannerViewModel.Style) -> AnyShapeStyle {
    switch style {
    case .ready, .awaiting, .failure: return AnyShapeStyle(theme.tokens.failure)
    case .loading, .remote: return AnyShapeStyle(theme.tokens.fgMuted)
    }
  }

  @ViewBuilder private func diagnosisIcon(_ style: AgentBannerViewModel.Style) -> some View {
    switch style {
    case .loading:
      ProgressView().controlSize(.mini)
    case .ready:
      Image(systemName: "sparkles")
    case .failure:
      Image(systemName: "exclamationmark.triangle.fill")
    case .awaiting:
      Image(systemName: "questionmark.circle")
    case .remote:
      Image(systemName: "network")
    }
  }
}

/// An invisible AppKit view, laid out behind the cwd segment and handed back through a binding, so
/// `NSMenu.popUp(positioning:at:in:)` has a view to pop out of (issue #143) — the view-less,
/// screen-coordinate form of that call silently does nothing for a synthesized click.
///
/// `hitTest` returns nil so the anchor can never take the click that pops the menu, or the hover that
/// fills the well, from the `Button` in front of it.
private struct MenuAnchor: NSViewRepresentable {
  final class AnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  @Binding var view: NSView?

  func makeNSView(context: Context) -> AnchorView {
    let anchor = AnchorView()
    // Async: assigning to `@State` during `makeNSView` mutates state mid-update.
    DispatchQueue.main.async { view = anchor }
    return anchor
  }

  func updateNSView(_ nsView: AnchorView, context: Context) {}
}

/// `NSMenuItem` takes an ObjC target/action, and both cwd actions are closures.
private final class ClosureMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    target = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("ClosureMenuItem is built in code, never unarchived") }

  @objc private func fire() { handler() }
}

/// Hover well for the status bar's one clickable segment, the cwd (issue #143).
///
/// The well is a **negatively inset background**, not padding around the label. The cwd shares the
/// bar's leading slot with the file path (a terminal has no path, a content pane has no cwd), so
/// padding it would put the `folder` glyph 5pt right of where a file pane's `doc` glyph lands — the
/// same bar would shift its leading edge depending on which pane you looked at. Negative insets bleed
/// the fill outside the label's bounds and leave the layout, and that alignment, untouched.
///
/// Opacity is animated, never the view tree: an implicit tree animation interpolates a glyph's 1pt
/// pixel re-round into a visible slide (see `ToolbarIconButtonStyle`).
private struct StatusBarSegmentButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverWell(configuration: configuration)
  }

  private struct HoverWell: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      configuration.label
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(
              ThemeService.shared.tokens.hover
                .opacity(hovering || configuration.isPressed ? 1 : 0)
            )
            .padding(EdgeInsets(top: -3, leading: -5, bottom: -3, trailing: -5))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
  }
}
