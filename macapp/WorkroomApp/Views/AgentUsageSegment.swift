import SwiftUI

/// Provider quota controls shared by every window footer.
struct AgentUsageSegment: View {
  let backend: AgentBackend
  @EnvironmentObject var agentUsage: AgentUsageMonitor
  @EnvironmentObject var claudeUsageBridge: ClaudeUsageBridge
  @State private var usageDetailPinned = false
  @State private var confirmingClaudeUsage = false
  @State private var claudeBridgeError: String?
  private let theme = ThemeService.shared

  var body: some View {
    agentUsageSegment(backend)
      .task { agentUsage.refresh() }
      .alert("Enable Claude usage?", isPresented: $confirmingClaudeUsage) {
        Button("Cancel", role: .cancel) {}
        Button("Enable") {
          do {
            try claudeUsageBridge.enable()
            agentUsage.refresh(userInitiated: true)
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

  private var bridgeErrorPresented: Binding<Bool> {
    Binding(
      get: { claudeBridgeError != nil },
      set: { if !$0 { claudeBridgeError = nil } })
  }

  /// A system dismissal (clicking outside the popover, or Escape) unpins too, so a pin doesn't
  /// linger open after the platform already closed it.
  private var usageDetailPresented: Binding<Bool> {
    Binding(get: { usageDetailPinned }, set: { usageDetailPinned = $0 })
  }

  // MARK: Agent quota

  /// Resolve the bundled provider logos once per launch.
  private static let logoTools: [AgentBackend: RecognizedTool] = Dictionary(
    uniqueKeysWithValues: AgentBackend.allCases.compactMap { backend in
      ToolLogoRegistry.tool(forExecutableName: backend.executable).map { (backend, $0) }
    })

  /// Bar widths for the `ViewThatFits` variants, widest first (the ladder takes the first that fits,
  /// so inverting this order defeats it). Width is the only thing that varies — the segment is the
  /// logo plus bars, with nothing else to shed.
  ///
  /// Which bar is which window is deliberately not drawn. They run shortest-window-first
  /// (`AgentUsageDecoding.normalized` sorts by duration), and the segment's tooltip and popover both
  /// name them in full: the footer is a glance, not a reading.
  ///
  private static let quotaBarWidths: [CGFloat] = [44, 32, 24]

  /// ONE schedule for the whole segment, wrapping the BRANCH and not just the bars.
  ///
  /// The pace pin's offset is a function of wall-clock time — it crosses a bar in the window's own
  /// duration, ~9pt/hour on the 44pt variant for a 5h window — and this bar has no clock of its own
  /// otherwise, so an idle pane would park the pin wherever the last unrelated re-render left it.
  /// The tooltip and the accessibility label read the same `now`, so they can't disagree with the
  /// pin beside them.
  ///
  /// It wraps the branch because `agentUsage.snapshot(for:)` is what applies the freshness filter
  /// (`fresh(at:)` drops windows past their `resetsAt`). Resolving the snapshot outside the schedule
  /// and letting the ticks re-render a captured value means an idle agent that stops rewriting its
  /// quota file keeps an EXPIRED window on screen indefinitely, marching the pin to 100% and
  /// eventually claiming "resets now" — the filter never gets a chance to run.
  /// `AgentUsageMonitor.unavailableReason` exists precisely for that state and says so in its own
  /// doc comment; re-resolving here is what lets the segment reach it.
  ///
  /// It also sits OUTSIDE the `ViewThatFits` below: that view instantiates every child to measure
  /// it, so a `TimelineView` inside the variants would run one schedule per rung. `VCSToolbar`
  /// wraps its whole bar for the same reason.
  @ViewBuilder private func agentUsageSegment(_ backend: AgentBackend) -> some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let now = context.date
      if backend == .claude, claudeUsageBridge.state == .disabled {
        Button("Enable Claude usage…") { confirmingClaudeUsage = true }
          .buttonStyle(StatusBarSegmentButtonStyle())
          .foregroundStyle(theme.tokens.accent)
          .help("Enable the opt-in Claude status-line bridge")
          .accessibilityIdentifier("terminal.statusBar.agentUsage.enableClaude")
      } else if let snapshot = agentUsage.snapshot(for: backend) {
        let label = quotaAccessibilityLabel(snapshot, now: now)
        Button {
          usageDetailPinned.toggle()
        } label: {
          // No `.fixedSize` here, unlike the text ladder this replaced. `fixedSize` proposes an
          // UNSPECIFIED width, so `ViewThatFits` measures the first variant against no constraint,
          // it always "fits", and every later variant is dead code — which is exactly what happened
          // to the old compact half. The modifier existed only to stop a `Text` truncating under
          // this bar's ambient `.lineLimit(1)`; fixed-frame capsules cannot truncate.
          ViewThatFits(in: .horizontal) {
            ForEach(Self.quotaBarWidths, id: \.self) { width in
              quotaBars(snapshot, now: now, barWidth: width)
            }
          }
        }
        .buttonStyle(StatusBarSegmentButtonStyle())
        // The percentages left the segment with issue #168, so hover is the only way to read one
        // without opening the popover.
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("terminal.statusBar.agentUsage")
        .popover(isPresented: usageDetailPresented, arrowEdge: .bottom) {
          AgentUsageDetailView(snapshot: snapshot, now: now)
            .frame(width: AgentUsageDetailView.popoverWidth)
        }
      } else {
        let isLoading = agentUsage.loading.contains(backend)
        // The reason (and the retry) matter only once the read has settled — mid-load there's
        // nothing to explain yet, and a click would just cancel the refresh already running. The
        // reason is re-read on every tick along with the branch above it, so a snapshot that
        // expires while sitting here updates its own explanation.
        let reason = isLoading ? nil : agentUsage.unavailableReason(for: backend)
        Button {
          agentUsage.refresh(userInitiated: true)
        } label: {
          HStack(spacing: 4) {
            if isLoading {
              ProgressView().controlSize(.mini)
              Text("Loading \(backend.displayName) usage…")
            } else {
              Text("\(backend.displayName) usage unavailable")
              Image(systemName: "arrow.clockwise")
            }
          }
        }
        .buttonStyle(StatusBarSegmentButtonStyle())
        .disabled(isLoading)
        .foregroundStyle(theme.tokens.fgDim)
        .help((reason.map { "\($0) Click to refresh." }) ?? "Reading the local quota snapshot…")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          isLoading
            ? "Loading \(backend.displayName) quota usage"
            : "\(backend.displayName) quota usage unavailable. \(reason ?? "") Click to refresh."
        )
        .accessibilityIdentifier("terminal.statusBar.agentUsage.unavailable")
      }
    }
  }

  /// The agent's logo followed by one bar per window. `barWidth` is the only thing the `ViewThatFits`
  /// ladder varies between its variants.
  private func quotaBars(_ snapshot: AgentQuotaSnapshot, now: Date, barWidth: CGFloat) -> some View
  {
    HStack(spacing: 8) {
      agentLogo(snapshot.backend)
      ForEach(snapshot.windows) { window in
        quotaBar(window, now: now, width: barWidth)
      }
    }
  }

  private func quotaBar(_ window: AgentQuotaWindow, now: Date, width: CGFloat) -> some View {
    let pace = window.pace(at: now)
    return QuotaBar(
      usedPercentage: window.usedPercentage,
      markerPercentage: window.sustainablePacePercentage(at: now),
      fill: QuotaBar.fill(for: pace.severity, theme.tokens), width: width, compact: true)
  }

  /// The agent's brand logo, or its name when no logo is bundled — `ToolLogoRegistry` only vends
  /// entries whose imageset actually shipped, so this never renders a blank. Same modifiers as the
  /// tab chip's favicon (`TerminalTabStrip`). No template-tinting risk: neither agent imageset
  /// declares `template-rendering-intent`, so this bar's ambient `foregroundStyle` leaves the brand
  /// colour alone.
  @ViewBuilder private func agentLogo(_ backend: AgentBackend) -> some View {
    if let tool = Self.logoTools[backend] {
      Image(ToolLogoRegistry.assetName(for: tool.id))
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 12, height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    } else {
      Text(backend.displayName)
    }
  }

  /// Takes `now` from the segment's `TimelineView` rather than reading its own clock, so the tooltip
  /// and the VoiceOver label describe the same instant the pace pins are drawn for. The FORMAT is
  /// load-bearing: every `AgentUsageUITests` assertion reads this string.
  private func quotaAccessibilityLabel(_ snapshot: AgentQuotaSnapshot, now: Date) -> String {
    let windows = snapshot.windows.map { window in
      let used = Int(window.usedPercentage.rounded())
      let pace = used == 0 ? "" : ", \(window.pace(at: now).accessibilityDescription)"
      return
        "\(window.kind.compactLabel) quota \(used)% used\(pace), \(window.resetDescription(at: now))"
    }
    return "\(snapshot.backend.displayName) quota. " + windows.joined(separator: ". ")
  }

}
