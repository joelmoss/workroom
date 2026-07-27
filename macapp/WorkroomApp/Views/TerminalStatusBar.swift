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
  @ObservedObject var sessions: TerminalSessions
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var agentManager: TerminalAgentManager
  @State private var showingDiagnosis = false

  private let theme = ThemeService.shared

  /// This pane's live cwd (observed state first, then the surface's last-known); nil for a diff pane.
  private var cwd: String? { state.flatMap { $0.cwd ?? $0.view.lastKnownCwd } }

  private var isRunTab: Bool { state != nil && store.runTabID(for: target.id) == tabID }

  private var diagnosis: AgentBannerState? { state == nil ? nil : agentManager.banners[tabID] }

  var body: some View {
    HStack(spacing: 12) {
      // Path and cwd are mutually exclusive in practice — a content pane has no cwd, a terminal has
      // no file — so they share the leading slot, ahead of the branch.
      pathSegment
      cwdSegment
      branchSegment
      // Diagnosis sits left-aligned right after the branch, not pushed to the far edge.
      if let diagnosis { diagnosisSegment(diagnosis) }
      Spacer(minLength: 8)
      if isRunTab, let run = runStatePresentation { runSegment(run) }
    }
    .font(.caption)
    .foregroundStyle(theme.tokens.fgMuted)
    .lineLimit(1)
    .padding(.horizontal, 10)
    .frame(height: 24)
    .frame(maxWidth: .infinity)
    .background(theme.tokens.bg)
    .overlay(alignment: .top) { theme.tokens.border.frame(height: 1) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal.statusBar")
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

  @ViewBuilder private var cwdSegment: some View {
    if let cwd {
      Label {
        Text(Self.abbreviate(cwd)).truncationMode(.middle)
      } icon: {
        Image(systemName: "folder")
      }
      .labelStyle(.titleAndIcon)
      .help(cwd)
      .accessibilityLabel("Working directory \(cwd)")
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
          let cwd = state?.view.lastKnownCwd ?? target.path
          // Seed the interactive agent with the problem so it can start investigating immediately.
          let command = AgentPrompt.investigateCommandLine(for: bannerState)
          _ = sessions.addRunTab(for: target, command: command, cwd: cwd)
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
