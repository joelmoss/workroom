import SwiftUI

/// A status bar pinned to the bottom of a single pane (issue #49). Part of the pane itself, so every
/// pane in a split carries its own — it reflects THAT pane's live working state: the cwd (a
/// terminal), the branch, the run command's state (only on the run tab), and the inline
/// agent's diagnosis. Themed to match the terminal (same background + foreground palette) so it reads
/// as the pane's own chrome.
///
/// It no longer carries a content pane's file path (issue #136): since issue #150 every pane has a
/// title bar naming itself, so the path was being shown twice. Identity goes at the top of the pane,
/// live state at the bottom.
///
/// The diagnosis is a compact indicator that opens the full `TerminalCodingAgentBanner` in a POPOVER — not
/// an overlay. A SwiftUI overlay's controls sit over the terminal's Metal `NSView`, which wins AppKit
/// hit-testing, so overlay buttons silently swallow clicks; a popover lives in its own window.
///
/// Store-free: it renders `model` and forwards the diagnosis' buttons to `actions`.
/// `TerminalStatusBarAdapter` builds both for a pane. The detached-sessions button is a slot
/// (`detachedSessions`), since that button reads the window's sessions itself.
struct TerminalStatusBar<DetachedSessions: View>: View {
  let model: TerminalStatusBarModel
  let actions: TerminalStatusBarActions
  @ViewBuilder let detachedSessions: () -> DetachedSessions
  @State private var showingDiagnosis = false
  @Environment(\.isQuickTerminal) private var isQuickTerminal
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    #if DEBUG
      StatusBarPasses.count += 1
    #endif
    // Computed once per render so a divider between two segments only appears when BOTH sides are
    // actually showing something — each segment is independently optional.
    let cwd = model.cwd
    let hasLeading = cwd != nil
    let branch = model.branch
    let hasBranch = branch != nil
    let diagnosis = model.diagnosis
    let hasDiagnosis = diagnosis != nil
    let hasDetached = model.hasDetachedSessions
    let runStatePresentation = runStatePresentation
    let hasRun = runStatePresentation != nil

    return HStack(spacing: 12) {
      // A terminal's cwd leads the bar. The file path a content pane used to show here moved to the
      // pane's own title bar (issue #150), which names the pane; this bar is its live working state.
      if let cwd { StatusBarCwdSegment(cwd: cwd, onHost: model.cwdIsOnHost) }
      if hasLeading, hasBranch { StatusBarDivider() }
      if let branch { StatusBarBranchSegment(branch: branch) }
      // Diagnosis sits left-aligned right after the branch, not pushed to the far edge.
      if hasLeading || hasBranch, hasDiagnosis { StatusBarDivider() }
      if let diagnosis { diagnosisSegment(diagnosis) }
      if isQuickTerminal {
        // Its empty middle drags the Quick Terminal along the screen edges.
        // Fills the bar's fixed height (`statusBarChrome`).
        Spacer(minLength: 8)
          .frame(maxHeight: .infinity)
          .overlay { QuickTerminalDragHandle() }
          .accessibilityHidden(true)
      } else {
        Spacer(minLength: 8)
      }
      // The running agent's usage (#480). Before the detached-sessions button, so nothing trailing
      // moves when it comes and goes, and lowest priority, so it gives way before cwd or branch. Not
      // in a remote pane: its agent bills the host's login, which this Mac's readings may not be.
      if let usage = model.usage {
        PaneUsageSlot(backend: usage.backend, claudeProfile: usage.claudeProfile)
          .layoutPriority(-1)
      }
      detachedSessions()
      if hasDetached, hasRun { StatusBarDivider() }
      if let run = runStatePresentation { runSegment(run) }
    }
    .statusBarChrome()
  }

  // MARK: Run state (run tab only)

  private func runSegment(_ run: RunPresentation) -> some View {
    Label {
      Text(run.text)
    } icon: {
      Image(systemName: run.icon)
    }
    .labelStyle(.titleAndIcon)
    .foregroundStyle(run.color ?? AnyShapeStyle(tokens.fgMuted))
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
    guard let state = model.run else { return nil }
    switch state {
    case .armed:
      return nil
    case .running(_, true):
      return RunPresentation(
        icon: "stop.fill", text: "Stopping…", color: AnyShapeStyle(tokens.warning))
    case .running(_, false):
      return RunPresentation(
        icon: "play.fill", text: "Running", color: AnyShapeStyle(tokens.accent))
    case .restarting:
      return RunPresentation(
        icon: "arrow.clockwise", text: "Restarting…", color: AnyShapeStyle(tokens.warning))
    case .stopped:
      switch model.runOutcome {
      case .exited(let code) where code != 0:
        return RunPresentation(
          icon: "xmark.octagon.fill", text: "Failed (exit \(code))",
          color: AnyShapeStyle(tokens.failure))
      case .exited:
        return RunPresentation(icon: "checkmark.circle", text: "Exited", color: nil)
      case .failedToStart:
        return RunPresentation(
          icon: "xmark.octagon.fill", text: "Failed to start",
          color: AnyShapeStyle(tokens.failure))
      case .stoppedByUser, .none:
        return RunPresentation(icon: "stop.fill", text: "Stopped", color: nil)
      }
    }
  }

  // MARK: Diagnosis

  private func diagnosisSegment(_ bannerState: CodingAgentBannerState) -> some View {
    let banner = CodingAgentBannerViewModel(state: bannerState)
    let tint = diagnosisTint(banner.style)
    return Button {
      showingDiagnosis.toggle()
    } label: {
      HStack(spacing: 4) {
        diagnosisIcon(banner.style)
        Text(banner.headline).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading)
      }
      // A diagnosis means a command FAILED — colour it red on any tab (not only the run tab's run
      // state), so a failure reads red everywhere.
      .foregroundStyle(tint)
    }
    .buttonStyle(.plain)
    .help("Show the agent's diagnosis")
    .accessibilityLabel("Diagnosis: \(banner.headline)")
    .accessibilityIdentifier("terminal.statusBar.diagnosis")
    .popover(isPresented: $showingDiagnosis, arrowEdge: .bottom) {
      TerminalCodingAgentBanner(
        state: bannerState,
        onDiagnose: actions.diagnose,
        onInsertFix: { fix in
          actions.insertFix(fix)
          showingDiagnosis = false
        },
        onInvestigate: {
          actions.investigate(bannerState)
          showingDiagnosis = false
        },
        onDismiss: {
          actions.dismissDiagnosis()
          showingDiagnosis = false
        }
      )
      .frame(width: 380)
    }
  }

  /// Foreground for the diagnosis indicator: red for the command-failure states (a diagnosis exists
  /// because a command failed), muted for the transient/neutral ones.
  private func diagnosisTint(_ style: CodingAgentBannerViewModel.Style) -> AnyShapeStyle {
    switch style {
    case .ready, .awaiting, .failure: return AnyShapeStyle(tokens.failure)
    case .loading, .remote: return AnyShapeStyle(tokens.fgMuted)
    }
  }

  @ViewBuilder private func diagnosisIcon(_ style: CodingAgentBannerViewModel.Style) -> some View {
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

#if DEBUG
  /// How many times any pane's `TerminalStatusBar` body has run, read by
  /// `AdapterGateInvalidationTests` (a generic type can't hold the counter itself).
  @MainActor enum StatusBarPasses {
    static var count = 0
  }
#endif

/// What a pane's status bar shows. Every segment is optional: a content pane has no cwd, run state
/// or diagnosis, only the branch.
struct TerminalStatusBarModel: Equatable {
  /// The running coding agent whose usage the bar shows.
  struct Usage: Equatable {
    let backend: CodingAgentBackend
    let claudeProfile: PaneClaudeProfile?
  }

  /// The pane's live cwd (a remote pane's host path, else the shell's last report).
  var cwd: String? = nil
  /// Whether `cwd` is a path on a remote pane's host (#239), which names nothing on this Mac.
  var cwdIsOnHost = false
  var branch: String? = nil
  var diagnosis: CodingAgentBannerState? = nil
  /// Nil without a running agent, and always in a remote pane: its agent bills the host's login,
  /// which this Mac's readings may not be.
  var usage: Usage? = nil
  /// Whether the detached-sessions slot is showing anything, so the divider beside it can know.
  var hasDetachedSessions = false
  /// The run command's state, on the run tab only.
  var run: RunCommandController.RunState? = nil
  /// How a stopped run ended; read only once `run` is `.stopped`.
  var runOutcome: RunCommandController.RunOutcome? = nil
}

/// What the diagnosis popover's buttons do. The bar closes the popover itself.
struct TerminalStatusBarActions {
  var diagnose: () -> Void
  /// Type the agent's suggested fix into the pane's terminal.
  var insertFix: (String) -> Void
  /// Open an agent tab to investigate the failure, and dismiss the diagnosis.
  var investigate: (CodingAgentBannerState) -> Void
  var dismissDiagnosis: () -> Void
}

/// Builds a pane's `TerminalStatusBar` from the window's stores.
///
/// A view of its own, not a computation in `PaneLeafView`: this body is where the branch, run state,
/// diagnosis and detached sessions are read, so a change to any of them re-evaluates the bar and
/// not the pane (and its surface) around it.
struct TerminalStatusBarAdapter: View {
  let target: TerminalTarget
  let tabID: TerminalTab.ID
  /// The pane's terminal, or nil for a non-terminal (diff / file / changeset) pane — which shows no
  /// cwd, run state or diagnosis, only the branch.
  let state: TerminalState?
  /// The pane's terminal surface, for the diagnosis' "Insert fix" and Investigate; nil with `state`.
  var surface: GhosttySurfaceView?
  @Environment(\.paneHost) private var host
  @EnvironmentObject var runCommand: RunCommandController
  @EnvironmentObject var codingAgentManager: TerminalCodingAgentManager
  /// Observed here too (`DetachedSessionsButton` already observes it) so a divider next to that
  /// button can know whether it's actually showing anything.
  @ObservedObject private var sessionsStore = DetachedSessionList.shared

  var body: some View {
    Gated(
      model: model, target: target, tabID: tabID, surface: surface.map(ObjectIdentifier.init),
      actions: actions
    )
    .equatable()
  }

  /// The bar behind an equality gate, so a store publish that changes nothing this pane shows
  /// skips the bar's body. The gate covers what the closures capture as well as the model:
  /// `actions` and the slot close over `target`, `tabID` and `surface`, so a gate on the model
  /// alone could keep one that types into the wrong surface. `@State` and the environment still
  /// invalidate the bar past the gate.
  private struct Gated: View, Equatable {
    let model: TerminalStatusBarModel
    let target: TerminalTarget
    let tabID: TerminalTab.ID
    /// The surface `actions` holds, by identity.
    let surface: ObjectIdentifier?
    let actions: TerminalStatusBarActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.model == rhs.model && lhs.target == rhs.target && lhs.tabID == rhs.tabID
        && lhs.surface == rhs.surface
    }

    var body: some View {
      TerminalStatusBar(model: model, actions: actions) {
        DetachedSessionsButton(target: target)
      }
    }
  }

  private var model: TerminalStatusBarModel {
    // The run state is read only on the run tab, and the outcome only once it has stopped, so a
    // pane observes no more of the run controller than it shows.
    let isRunTab = state != nil && runCommand.runTabID(for: target.id) == tabID
    let run = isRunTab ? runCommand.runStates[target.id] : nil
    let runOutcome: RunCommandController.RunOutcome? =
      if case .stopped = run { runCommand.runOutcomes[target.id] } else { nil }
    return TerminalStatusBarModel(
      // The surface is the live read for a detached pane, whose `state` is the copy taken when its
      // window opened (`DetachedPaneController` reads its content once).
      cwd: state.flatMap { $0.hostCwd ?? $0.cwd ?? surface?.lastKnownCwd },
      cwdIsOnHost: state?.hostCwd != nil,
      branch: host.branchLabel(for: target) ?? state?.liveBranch,
      diagnosis: state == nil ? nil : codingAgentManager.banners[tabID],
      usage: state.flatMap { state in
        guard let backend = state.activeCodingAgentBackend, !target.isRemoteWorkroom else {
          return nil
        }
        return .init(backend: backend, claudeProfile: state.claudeProfile)
      },
      hasDetachedSessions: !sessionsStore.detached(for: target.id.encoded).isEmpty,
      run: run,
      runOutcome: runOutcome
    )
  }

  private var actions: TerminalStatusBarActions {
    TerminalStatusBarActions(
      diagnose: { [codingAgentManager, tabID, target] in
        codingAgentManager.diagnose(tab: tabID, target: target.id)
      },
      insertFix: { [surface] fix in surface?.sendText(fix) },
      investigate: { [host, codingAgentManager, tabID, target, surface] bannerState in
        host.investigate(bannerState, in: target, surface: surface)
        codingAgentManager.dismiss(tab: tabID)
      },
      dismissDiagnosis: { [codingAgentManager, tabID] in codingAgentManager.dismiss(tab: tabID) }
    )
  }
}

// MARK: - Shared segments (a pane's bar and the Quick Terminal's footer)

extension View {
  /// The status bar's own chrome, so every footer reads alike.
  func statusBarChrome() -> some View { modifier(StatusBarChrome()) }
}

private struct StatusBarChrome: ViewModifier {
  @Environment(\.themeTokens) private var tokens

  func body(content: Content) -> some View {
    // `.subheadline` (11pt) — the middle of the two sizes this bar has worn. `.caption` (10pt) was
    // too small to read at a glance for what the bar carries (a pane's live state: branch, run
    // state); `.callout` (12pt) read as content rather than chrome.
    content.font(.subheadline)
      .foregroundStyle(tokens.fgMuted)
      .lineLimit(1)
      .padding(.horizontal, 10)
      // Fixed, not vertical padding: the bar's height must not vary with its content (an icon, a
      // `ProgressView`) or a pane would resize as a diagnosis arrives. Held at 28pt across the font
      // change so panes don't reflow — the 11pt text just sits in a little more air.
      .frame(height: TerminalPanelMetrics.chromeRowHeight)
      .frame(maxWidth: .infinity)
      .background { SidebarBackground() }
      .overlay(alignment: .top) { tokens.border.frame(height: 1) }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("terminal.statusBar")
  }
}

/// A thin vertical rule between two segments, shorter than the 28pt bar so it reads as a
/// separator rather than a full-height rail.
struct StatusBarDivider: View {
  @Environment(\.themeTokens) private var tokens

  var body: some View { tokens.border.frame(width: 1, height: 14) }
}

/// The current branch. Middle-truncates: a long branch name's ends are the informative part. The
/// file path that used to lead this row moved to the pane's own title bar in issue #150
/// (`PaneTitlePresentation` kept its `.head` truncation for the same reason it had one here — a
/// repo-relative path's discriminating part is its tail).
struct StatusBarBranchSegment: View {
  let branch: String

  var body: some View {
    Label {
      Text(branch).truncationMode(.middle)
    } icon: {
      Image(systemName: "arrow.triangle.branch")
    }
    .labelStyle(.titleAndIcon)
    .help("Current branch")
    .accessibilityLabel("Branch \(branch)")
  }
}

/// A pane's cwd, and the two things you want from a path you can see: copy it, or reveal it
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
struct StatusBarCwdSegment: View {
  let cwd: String
  /// `cwd` is on a remote pane's host (#239), which names nothing on this Mac.
  let onHost: Bool
  /// The AppKit view the cwd menu pops out of — see `MenuAnchor`.
  @State private var menuAnchor: NSView?
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    Button {
      popMenu()
    } label: {
      Label {
        // Not `~`-abbreviated on a host: this Mac's home says nothing about the host's.
        Text(onHost ? cwd : Self.abbreviate(cwd)).truncationMode(.middle)
      } icon: {
        Image(systemName: "folder")
      }
      .labelStyle(.titleAndIcon)
      // Explicit, not inherited: a `Button`'s label doesn't pick up the bar's ambient
      // `foregroundStyle`, so without this the segment reads brighter than its neighbours.
      .foregroundStyle(tokens.fgMuted)
    }
    .buttonStyle(StatusBarSegmentButtonStyle())
    .background(MenuAnchor(view: $menuAnchor))
    .help(cwd)
    .accessibilityLabel("Working directory \(cwd)")
    .accessibilityIdentifier("terminal.statusBar.cwd")
  }

  /// `~`-abbreviate a home-relative path; leave others untouched. Truncation is left to the label.
  static func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }

  /// On a host there is nothing for Finder to reveal. Revealing it would select whatever this Mac
  /// happens to have at that path.
  private func popMenu() {
    let menu = NSMenu()
    menu.addItem(
      ClosureMenuItem(title: "Copy to Clipboard") { [cwd, menuAnchor] in
        CopyConfirmation.copy(cwd, relativeTo: menuAnchor)
      })
    // `activateFileViewerSelecting`, matching the wording and the Room menu's own "Reveal in Finder"
    // (which reveals the selected target's directory the same way): the directory comes up selected in
    // its parent. `NSWorkspace.open` would open the folder's own window instead — a different verb
    // than the one this item promises.
    if !onHost {
      menu.addItem(
        ClosureMenuItem(title: "Reveal in Finder") { [cwd] in
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
        })
    }
    // At the cursor, like a context menu — but popped out of a real view rather than the tempting
    // `at: NSEvent.mouseLocation, in: nil` (screen coordinates, no anchor needed). That form does
    // nothing at all when the click is synthesized: `StatusBarCwdUITests` clicked the segment and no
    // menu ever appeared. Anchored to a view it opens either way, so the cursor's screen point is
    // converted into the anchor's own coordinates instead.
    if let anchor = menuAnchor, let window = anchor.window {
      let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
      menu.popUp(positioning: nil, at: anchor.convert(inWindow, from: nil), in: anchor)
    } else {
      menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
struct StatusBarSegmentButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverWell(configuration: configuration)
  }

  private struct HoverWell: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themeTokens) private var tokens

    var body: some View {
      configuration.label
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(
              tokens.hover
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

#if DEBUG
  #Preview("Status bar") {
    let actions = TerminalStatusBarActions(
      diagnose: {}, insertFix: { _ in }, investigate: { _ in }, dismissDiagnosis: {})
    VStack(spacing: 12) {
      // A terminal on its run tab, with a failed command diagnosed.
      TerminalStatusBar(
        model: TerminalStatusBarModel(
          cwd: NSHomeDirectory() + "/dev/platform", branch: "fix-auth",
          diagnosis: .awaitingDiagnose(
            FailedCommand(
              command: "npm test", cwd: nil, exitCode: 1, shell: "zsh", output: "1 failing",
              isRunTab: false, isRemote: false)),
          run: .running(tab: UUID(), interrupted: false)),
        actions: actions
      ) { EmptyView() }
      // A content pane: the branch alone.
      TerminalStatusBar(model: TerminalStatusBarModel(branch: "main"), actions: actions) {
        EmptyView()
      }
    }
    .frame(width: 640)
  }
#endif
