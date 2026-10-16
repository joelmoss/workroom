import DesignSystem
import SwiftUI

/// A create's pane (#483): a GitHub Actions-style checklist of the steps its kind runs, each with its
/// time and its log one click away, and on failure a footer with what to do next. Shown bare, with no
/// title bar, tab bar or footer, from the click until the run ends (`TargetTerminalDetail`). What it
/// says is `CreationPanePresentation`'s.
///
/// Layout (design D4): one continuous `panel` surface, a leading column at most 640pt wide holding the
/// header and the rows. With a row's log open, the log fills what is left and the rows below it sit
/// on the pane's bottom edge (D9); only below a 3-line log does the whole column scroll.
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
  private let theme = ThemeService.shared

  private typealias P = CreationPanePresentation
  /// Below this a pane is narrow (design D15): tighter insets and a stacked footer.
  static let narrowWidth: CGFloat = 420
  private static let columnWidth: CGFloat = 640
  /// Three log lines and the log's padding: the open log shrinks no further before the column
  /// scrolls.
  private static let minimumLogHeight: CGFloat = 3 * 16 + 2 * CreationLogView.padding
  /// The space above and below an open log.
  private static let logPadding: CGFloat = 4

  var body: some View {
    GeometryReader { geo in
      let narrow = geo.size.width < Self.narrowWidth
      VStack(spacing: 0) {
        checklist(inset: narrow ? 16 : 32)
        if let footer = P.footer(for: run.outcome) {
          CreationFailureFooter(footer: footer, narrow: narrow, inset: narrow ? 16 : 32) {
            perform($0)
          }
          .transition(.move(edge: .bottom))
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: run.outcome)
    }
    .background(theme.tokens.panel)
    // Return and Escape reach the footer only while focus is inside this pane (D16): another pane's
    // failed create never answers them, as a window-wide `.keyboardShortcut` would.
    .onKeyPress(.return) { answer { $0.primary } }
    .onKeyPress(.escape) { answer { $0.escapeAction } }
  }

  // MARK: Checklist

  private func checklist(inset: CGFloat) -> some View {
    GeometryReader { geo in
      // A ScrollView offers its content unlimited height, so the column's height is worked out here
      // (D9): the pane's, with the log taking what the header and rows leave.
      let layout = P.openLogLayout(
        pane: geo.size.height - 2 * inset,
        fixed: headerHeight + rowHeights.values.reduce(0, +) + Self.logPadding * 2,
        logContent: logContentHeight, minimum: Self.minimumLogHeight)
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
            if expanded == step.id {
              CreationLogView(
                lines: step.log, isFinished: !Self.isActive(step),
                onContentHeight: { logContentHeight = $0 }
              )
              .id(step.id)
              .frame(height: layout.log)
              .padding(.leading, CreationStepRow.titleInset)
              .padding(.vertical, Self.logPadding)
              // What a short log leaves, which puts the rows below on the pane's bottom edge.
              Spacer(minLength: 0)
            }
          }
        }
        // The checklist's container sits on the column, the first view here with several children: a
        // container with a single child folds into it, and the bare pane's `workroom.pane` container
        // (`WorkroomPaneLeaf`) folds into the same element and takes its identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CreationPane")
        .frame(maxWidth: Self.columnWidth, alignment: .leading)
        .frame(height: expanded == nil ? nil : layout.column, alignment: .top)
        .padding(inset)
        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
      }
      .scrollBounceBehavior(.basedOnSize)
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
      let result = P.handle(key, focused: focused, expanded: expanded, rows: run.steps.map(\.id))
      focusedRow = result.focused
      setExpanded(result.expanded)
      return .handled
    }
  }

  /// Two lines at a fixed height from the first frame (design D5); the name replaces "New workroom"
  /// in place, and nothing here changes on failure.
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
      isExpanded: expanded == step.id
    ) {
      focusedRow = step.id
      setExpanded(expanded == step.id ? nil : step.id)
    }
    .focusable()
    .focused($focusedRow, equals: step.id)
  }

  /// The row whose log is open: one at a time, and none until the user opens one (D7). Kept on this
  /// window's store, not in the view, so it survives the pane's id becoming the workroom's.
  private var expanded: String? { store.expandedCreationLogs[run.id] }

  private func setExpanded(_ id: String?) {
    guard id != expanded else { return }
    logContentHeight = 0
    store.expandedCreationLogs[run.id] = id
  }

  private static func isActive(_ step: CreationStep) -> Bool {
    step.state == .running || step.state == .waitingForUser
  }

  // MARK: Actions

  private func answer(_ action: (P.Footer) -> P.Action?) -> KeyPress.Result {
    guard let footer = P.footer(for: run.outcome), let chosen = action(footer) else {
      return .ignored
    }
    perform(chosen)
    return .handled
  }

  private func perform(_ action: P.Action) {
    switch action {
    case .tryAgain: Task { await store.retryCreation(run) }
    case .close: store.closeCreation(run)
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
  let isExpanded: Bool
  let toggle: () -> Void
  private let theme = ThemeService.shared

  /// Where a row's title starts, which an open log lines up with.
  static let titleInset: CGFloat = glyphWidth + spacing
  private static let glyphWidth: CGFloat = 18
  private static let spacing: CGFloat = 10
  /// The timing column's width: fixed, so the timer never jitters as a split is resized (D15).
  private static let durationWidth: CGFloat = 56
  /// A row's widest: its glyph, title, caption and duration, inside the 640pt column.
  private static let maxWidth: CGFloat = 420

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
    }
    // Narrower than the column (owner), so a wide pane's durations sit near their titles and still
    // line up; a narrower pane's row fills it.
    .frame(maxWidth: Self.maxWidth, alignment: .leading)
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .onTapGesture(perform: toggle)
    // The full title and caption, which truncate in a narrow pane (D15).
    .help(
      [step.title, CreationPanePresentation.caption(for: step)].compactMap { $0 }
        .joined(separator: "\n")
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(CreationPanePresentation.accessibilityLabel(for: step))
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityHint(CreationPanePresentation.caption(for: step) ?? "")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: isExpanded ? "Collapse log" : "Expand log", toggle)
    .accessibilityIdentifier("CreationPane.step.\(step.id)")
  }

  private var isActive: Bool { step.state == .running || step.state == .waitingForUser }

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

  private var isSkipped: Bool {
    if case .skipped = step.state { return true }
    return false
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
  let lines: [String]
  let isFinished: Bool
  let onContentHeight: (CGFloat) -> Void
  /// Opens at the latest output, where a running or failed step's news is.
  @State private var position = ScrollPosition(edge: .bottom)
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
      Group {
        if lines.isEmpty {
          Text(ScriptLogContent.emptyText(isFinished: isFinished))
            .font(.callout)
            .foregroundStyle(theme.tokens.fgMuted)
        } else {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
              Text(lines[index].isEmpty ? " " : lines[index])
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Self.padding)
    }
    .scrollPosition($position)
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

/// The failure footer (design D3), pinned to the pane's bottom edge: the reason in red on the left,
/// the buttons on the right. In a narrow pane (D15) the reason takes its own line, up to two, with the
/// buttons below it.
private struct CreationFailureFooter: View {
  let footer: CreationPanePresentation.Footer
  let narrow: Bool
  let inset: CGFloat
  let perform: (CreationPanePresentation.Action) -> Void
  private let theme = ThemeService.shared

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      Group {
        if narrow {
          VStack(alignment: .leading, spacing: 10) {
            reason(lines: 2)
            HStack {
              Spacer()
              buttons
            }
          }
        } else {
          HStack(spacing: 12) {
            reason(lines: 1)
            Spacer(minLength: 8)
            buttons
          }
        }
      }
      .padding(.horizontal, inset)
      .padding(.vertical, 12)
    }
    .background(theme.tokens.panel)
  }

  private func reason(lines: Int) -> some View {
    Text(footer.reason)
      .font(.callout)
      .foregroundStyle(theme.tokens.failure)
      .lineLimit(lines)
      .truncationMode(.tail)
      .help(footer.reason)
  }

  @ViewBuilder private var buttons: some View {
    HStack(spacing: 8) {
      button(footer.secondary)
      // The default: prominent, and answering Return while focus is in this pane (D16).
      button(footer.primary).buttonStyle(.borderedProminent)
    }
    .fixedSize()
  }

  private func button(_ action: CreationPanePresentation.Action) -> some View {
    Button(action.title) { perform(action) }
      .accessibilityIdentifier("CreationPane.\(action.title)")
  }
}
