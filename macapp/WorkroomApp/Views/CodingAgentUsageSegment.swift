import Defaults
import SwiftUI

/// One thing a usage row can show (#480): a reading, a Claude account with none, or the one-time
/// offer to enable the Claude status-line bridge.
enum CodingAgentUsageItem: Identifiable, Equatable {
  /// `label` and `account` are set for a Claude account from cswap; `reason` when its last poll failed.
  case reading(
    CodingAgentQuotaSnapshot, label: String?, account: ClaudeAccount?, reason: String?)
  case unavailable(label: String, account: ClaudeAccount, reason: String)
  case enableClaude

  /// A reading that belongs to no particular account: Codex, or Claude from the bridge.
  static func reading(_ snapshot: CodingAgentQuotaSnapshot) -> CodingAgentUsageItem {
    .reading(snapshot, label: nil, account: nil, reason: nil)
  }

  var id: String {
    switch self {
    case .reading(let snapshot, _, let account, _):
      return account.map { "claude-\($0.slot)" } ?? snapshot.backend.rawValue
    case .unavailable(_, let account, _): return "claude-\(account.slot)"
    case .enableClaude: return "enable-claude"
    }
  }

  var isClaudeAccount: Bool {
    switch self {
    case .reading(_, _, let account, _): return account != nil
    case .unavailable: return true
    case .enableClaude: return false
    }
  }
}

/// A coding agent's usage as a footer segment: its logo, an account label for a Claude account from cswap,
/// then one bar per window. Clicking opens the detail popover, which polls for a fresh reading.
struct CodingAgentUsageSegment: View {
  let item: CodingAgentUsageItem
  let barWidth: CGFloat
  /// Whether the account label is drawn; the pane footer drops it before anything else.
  var showsLabel = true
  let now: Date
  @EnvironmentObject var agentUsage: CodingAgentUsageMonitor
  @EnvironmentObject var claudeUsageBridge: ClaudeUsageBridge
  @State private var usageDetailPinned = false
  @State private var confirmingClaudeUsage = false
  @State private var claudeBridgeError: String?
  private let theme = ThemeService.shared

  var body: some View {
    segment
      .alert("Enable Claude usage?", isPresented: $confirmingClaudeUsage) {
        Button("Cancel", role: .cancel) {}
        // Declines for good: the footer stops offering it; Settings ▸ AI Agents ▸ Usage still can.
        Button("Don’t Ask Again") { Defaults[.claudeUsageDeclined] = true }
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
            + "unchanged to your current command. You can remove it from the usage popover."
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

  @ViewBuilder private var segment: some View {
    switch item {
    case .enableClaude:
      Button {
        confirmingClaudeUsage = true
      } label: {
        HStack(spacing: 6) {
          Self.logo(.claude)
          Text("Enable usage…")
        }
      }
      // At least as wide as the logo-and-bars segment that replaces it, so enabling moves nothing
      // at the wider bar widths; never narrower than its own label.
      .frame(minWidth: 18 + barWidth * 2 + 8, alignment: .leading)
      .buttonStyle(StatusBarSegmentButtonStyle())
      .foregroundStyle(theme.tokens.accent)
      .help("Enable Claude usage")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Enable Claude usage")
      .accessibilityIdentifier("terminal.statusBar.agentUsage.enableClaude")

    case .reading(let snapshot, let label, _, _):
      let spoken = Self.quotaAccessibilityLabel(snapshot, accountLabel: label, now: now)
      Button {
        usageDetailPinned.toggle()
      } label: {
        HStack(spacing: 6) {
          Self.logo(snapshot.backend)
          if showsLabel, let label { Text(label) }
          HStack(spacing: 8) {
            ForEach(snapshot.windows) { window in
              let shown = Self.displayed(window, now: now)
              QuotaBar(
                usedPercentage: shown.usedPercentage, markerPercentage: shown.marker ?? 0,
                fill: QuotaBar.fill(for: window.pace(at: now).severity, theme.tokens),
                width: barWidth, compact: true, showsMarker: shown.marker != nil)
            }
          }
          .opacity(snapshot.isStale(at: now) ? 0.5 : 1)
        }
      }
      .buttonStyle(StatusBarSegmentButtonStyle())
      // The percentages left the segment with issue #168, so hover is the only way to read one
      // without opening the popover.
      .help(spoken)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spoken)
      .accessibilityIdentifier("terminal.statusBar.agentUsage")
      .popover(isPresented: usageDetailPresented, arrowEdge: .bottom) { detail }

    case .unavailable(let label, _, let reason):
      Button {
        usageDetailPinned.toggle()
      } label: {
        HStack(spacing: 6) {
          Self.logo(.claude)
          if showsLabel { Text(label) }
          Image(systemName: "exclamationmark.circle")
            .imageScale(.small)
          // One empty track standing in for both bars, so recovery changes nothing's width.
          Capsule().fill(theme.tokens.fgDim.opacity(0.35)).frame(width: barWidth * 2 - 6, height: 5)
        }
        .foregroundStyle(theme.tokens.fgDim)
      }
      .buttonStyle(StatusBarSegmentButtonStyle())
      .help("\(label) usage unavailable")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Self.unavailableAccessibilityLabel(accountLabel: label, reason: reason))
      .accessibilityIdentifier("terminal.statusBar.agentUsage.unavailable")
      .popover(isPresented: usageDetailPresented, arrowEdge: .bottom) { detail }
    }
  }

  /// The popover: who the reading is for, why there is none, the windows, and its age with a way
  /// to read again. Opening it polls, so what it shows is as fresh as cswap and Codex allow.
  private var detail: some View {
    CodingAgentUsagePopover(item: item, now: now)
      .frame(width: CodingAgentUsageDetailView.popoverWidth)
      .onAppear { agentUsage.poll() }
  }

  // MARK: Presentation rules

  /// Resolve the bundled provider logos once per launch.
  private static let logoTools: [CodingAgentBackend: RecognizedTool] = Dictionary(
    uniqueKeysWithValues: CodingAgentBackend.allCases.compactMap { backend in
      ToolLogoRegistry.tool(forExecutableName: backend.executable).map { (backend, $0) }
    })

  /// The agent's brand logo, or its name when no logo is bundled — `ToolLogoRegistry` only vends
  /// entries whose imageset actually shipped, so this never renders a blank. No template-tinting
  /// risk: neither agent imageset declares `template-rendering-intent`.
  @ViewBuilder static func logo(_ backend: CodingAgentBackend) -> some View {
    if let tool = logoTools[backend] {
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

  /// Bar widths a row steps through, widest first. Which bar is which window is deliberately not
  /// drawn: they run shortest-window-first, and the tooltip and popover both name them in full.
  static let barWidths: [CGFloat] = [44, 32, 24]

  static let maximumLabelLength = 8

  /// Each account's footer label: its cswap alias capped at 8 characters (tail-truncated), its
  /// slot when two share an alias, and `#<slot>` when it has none.
  static func accountLabels(_ accounts: [ClaudeAccount]) -> [Int: String] {
    func shortened(_ alias: String) -> String {
      alias.count > maximumLabelLength
        ? String(alias.prefix(maximumLabelLength - 1)) + "…" : alias
    }
    let counts = Dictionary(
      accounts.compactMap(\.alias).map { (shortened($0), 1) }, uniquingKeysWith: +)
    return Dictionary(
      uniqueKeysWithValues: accounts.map { account in
        guard let alias = account.alias, !alias.isEmpty else {
          return (account.slot, "#\(account.slot)")
        }
        let label = shortened(alias)
        return (account.slot, (counts[label] ?? 0) > 1 ? "\(label) #\(account.slot)" : label)
      })
  }

  /// What a window draws: past its reset it is empty, with no pace pin, because nothing has been
  /// read since and the pin would sit at a meaningless 100%.
  static func displayed(_ window: CodingAgentQuotaWindow, now: Date) -> (
    usedPercentage: Double, marker: Double?
  ) {
    guard window.isFresh(at: now) else { return (0, nil) }
    return (window.usedPercentage, window.sustainablePacePercentage(at: now))
  }

  /// Takes `now` from the row's `TimelineView` rather than reading its own clock, so the tooltip
  /// and the VoiceOver label describe the same instant the pace pins are drawn for. The FORMAT is
  /// load-bearing: every `CodingAgentUsageUITests` assertion reads this string, and
  /// `CodingAgentUsageSegmentLabelTests` pins its branches. Without `accountLabel` it reads exactly
  /// as it did before accounts existed.
  static func quotaAccessibilityLabel(
    _ snapshot: CodingAgentQuotaSnapshot, accountLabel: String? = nil, now: Date
  ) -> String {
    let windows = snapshot.windows.map { window in
      guard window.isFresh(at: now) else {
        return "\(window.kind.compactLabel) quota reset, nothing read since"
      }
      let used = Int(window.usedPercentage.rounded())
      let pace = used == 0 ? "" : ", \(window.pace(at: now).accessibilityDescription)"
      return
        "\(window.kind.compactLabel) quota \(used)% used\(pace), \(window.resetDescription(at: now))"
    }
    let name = [snapshot.backend.displayName, accountLabel].compactMap { $0 }.joined(separator: " ")
    var label = "\(name) quota. " + windows.joined(separator: ". ")
    if snapshot.isStale(at: now) { label += ". Updated \(age(of: snapshot, now: now))." }
    return label
  }

  static func unavailableAccessibilityLabel(accountLabel: String, reason: String) -> String {
    "Claude \(accountLabel) usage unavailable. \(reason)"
  }

  /// "10 minutes ago", against the caller's `now` rather than the wall clock.
  static func age(of snapshot: CodingAgentQuotaSnapshot, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: snapshot.capturedAt, relativeTo: now)
  }

  /// What a footer shows, in order: every Claude account cswap manages (or, without cswap, the bridge's one
  /// reading or its Enable offer), then Codex. A backend with no reading at all is absent.
  @MainActor static func items(
    monitor: CodingAgentUsageMonitor, bridgeState: ClaudeUsageBridge.State, claudeSeen: Bool,
    enableDeclined: Bool
  ) -> [CodingAgentUsageItem] {
    var items: [CodingAgentUsageItem] = []
    if let accounts = monitor.claudeAccounts {
      let labels = accountLabels(accounts.map(\.account))
      for usage in accounts {
        items.append(item(for: usage, labels: labels, pollFailure: monitor.pollFailures[.claude]))
      }
    } else if monitor.claudeUsesBridge {
      if bridgeState == .disabled {
        if claudeSeen, !enableDeclined { items.append(.enableClaude) }
      } else if let snapshot = monitor.snapshot(for: .claude) {
        items.append(.reading(snapshot))
      }
    }
    if let snapshot = monitor.snapshot(for: .codex) { items.append(.reading(snapshot)) }
    return items
  }

  /// A cswap account's item: its reading, or why there is none.
  static func item(
    for usage: ClaudeAccountUsage, labels: [Int: String], pollFailure: String?
  ) -> CodingAgentUsageItem {
    let label = labels[usage.account.slot] ?? "#\(usage.account.slot)"
    let reason = usage.unavailableReason ?? pollFailure
    if let snapshot = usage.snapshot {
      return .reading(snapshot, label: label, account: usage.account, reason: reason)
    }
    return .unavailable(
      label: label, account: usage.account,
      reason: reason ?? "cswap has no reading for this account yet.")
  }
}

/// The window footer's usage (#480): every item, fitted as one row. All segments step their bars
/// down together; if the row still doesn't fit, trailing Claude accounts collapse into a "+N" chip.
struct CodingAgentUsageRow: View {
  @EnvironmentObject var agentUsage: CodingAgentUsageMonitor
  @EnvironmentObject var claudeUsageBridge: ClaudeUsageBridge
  @ObservedObject private var registry = WindowRegistry.shared
  @Default(.claudeSessionSeen) private var claudeSessionSeen
  @Default(.claudeUsageDeclined) private var claudeUsageDeclined

  private struct Variant: Hashable {
    let barWidth: CGFloat
    /// How many Claude accounts are drawn; the rest go behind "+N".
    let claudeShown: Int
  }

  var body: some View {
    // ONE schedule for the whole row, outside the `ViewThatFits`: that view instantiates every
    // variant to measure it, so a schedule inside would run once per variant.
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let now = context.date
      let items = CodingAgentUsageSegment.items(
        monitor: agentUsage, bridgeState: claudeUsageBridge.state,
        claudeSeen: claudeSessionSeen || registry.activeAgentBackends.contains(.claude),
        enableDeclined: claudeUsageDeclined)
      ViewThatFits(in: .horizontal) {
        ForEach(Self.variants(claudeAccounts: items.filter(\.isClaudeAccount).count), id: \.self) {
          variant in
          row(items, variant: variant, now: now)
        }
      }
    }
    .task { agentUsage.refresh() }
    .onChange(of: registry.activeAgentBackends.contains(.claude), initial: true) { _, running in
      if running, !claudeSessionSeen { claudeSessionSeen = true }
    }
  }

  /// Every bar width with all accounts, then, at the narrowest, one fewer account at a time.
  private static func variants(claudeAccounts: Int) -> [Variant] {
    let widths = CodingAgentUsageSegment.barWidths
    var variants = widths.map { Variant(barWidth: $0, claudeShown: claudeAccounts) }
    if claudeAccounts > 1, let narrowest = widths.last {
      for shown in stride(from: claudeAccounts - 1, through: 1, by: -1) {
        variants.append(Variant(barWidth: narrowest, claudeShown: shown))
      }
    }
    return variants
  }

  private func row(_ items: [CodingAgentUsageItem], variant: Variant, now: Date) -> some View {
    var claudeSeen = 0
    var shown: [CodingAgentUsageItem] = []
    var hidden: [CodingAgentUsageItem] = []
    for item in items {
      if item.isClaudeAccount {
        claudeSeen += 1
        if claudeSeen > variant.claudeShown {
          hidden.append(item)
          continue
        }
      }
      shown.append(item)
    }
    // Hidden accounts' chip sits where they would have been: after the shown accounts, before
    // Codex.
    var entries = shown.map(RowEntry.item)
    if !hidden.isEmpty {
      let chipIndex = shown.lastIndex(where: \.isClaudeAccount).map { $0 + 1 } ?? 0
      entries.insert(.overflow(hidden), at: chipIndex)
    }
    return HStack(spacing: 20) {
      ForEach(entries) { entry in
        switch entry {
        case .item(let item):
          CodingAgentUsageSegment(item: item, barWidth: variant.barWidth, now: now)
        case .overflow(let hidden):
          CodingAgentUsageOverflowChip(hidden: hidden, now: now)
        }
      }
    }
    .fixedSize()
  }

  private enum RowEntry: Identifiable {
    case item(CodingAgentUsageItem)
    case overflow([CodingAgentUsageItem])

    var id: String {
      switch self {
      case .item(let item): return item.id
      case .overflow: return "overflow"
      }
    }
  }
}

/// "+N" for Claude accounts the row had no room for; it opens a list of them.
struct CodingAgentUsageOverflowChip: View {
  let hidden: [CodingAgentUsageItem]
  let now: Date
  @EnvironmentObject var agentUsage: CodingAgentUsageMonitor
  @State private var open = false
  private let theme = ThemeService.shared

  var body: some View {
    Button("+\(hidden.count)") { open.toggle() }
      .buttonStyle(StatusBarSegmentButtonStyle())
      .foregroundStyle(theme.tokens.fgMuted)
      .help("\(hidden.count) more Claude accounts")
      .accessibilityLabel("\(hidden.count) more Claude accounts")
      .accessibilityIdentifier("terminal.statusBar.agentUsage.more")
      .popover(isPresented: $open, arrowEdge: .bottom) {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(hidden) { item in
              CodingAgentUsagePopover(item: item, now: now)
              Divider()
            }
          }
        }
        .frame(width: CodingAgentUsageDetailView.popoverWidth)
        .frame(maxHeight: 480)
        .onAppear { agentUsage.poll() }
      }
  }
}

/// The detail for one item: who it is, why there is no reading, the windows, and the reading's
/// age with a Refresh. `Remove` for the status-line bridge lives here too, without cswap.
struct CodingAgentUsagePopover: View {
  let item: CodingAgentUsageItem
  let now: Date
  @EnvironmentObject var agentUsage: CodingAgentUsageMonitor
  @EnvironmentObject var claudeUsageBridge: ClaudeUsageBridge
  @State private var removeError: String?
  private let theme = ThemeService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let account {
        VStack(alignment: .leading, spacing: 2) {
          Text(
            [account.alias, "#\(account.slot)"].compactMap { $0 }.joined(separator: " ")
          )
          .font(.headline)
          Text(
            [account.organizationName, account.email.isEmpty ? nil : account.email]
              .compactMap { $0 }.joined(separator: " · ")
          )
          .font(.caption)
          .foregroundStyle(theme.tokens.fgMuted)
        }
        .padding([.horizontal, .top], 14)
      }
      if let reason {
        Label(reason, systemImage: "exclamationmark.circle")
          .font(.callout)
          .foregroundStyle(theme.tokens.warning)
          .padding([.horizontal, .top], 14)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let snapshot {
        CodingAgentUsageDetailView(snapshot: snapshot, now: now)
      }
      HStack {
        Text(status)
          .font(.caption)
          .foregroundStyle(theme.tokens.fgMuted)
        Spacer()
        if isBridgeReading, claudeUsageBridge.state == .needsRepair {
          // Workroom's command is installed but its saved metadata is gone (or stale); repairing
          // rebuilds it so Remove can work again.
          Button("Repair") {
            do {
              try claudeUsageBridge.repair()
              agentUsage.refresh()
            } catch {
              removeError = error.localizedDescription
            }
          }
          .help("Rebuild Workroom's Claude status-line bridge")
        } else if isBridgeReading {
          Button("Remove") {
            do {
              try claudeUsageBridge.disable()
              agentUsage.refresh()
            } catch {
              removeError = error.localizedDescription
            }
          }
          .help("Remove Workroom's Claude status-line bridge and restore your own status line")
        }
        Button {
          agentUsage.refresh()
          agentUsage.poll()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(agentUsage.isPolling)
        .help("Refresh")
        .accessibilityLabel("Refresh")
      }
      .padding(14)
    }
    .alert(
      "The Claude bridge wasn’t changed",
      isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(removeError ?? "")
    }
  }

  private var snapshot: CodingAgentQuotaSnapshot? {
    if case .reading(let snapshot, _, _, _) = item { return snapshot }
    return nil
  }

  private var account: ClaudeAccount? {
    switch item {
    case .reading(_, _, let account, _): return account
    case .unavailable(_, let account, _): return account
    case .enableClaude: return nil
    }
  }

  private var reason: String? {
    switch item {
    case .reading(_, _, _, let reason): return reason
    case .unavailable(_, _, let reason): return reason
    case .enableClaude: return nil
    }
  }

  /// Claude's reading came from the status-line bridge (no cswap), so `Remove` applies.
  private var isBridgeReading: Bool {
    if case .reading(let snapshot, _, nil, _) = item, snapshot.backend == .claude,
      claudeUsageBridge.state != .disabled
    {
      return true
    }
    return false
  }

  private var status: String {
    if agentUsage.isPolling { return "Updating…" }
    guard let snapshot else { return "No reading yet" }
    return "Updated \(CodingAgentUsageSegment.age(of: snapshot, now: now))"
  }
}

/// A pane footer's usage (#480): only the coding agent running in that pane, while it runs. In a narrow
/// pane it drops its label, then its bars, so the pane's own state is never truncated for it.
struct PaneUsageSlot: View {
  let backend: CodingAgentBackend
  let claudeProfile: PaneClaudeProfile?
  @EnvironmentObject var agentUsage: CodingAgentUsageMonitor
  @Default(.usageInPaneFooter) private var showsUsage

  var body: some View {
    if showsUsage {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        if let item = Self.item(
          backend: backend, claudeProfile: claudeProfile, monitor: agentUsage)
        {
          ViewThatFits(in: .horizontal) {
            CodingAgentUsageSegment(
              item: item, barWidth: CodingAgentUsageSegment.barWidths[0], now: context.date)
            ForEach(CodingAgentUsageSegment.barWidths, id: \.self) { width in
              CodingAgentUsageSegment(
                item: item, barWidth: width, showsLabel: false, now: context.date)
            }
            Color.clear.frame(width: 0, height: 0)
          }
        }
      }
    }
  }

  /// The pane's reading. Claude needs a profile read (a local daemon-backed pane); with cswap it
  /// picks that profile's account, without it the bridge's one reading.
  @MainActor static func item(
    backend: CodingAgentBackend, claudeProfile: PaneClaudeProfile?,
    monitor: CodingAgentUsageMonitor
  ) -> CodingAgentUsageItem? {
    switch backend {
    case .codex:
      return monitor.snapshot(for: .codex).map(CodingAgentUsageItem.reading)
    case .claude:
      guard let claudeProfile else { return nil }
      if let accounts = monitor.claudeAccounts {
        return ClaudeProfileResolution.account(
          forProfile: claudeProfile, accounts: accounts, activeSlot: monitor.claudeActiveSlot
        ).map {
          CodingAgentUsageSegment.item(
            for: $0, labels: CodingAgentUsageSegment.accountLabels(accounts.map(\.account)),
            pollFailure: monitor.pollFailures[.claude])
        }
      }
      guard monitor.claudeUsesBridge else { return nil }
      return monitor.snapshot(for: .claude).map(CodingAgentUsageItem.reading)
    }
  }
}
