import Defaults
import DesignSystem
import SwiftUI

/// A create's pane (#483): a GitHub Actions-style checklist of the steps its kind runs, each with its
/// time and its log one click away, what to do next on failure under the step that failed, and
/// Done in a footer on success. Shown bare, with no title bar, tab bar or footer, from the click
/// until the run ends (`TargetTerminalDetail`). What it says is `CreationPanePresentation`'s.
///
/// Layout (design D4): one continuous `panel` surface, a leading column at most 640pt wide holding the
/// header and the rows. A row's open log is as tall as its lines, up to what the pane has left, with
/// the rows below straight after it (D9); only below a 3-line log does the whole column scroll.
struct CreationPane: View {
  @ObservedObject var run: CreationRun
  @EnvironmentObject private var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focusedRow: String?
  /// How tall the open log's lines are, so a short log is only as tall as they are.
  @State private var logContentHeight: CGFloat = 0
  /// The header's and each row's height: what the open log leaves room for (D9).
  @State private var headerHeight: CGFloat = 0
  @State private var rowHeights: [String: CGFloat] = [:]
  @State private var noticeHeight: CGFloat = 0
  /// Continue Without Script's confirmation is up.
  @State private var confirmingSkip = false
  private let theme = ThemeService.shared

  private typealias P = CreationPanePresentation
  /// Below this a pane is narrow (design D15): tighter insets and a stacked footer.
  static let narrowWidth: CGFloat = 420
  private static let columnWidth: CGFloat = 640
  /// Three log lines and the log's padding: the open log shrinks no further before the column
  /// scrolls.
  private static let minimumLogHeight: CGFloat = 3 * 13 + 2 * CreationLogView.padding
  /// The failure notice's scroll identity.
  private static let noticeID = "CreationPane.notice"
  /// The space above and below an open log.
  private static let logPadding: CGFloat = 4

  var body: some View {
    GeometryReader { geo in
      let narrow = geo.size.width < Self.narrowWidth
      VStack(spacing: 0) {
        checklist(inset: narrow ? 16 : 32)
        if run.outcome == .succeeded {
          CreationDoneFooter(inset: narrow ? 16 : 32) { store.finishCreation(run) }
            .transition(.move(edge: .bottom))
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: run.outcome)
    }
    .background(theme.tokens.panel)
    // Return and Escape reach the footer only while focus is inside this pane (D16): another pane's
    // failed create never answers them, as a window-wide `.keyboardShortcut` would.
    .onKeyPress(.return) { answer { $0.returnAction } }
    .onKeyPress(.escape) { answer { $0.escapeAction } }
    .confirmationDialog(
      skipConfirmation.title, isPresented: $confirmingSkip, titleVisibility: .visible
    ) {
      Button("Continue Without Script") { Task { await store.skipSetupScript(run) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(skipConfirmation.message)
    }
  }

  private var skipConfirmation: (title: String, message: String) {
    P.skipConfirmation(scriptName: P.footer(for: run.outcome)?.scriptName ?? "workroom_setup")
  }

  private var isDone: Bool { run.outcome == .succeeded }

  // MARK: Checklist

  private func checklist(inset: CGFloat) -> some View {
    GeometryReader { geo in
      // A ScrollView offers its content unlimited height, so the column's height is worked out here
      // (D9): the pane's, with the log taking what the header and rows leave.
      let footer = P.footer(for: run.outcome)
      let logHeight = P.openLogHeight(
        pane: geo.size.height - 2 * inset,
        fixed: headerHeight + run.steps.compactMap { rowHeights[$0.id] }.reduce(0, +)
          + (footer == nil ? 0 : noticeHeight) + Self.logPadding * 2,
        logContent: logContentHeight, minimum: Self.minimumLogHeight)
      // A failure's notice goes under its step's row (owner), above that step's open log.
      let noticeStep = P.noticeStep(in: run.steps) ?? run.steps.last?.id
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 20)
              .onGeometryChange(for: CGFloat.self) {
                $0.size.height
              } action: {
                headerHeight = $0
              }
            ForEach(run.steps) { step in
              row(step)
                .onGeometryChange(for: CGFloat.self) {
                  $0.size.height
                } action: {
                  rowHeights[step.id] = $0
                }
              if let footer, noticeStep == step.id {
                CreationFailureNotice(footer: footer) { perform($0) }
                  .id(Self.noticeID)
                  .padding(.leading, CreationStepRow.titleInset)
                  .padding(.vertical, 6)
                  .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                  } action: {
                    noticeHeight = $0
                  }
              }
              if expanded == step.id {
                CreationLogView(lines: P.log(of: step), onContentHeight: { logContentHeight = $0 })
                  .id(step.id)
                  .frame(height: logHeight)
                  .padding(.leading, CreationStepRow.titleInset)
                  .padding(.vertical, Self.logPadding)
              }
            }
          }
          // The checklist's container sits on the column, the first view here with several children: a
          // container with a single child folds into it, and the bare pane's `workroom.pane` container
          // (`WorkroomPaneLeaf`) folds into the same element and takes its identifier.
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("CreationPane")
          .frame(maxWidth: Self.columnWidth, alignment: .leading)
          .padding(inset)
          .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Return and Escape answer the notice's buttons, so a notice that appears below the fold, in a
        // long list or under an open log, scrolls into view first. Deferred a tick so it is laid out.
        .onChange(of: footer != nil, initial: true) { _, shown in
          guard shown else { return }
          Task { @MainActor in proxy.scrollTo(Self.noticeID) }
        }
      }
    }
    .onKeyPress(keys: [.upArrow, .downArrow, .space, .rightArrow, .leftArrow]) { press in
      guard let focused = focusedRow else { return .ignored }
      let key: P.Key =
        switch press.key {
        case .upArrow: .up
        case .downArrow: .down
        case .rightArrow: .right
        case .leftArrow: .left
        default: .space
        }
      let result = P.handle(
        key, focused: focused, expanded: expanded, rows: run.steps.map(\.id),
        expandable: Set(run.steps.filter(P.isExpandable).map(\.id)))
      focusedRow = result.focused
      setExpanded(result.expanded)
      return .handled
    }
  }

  /// Two lines at a fixed height from the first frame (design D5); the name joins "Creating
  /// workroom…" in place, and stands alone once the create ends.
  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(P.title(of: run))
        .font(.title3.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.tail)
      Text(P.subtitle(of: run))
        .font(.callout)
        .foregroundStyle(theme.tokens.fgDim)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .accessibilityElement(children: .combine)
  }

  private func row(_ step: CreationStep) -> some View {
    CreationStepRow(
      step: step, pullFraction: step.id == "image" ? run.pullFraction : nil,
      isExpandable: P.isExpandable(step), isExpanded: expanded == step.id
    ) {
      focusedRow = step.id
      if P.isExpandable(step) { setExpanded(expanded == step.id ? nil : step.id) }
    }
    .focusable()
    // No focus ring (owner): the open log already shows which row is in use.
    .focusEffectDisabled()
    .focused($focusedRow, equals: step.id)
  }

  /// The row whose log is open: one at a time, and none until the user opens one (D7). Kept on this
  /// window's store, not in the view, so it survives the pane's id becoming the workroom's. Only a
  /// row that `isExpandable` shows its log.
  private var expanded: String? {
    store.expandedCreationLogs[run.id].flatMap { id in
      run.steps.contains { $0.id == id && P.isExpandable($0) } ? id : nil
    }
  }

  private func setExpanded(_ id: String?) {
    guard id != expanded else { return }
    logContentHeight = 0
    store.expandedCreationLogs[run.id] = id
  }

  // MARK: Actions

  private func answer(_ action: (P.Footer) -> P.Action?) -> KeyPress.Result {
    // Return and Escape both answer Done.
    if isDone {
      store.finishCreation(run)
      return .handled
    }
    guard let footer = P.footer(for: run.outcome), let chosen = action(footer) else {
      return .ignored
    }
    perform(chosen)
    return .handled
  }

  private func perform(_ action: P.Action) {
    switch action {
    case .tryAgain: Task { await store.retryCreation(run) }
    case .approveScript: Task { await store.approveSetupScript(run) }
    case .skipScript: confirmingSkip = true
    case .close, .cancel: store.closeCreation(run)
    case .openAnyway: store.openCreatedWorkroomAnyway(run)
    case .deleteWorkroom: deleteWorkroom()
    }
  }

  /// The existing delete confirmation, for the workroom this create made; for one left behind it
  /// takes the machine down too.
  private func deleteWorkroom() {
    guard let project = store.projects.first(where: { $0.path == run.project.path }),
      let workroom = project.workrooms.first(where: { $0.name == run.name })
    else { return }
    store.pendingDeletion = PendingWorkroomDeletion(workroom: workroom, project: project)
  }
}

/// One step of the checklist: its status glyph, its title (and caption), and its time. Every row keeps
/// its height and position in every state; weight and colour are the only emphasis (design D6).
private struct CreationStepRow: View {
  let step: CreationStep
  let pullFraction: Double?
  let isExpandable: Bool
  let isExpanded: Bool
  let toggle: () -> Void
  @State private var hovering = false
  private let theme = ThemeService.shared

  /// Where a row's title starts, which an open log lines up with.
  static let titleInset: CGFloat = glyphWidth + spacing
  private static let glyphWidth: CGFloat = 18
  private static let spacing: CGFloat = 10
  /// The timing column's width: fixed, so the timer never jitters as a split is resized (D15).
  private static let durationWidth: CGFloat = 56
  /// The expand/collapse chevron's slot, after the duration.
  private static let chevronWidth: CGFloat = 12
  /// A row's widest: its glyph, title, caption, duration and chevron, inside the 640pt column.
  private static let maxWidth: CGFloat = 420 + spacing + chevronWidth

  var body: some View {
    HStack(alignment: .top, spacing: Self.spacing) {
      // As tall as the title's line, so the glyph sits beside the title with or without a caption.
      glyph.frame(width: Self.glyphWidth, height: 17)
      VStack(alignment: .leading, spacing: 2) {
        Text(step.title)
          .font(.body.weight(isActive ? .semibold : .regular))
          .foregroundStyle(titleColor)
          .lineLimit(1)
          .truncationMode(.tail)
        if let caption = CreationPanePresentation.caption(for: step) {
          Text(caption)
            .font(.caption)
            .foregroundStyle(captionColor)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      Spacer(minLength: 8)
      // Smaller than the title (owner), centred on the title's line like the glyph, so the row's
      // height never changes.
      trailing
        .font(.subheadline.monospacedDigit())
        .lineLimit(1)
        .frame(minWidth: Self.durationWidth, minHeight: 17, alignment: .trailing)
      // Its slot is always laid out, so the chevron showing on hover never moves the row.
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(theme.tokens.fgDim)
        .frame(width: Self.chevronWidth, height: 17)
        .opacity(hovering && isExpandable ? 1 : 0)
        .accessibilityHidden(true)
    }
    // Narrower than the column (owner), so a wide pane's durations sit near their titles and still
    // line up; a narrower pane's row fills it.
    .frame(maxWidth: Self.maxWidth, alignment: .leading)
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture(perform: toggle)
    // The full title and caption, which truncate in a narrow pane (D15).
    .help(
      [step.title, CreationPanePresentation.caption(for: step)].compactMap { $0 }
        .joined(separator: "\n")
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(CreationPanePresentation.accessibilityLabel(for: step))
    .accessibilityHint(CreationPanePresentation.caption(for: step) ?? "")
    // A row with no log to open isn't a button.
    .accessibilityValue(isExpandable ? isExpanded ? "Expanded" : "Collapsed" : "")
    .accessibilityAddTraits(isExpandable ? .isButton : [])
    .accessibilityActions {
      if isExpandable { Button(isExpanded ? "Collapse log" : "Expand log", action: toggle) }
    }
    .accessibilityIdentifier("CreationPane.step.\(step.id)")
  }

  private var isActive: Bool { step.state == .running || step.state == .waitingForUser }
  private var isSkipped: Bool {
    if case .skipped = step.state { return true }
    return false
  }

  @ViewBuilder private var glyph: some View {
    switch step.state {
    case .pending:
      Image(systemName: "circle").foregroundStyle(theme.tokens.fgDim)
    case .running:
      if let pullFraction {
        // The host image's download, as far as it has got (#309).
        ProgressView(value: pullFraction).progressViewStyle(.circular).controlSize(.small)
      } else {
        ProgressView().controlSize(.small)
      }
    case .waitingForUser:
      Image(systemName: "person.crop.circle.badge.questionmark")
        .foregroundStyle(theme.tokens.accent)
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.tokens.success)
    case .warning:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.tokens.warning)
    case .failed:
      Image(systemName: "xmark.octagon.fill").foregroundStyle(theme.tokens.failure)
    case .skipped:
      Image(systemName: "minus.circle").foregroundStyle(theme.tokens.fgDim)
    }
  }

  @ViewBuilder private var trailing: some View {
    switch step.state {
    case .running:
      // Ticks every second; the row's label never carries it (D17).
      TimelineView(.periodic(from: step.startedAt ?? .now, by: 1)) { context in
        Text(CreationPanePresentation.trailing(for: step, now: context.date) ?? "")
          .foregroundStyle(theme.tokens.accent)
      }
    case .waitingForUser:
      Text("Waiting for you").foregroundStyle(theme.tokens.accent).fixedSize()
    default:
      Text(CreationPanePresentation.trailing(for: step, now: .now) ?? "")
        .foregroundStyle(isSkipped ? theme.tokens.fgDim : theme.tokens.fgMuted)
    }
  }

  private var titleColor: Color {
    switch step.state {
    case .pending, .skipped: theme.tokens.fgDim
    case .failed: theme.tokens.failure
    default: .primary
    }
  }

  private var captionColor: Color {
    if case .warning = step.state { return theme.tokens.warning }
    return theme.tokens.fgDim
  }
}

/// A step's log, open under its row: monospaced, selectable and dense (approved mockup C), on the
/// `surface` fill with a hairline. It follows new lines only while it is scrolled to its bottom; once
/// scrolled up it stays put, with "Jump to latest" over its corner until it is back (design D10).
private struct CreationLogView: View {
  /// Never empty: only a row with output opens (`isExpandable`).
  let lines: ArraySlice<String>
  let onContentHeight: (CGFloat) -> Void
  /// Opens at the latest output, where a running or failed step's news is: through
  /// `defaultScrollAnchor`, as a `ScrollPosition(edge: .bottom)` start left a log a little shorter
  /// than its frame drawing only its last few lines, the lazy rows above it never laid out.
  @State private var position = ScrollPosition()
  @State private var following = true
  private let theme = ThemeService.shared

  static let padding: CGFloat = 10

  private struct Metrics: Equatable {
    var offset: CGFloat
    var visible: CGFloat
    var content: CGFloat
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(lines.indices, id: \.self) { index in
          Text(lines[index].isEmpty ? " " : lines[index])
            .font(.system(.footnote, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Self.padding)
    }
    .scrollPosition($position)
    .defaultScrollAnchor(.bottom)
    .onScrollGeometryChange(for: Metrics.self) { geometry in
      Metrics(
        offset: geometry.contentOffset.y, visible: geometry.containerSize.height,
        content: geometry.contentSize.height)
    } action: { old, new in
      onContentHeight(new.content)
      // New lines move only the content's end; the user's scroll (or a jump) moves the offset.
      if new.offset != old.offset || new.visible != old.visible {
        following = CreationPanePresentation.isAtBottom(
          offset: new.offset, visible: new.visible, content: new.content)
      }
    }
    .onChange(of: lines.count) {
      if following { position.scrollTo(edge: .bottom) }
    }
    .overlay(alignment: .bottomTrailing) {
      if !following {
        Button {
          position.scrollTo(edge: .bottom)
        } label: {
          Image(systemName: "arrow.down.circle.fill")
            .font(.title2)
            .foregroundStyle(theme.tokens.accent)
        }
        .buttonStyle(.plain)
        .help("Jump to latest")
        .accessibilityLabel("Jump to latest")
        .padding(8)
      }
    }
    .background(theme.tokens.surface)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(theme.tokens.border, lineWidth: 1)
    )
  }
}

/// What to do about a failed create, or a script to approve, under the row of the step it is about
/// (owner): the reason first, then the buttons, then any output (the script), so the buttons never
/// sit below something long to read.
private struct CreationFailureNotice: View {
  let footer: CreationPanePresentation.Footer
  let perform: (CreationPanePresentation.Action) -> Void
  private let theme = ThemeService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Wrapped, never truncated (owner): a reason cut short behind a tooltip hid the part that
      // said why.
      Text(footer.reason)
        .font(.callout)
        .foregroundStyle(theme.tokens.failure)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      buttons
      // A script to approve (#363), as it would run, drawn as a file from the Files inspector. A
      // long one scrolls, or opens in a window of its own.
      if let script = footer.script {
        let name = footer.scriptName ?? "workroom_setup"
        VStack(alignment: .trailing, spacing: 4) {
          PaneToolbarButton(
            systemImage: "macwindow.badge.plus", help: "Open in new window",
            accessibilityLabel: "Open script in new window",
            identifier: "CreationPane.script.openInWindow"
          ) { ScriptWindow.show(text: script, name: name) }
          .buttonStyle(
            ToolbarIconButtonStyle(
              wellSize: PaneTitleBarMetrics.wellSize,
              horizontalPadding: PaneTitleBarMetrics.wellPadding)
          )
          .font(.system(size: PaneTitleBarMetrics.glyph))
          ScriptCodeView(text: script, name: name)
            .frame(height: min(ScriptCodeView.contentHeight(of: script), Self.maxScriptHeight))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.tokens.border, lineWidth: 1)
            )
            .accessibilityIdentifier("CreationPane.script")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Room to read a script before approving it; a longer one scrolls.
  private static let maxScriptHeight: CGFloat = 240

  /// In a row, or stacked where a narrow pane has no room for three (D15).
  private var buttons: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) { buttonList }.fixedSize()
      VStack(alignment: .leading, spacing: 8) { buttonList }.fixedSize()
    }
  }

  @ViewBuilder private var buttonList: some View {
    button(footer.secondary)
    if let alternative = footer.alternative { button(alternative) }
    // The default: prominent, and answering Return while focus is in this pane (D16).
    button(footer.primary).buttonStyle(.borderedProminent)
  }

  private func button(_ action: CreationPanePresentation.Action) -> some View {
    Button(action.title) { perform(action) }
      .accessibilityIdentifier("CreationPane.\(action.title)")
  }
}

/// A finished create's footer: Done on the right, and on the left whether a finished checklist closes
/// by itself from now on, as Settings › General also says.
private struct CreationDoneFooter: View {
  let inset: CGFloat
  let done: () -> Void
  @Default(.closeCreationPaneWhenDone) private var closeWhenDone
  private let theme = ThemeService.shared

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 12) {
        Toggle("Close automatically when done", isOn: $closeWhenDone)
          .toggleStyle(.checkbox)
          .font(.callout)
          .accessibilityIdentifier("CreationPane.closeWhenDone")
        Spacer(minLength: 8)
        // The default, answering Return while focus is in this pane (D16).
        Button("Done", action: done)
          .buttonStyle(.borderedProminent)
          .fixedSize()
          .accessibilityIdentifier("CreationPane.Done")
      }
      .padding(.horizontal, inset)
      .padding(.vertical, 12)
    }
    .background(theme.tokens.panel)
  }
}
