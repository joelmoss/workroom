import DesignSystem
import SwiftUI
import WorkroomVCS

/// Record a commit: what will be included, the message, and the failure when there is one.
///
/// **Why a dialog rather than a box in the Changes pane.** Measured against the pane it would have
/// lived in: the composer is ~152pt and `InspectorPanePolicy.expandedMinHeight` leaves 86pt of body,
/// so at the pane's own drag floor the Commit button was below the fold. At a default third of a
/// 900pt window it left two file rows — for a list whose entire job is letting
/// you decide whether committing is safe. Pinning it would also have meant switching Changes to fill
/// hosting, which disables the documented compress-and-scroll valve (`InspectorSplitView`), so a
/// short window would clip the button rather than scroll to it.
///
/// The dialog also deletes state rather than managing it: the draft and the selection live here for
/// the sheet's lifetime, so there is no per-workroom draft store to prune on delete, no recycled
/// workroom name inheriting last week's message, and no two windows racing one `Defaults` dictionary
/// (`AppStore` is per window).
///
/// The cost, accepted: this covers the diff you were reading.
struct CommitSheet: View {
  let pending: PendingCommit
  let onDismiss: () -> Void

  @EnvironmentObject var store: AppStore
  @EnvironmentObject var vcsStatus: VCSStatusService
  @Environment(\.themeTokens) private var tokens

  @State private var summary = ""
  @State private var messageBody = ""
  /// EXCLUSIONS, not selections — see `CommitDraft.selected(from:excluding:)`. A file written while
  /// this sheet is open arrives checked; a file the user unticked stays unticked.
  @State private var excluded: Set<String> = []
  /// The phase machine, the preflight and the commit itself. `@State`, so it lives as long as the
  /// sheet does.
  @State private var flow = CommitFlow()
  @FocusState private var summaryFocused: Bool

  /// Hard cap on rendered rows, matching `ChangesPanel`'s. See `fileSection`.
  private static let renderCap = 200

  private var status: WorkroomStatus? { vcsStatus.workroomStatuses[pending.sid] }

  /// Every changed file.
  private var files: [ChangedFile] { status?.changedFiles ?? [] }

  private var selectedFiles: [ChangedFile] {
    CommitDraft.selected(from: files, excluding: excluded)
  }

  /// How many files the commit would record, WITHOUT building the filtered array.
  ///
  /// `body` asks this several times per evaluation — the caption, the button label, the blocked
  /// reason, the select-all glyph — and re-evaluates on every keystroke, so `selectedFiles.count`
  /// meant several full copies of the change set per typed character.
  private var selectedCount: Int {
    files.reduce(into: 0) { if !excluded.contains($1.path) { $0 += 1 } }
  }

  private var blockedReason: String? {
    CommitDraft.blockedReason(
      summary: summary, selectedCount: selectedCount,
      totalCount: files.count, conflicted: status?.conflicted ?? false, sequencer: flow.sequencer)
  }

  /// The secondary verb rewrites a message and takes no pathspec, so it answers to the repo-state and
  /// summary rules but not the file-count ones — see `CommitDraft.messageOnlyBlockedReason`.
  private var secondaryBlockedReason: String? {
    CommitDraft.messageOnlyBlockedReason(
      summary: summary, conflicted: status?.conflicted ?? false, sequencer: flow.sequencer)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      fileSection
      messageSection
      amendTargetNotice
      if case .confirmingStagedLoss(let paths) = flow.phase { stagedLossNotice(paths) }
      if case .failed(let dialog) = flow.phase { CommitFailureNotice(dialog: dialog) }
      if case .landedThenFailed(let dialog) = flow.phase { CommitFailureNotice(dialog: dialog) }
      if case .outcomeUnknown(let dialog) = flow.phase { CommitFailureNotice(dialog: dialog) }
      Divider()
      buttons
    }
    .padding(20)
    .frame(width: 520)
    .onAppear(perform: prefill)
    // `children: .contain` is load-bearing: an identifier on a plain container makes SwiftUI treat it
    // as ONE element and swallow everything inside, which XCUITest then cannot reach. Same lesson
    // `VCSFailureSheet` records.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("commit.sheet")
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("Commit changes")
        .font(.headline)
        .accessibilityIdentifier("commit.title")
      Spacer(minLength: 0)
      if !files.isEmpty {
        Text(countCaption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("commit.count")
      }
    }
  }

  /// The primary button's label, which becomes an explicit confirmation while the staged-work
  /// warning is up so it can never read as an ordinary Commit.
  private var primaryLabel: String {
    if case .confirmingStagedLoss = flow.phase { return "Commit anyway" }
    return CommitDraft.commitLabel(selectedCount: selectedCount)
  }

  private var countCaption: String {
    "\(selectedCount) of \(files.count) file\(files.count == 1 ? "" : "s")"
  }

  // MARK: Files

  @ViewBuilder private var fileSection: some View {
    if files.isEmpty {
      Text("Nothing has changed in this workroom yet.")
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      // Capped and lazy, for the reason `ChangesPanel.fileList` is: an accidental `node_modules` or
      // vendor drop is thousands of rows, and every one of `summary`, `messageBody` and `excluded` is
      // `@State` — so a non-lazy `ForEach` rebuilt the whole list on the main thread for each
      // keystroke. The count in the button label is the honest total either way: the cap limits what
      // is DRAWN, never what is committed.
      let shown = Array(files.prefix(Self.renderCap))
      VStack(alignment: .leading, spacing: 6) {
        selectAllRow
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { file in
              CommitFileRow(
                file: file,
                isIncluded: !excluded.contains(file.path),
                toggle: { toggle(file) },
                only: { excluded = Set(files.map(\.path)).subtracting([file.path]) })
            }
          }
          .padding(.vertical, 2)
        }
        .frame(maxHeight: 200)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        if files.count > shown.count {
          // Never silent: the rows below the cap are still selected and still committed, and saying
          // so is the difference between a cap and a lie about what is about to be recorded.
          Text(
            "Showing the first \(shown.count) of \(files.count). All \(files.count) are included "
              + "unless you untick them."
          )
          .font(.caption).foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("commit.renderCapNotice")
        }
      }
    }
  }

  /// The staged-work warning: what committing is about to throw away, named, before it happens.
  ///
  /// `git commit --only` builds from the worktree, so for a file you staged with `git add -p` and
  /// then kept editing, the staged version is bypassed and gone — measured, with a clean
  /// `git status` afterwards and no other trace. This is not a refusal (committing from a partly
  /// staged file is legitimate), it is the difference between an informed choice and a silent loss.
  private func stagedLossNotice(_ paths: [String]) -> some View {
    Notice {
      Text(
        paths.count == 1
          ? "1 file has staged changes that differ from the file on disk"
          : "\(paths.count) files have staged changes that differ from the files on disk"
      )
      .font(FontRole.noticeTitle)
      Text(
        "Committing records what is on disk, so the version you staged will be replaced. "
          + "Stage and commit it from the terminal instead if you meant to keep it."
      )
      .font(FontRole.noticeBody).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Text(paths.prefix(5).joined(separator: ", ") + (paths.count > 5 ? ", …" : ""))
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("commit.stagedLoss")
  }

  /// The bulk affordance. Without it, "commit only this file" — an extremely common intent — costs
  /// one click per unwanted file.
  private var selectAllRow: some View {
    let allIncluded = excluded.isEmpty
    return Button {
      excluded = allIncluded ? Set(files.map(\.path)) : []
    } label: {
      HStack(spacing: 6) {
        Image(
          systemName: allIncluded
            ? "checkmark.square.fill" : (selectedCount == 0 ? "square" : "minus.square.fill")
        )
        .font(.callout)
        .foregroundStyle(allIncluded || selectedCount > 0 ? Color.accentColor : .secondary)
        .frame(width: 14)
        Text(allIncluded ? "Deselect all" : "Select all").font(.caption)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Include or exclude every changed file")
    .accessibilityIdentifier("commit.selectAll")
  }

  private func toggle(_ file: ChangedFile) {
    if excluded.contains(file.path) {
      excluded.remove(file.path)
    } else {
      excluded.insert(file.path)
    }
  }

  // MARK: Message

  private var messageSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Summary", text: $summary)
        .textFieldStyle(.roundedBorder)
        .focused($summaryFocused)
        .accessibilityIdentifier("commit.summary")
        .onSubmit { if blockedReason == nil { commitChecking(mode: .commit) } }
      ZStack(alignment: .topLeading) {
        // SwiftUI's TextEditor has no placeholder, so it is drawn behind. `allowsHitTesting(false)`
        // keeps the click through to the editor.
        if messageBody.isEmpty {
          Text("Description (optional)")
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
        }
        TextEditor(text: $messageBody)
          .font(.body)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 80, maxHeight: 140)
          .padding(2)
          .accessibilityIdentifier("commit.description")
      }
      .background(RoundedRectangle(cornerRadius: Radius.s).fill(.quaternary.opacity(0.4)))
      .overlay(RoundedRectangle(cornerRadius: Radius.s).stroke(tokens.border, lineWidth: 1))
    }
  }

  // MARK: Buttons

  private var buttons: some View {
    HStack(spacing: 8) {
      // A persistent line, never a tooltip: nobody hovers a button that looks dead, and a tooltip is
      // unreachable by keyboard and invisible to VoiceOver.
      if let blockedReason, flow.phase == .editing {
        Text(blockedReason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("commit.blocked")
      }
      if flow.phase == .committing {
        ProgressView().controlSize(.small)
        Text("Running hooks…").font(.caption).foregroundStyle(.secondary)
      } else if flow.preflightState.isLoading {
        ProgressView().controlSize(.small)
        Text("Reading repository…").font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("commit.preflight")
      }
      Spacer(minLength: 0)
      // Disabled mid-commit, Escape included. The subprocess cannot be called back — a hook is
      // already running — so dismissing here would only tear down the `@State` the completion writes
      // its outcome into. A rejected hook, a signing failure or a left-behind `index.lock` would then
      // be reported to a view that no longer exists, and the user would be told nothing at all.
      Button(flow.isSpent ? "Close" : "Cancel") { onDismiss() }
        .keyboardShortcut(.cancelAction)
        .disabled(flow.phase == .committing)
        .accessibilityIdentifier("commit.cancel")
      secondaryButton
      Button(primaryLabel) {
        // Once the warning is on screen the same button confirms it — the guard has already told the
        // user what it is about to replace, so a second warning would just be a speed bump.
        if case .confirmingStagedLoss = flow.phase {
          commit(mode: .commit)
        } else {
          commitChecking(mode: .commit)
        }
      }
      .sheetDefaultAction()
      .disabled(
        blockedReason != nil || flow.phase == .committing || flow.isSpent
          || flow.preflightState.isLoading
      )
      .help("Commit the selected files")
      .accessibilityIdentifier("commit.commit")
    }
  }

  /// The second verb, as its own button rather than behind a menu.
  ///
  /// There is exactly ONE alternative, and a menu holding a single item is a click that buys nothing
  /// — it hides the choice behind a disclosure and gives the control no name until you open it.
  /// Naming it outright also stops the "same shape, opposite contract" problem an ellipsis split
  /// button would have had beside `MergeButton`, whose menu CHANGES what its primary does rather than
  /// performing a second action.
  @ViewBuilder private var secondaryButton: some View {
    Button("Amend last commit") {
      commit(mode: .amendMessage)
    }
    .disabled(
      secondaryBlockedReason != nil || flow.phase == .committing || flow.isSpent
        || flow.preflightState.isLoading
    )
    .help(
      flow.amendTarget.map {
        "Replace the message of \($0). Nothing else about that commit changes."
      }
        ?? "Replace the last commit’s message. Nothing else about that commit changes."
    )
    .accessibilityIdentifier("commit.amend")
  }

  /// Which commit Amend would rewrite, named on screen rather than only in a tooltip.
  ///
  /// Amend replaces `HEAD`'s message with whatever is in the summary field — and that field starts
  /// EMPTY and is normally filled with a message written for a NEW commit. So the button one
  /// position left of the default action silently destroys a message the user cannot see, recoverable
  /// only through the reflog. Showing the target is the cheapest thing that makes the trade visible
  /// before the click instead of after it.
  @ViewBuilder private var amendTargetNotice: some View {
    if let amendTarget = flow.amendTarget, flow.phase == .editing {
      Text("“Amend last commit” would replace the message of \(amendTarget)")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("commit.amendTarget")
    }
  }

  // MARK: Actions

  /// The flow's asks, over this window's store for the workroom the sheet was opened for. The draft
  /// is read when the flow asks for it, so a commit started from a completion records what is in
  /// the fields then.
  private var flowContext: CommitFlow.Context {
    .store(
      store, sid: pending.sid,
      draft: {
        CommitFlow.Draft(
          message: CommitDraft.message(summary: summary, body: messageBody), files: selectedFiles)
      },
      dismiss: onDismiss)
  }

  // A preflight retried from a button focuses the summary as the one on appear does. The flow
  // does the retry itself (without focus) when a press finds the preflight not ready, so the view
  // adds only the focus.
  private func prefill() {
    summaryFocused = true
    flow.prefill(flowContext)
  }

  private func commitChecking(mode: VCSCommitMode) {
    if !flow.preflightState.isReady { summaryFocused = true }
    flow.commitChecking(mode: mode, flowContext)
  }

  private func commit(mode: VCSCommitMode) {
    if !flow.preflightState.isReady { summaryFocused = true }
    flow.commit(mode: mode, flowContext)
  }
}

/// One changed file, with its inclusion checkbox.
///
/// The checkbox is an SF Symbol in a 14pt slot rather than a `Toggle` on purpose: the row aligns on
/// `.firstTextBaseline` so the directory text sits on the filename's baseline, and a `Toggle` has no
/// text baseline to align to — it would sit visibly high against the change letter beside it. Same
/// glyph size and same slot width as that letter, so both share a baseline by construction.
private struct CommitFileRow: View {
  let file: ChangedFile
  let isIncluded: Bool
  let toggle: () -> Void
  let only: () -> Void
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Button(action: toggle) {
        Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
          .font(.callout)
          .foregroundStyle(isIncluded ? Color.accentColor : .secondary)
          .frame(width: 14)
      }
      .buttonStyle(.plain)
      .help(isIncluded ? "Exclude this file from the commit" : "Include this file in the commit")
      .accessibilityLabel("\(file.path), \(isIncluded ? "included" : "excluded")")
      .accessibilityIdentifier("commit.file.check.\(file.path)")
      // Combined SEPARATELY from the checkbox, not across the whole row. An
      // `.accessibilityElement(children: .combine)` on the row collapses everything inside it into one
      // element, which takes the checkbox with it — the control then isn't individually clickable and
      // XCUITest cannot toggle it. Caught by `CommitSheetUITests`; same family as the
      // `children: .contain` note on `VCSFailureSheet`.
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(ChangeBadge.letter(file.change))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(ChangeBadge.color(file.change, tokens))
          .frame(width: 14)
        let parts = ChangesPanel.splitPath(file.path)
        Text(parts.name).font(.callout).lineLimit(1).truncationMode(.middle)
        if !parts.dir.isEmpty {
          Text(parts.dir)
            .font(.caption2).foregroundStyle(.tertiary)
            .lineLimit(1).truncationMode(.head)
        }
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(ChangeBadge.word(file.change)) \(file.path)")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    // Excluded rows dim their CONTENT rather than taking a background: the accent background already
    // means "this row's diff is the focused tab" in the Changes panel, and two selection meanings
    // sharing one visual is how a user learns to distrust both.
    .opacity(isIncluded ? 1 : 0.45)
    .contentShape(Rectangle())
    // `.contain`, never `.combine`: the row holds two things a user acts on separately — the
    // checkbox and the file — and combining them would merge the checkbox into the row, leaving no
    // individually clickable control. The label halves live on the two children instead.
    .accessibilityElement(children: .contain)
    .contextMenu {
      Button("Commit Only This File", action: only)
      Button(isIncluded ? "Exclude This File" : "Include This File", action: toggle)
    }
  }
}

/// A commit failure, inline. Same content as `VCSFailureSheet` — a sheet cannot present another
/// sheet over itself, and the draft has to stay on screen because it survives the failure.
private struct CommitFailureNotice: View {
  let dialog: VCSFailureDialog
  @State private var showDetails = false

  var body: some View {
    Notice {
      Text(dialog.title).font(FontRole.noticeTitle)
      Text(dialog.message)
        .font(FontRole.noticeBody).foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    } accessory: {
      // The hook's own output is the most useful text in the whole taxonomy — 40 lines of eslint
      // naming file and line — so it gets a scroll pane and selectable text, not a truncated line.
      if let details = dialog.details {
        DisclosureGroup(isExpanded: $showDetails) {
          ScrollView {
            Text(details)
              .font(.system(.caption2, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(6)
          }
          .frame(maxHeight: 120)
          .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
        } label: {
          DisclosureLabel(isExpanded: $showDetails) {
            Text("Output").font(.caption.weight(.semibold))
          }
        }
        .accessibilityIdentifier("commit.failure.detailsToggle")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("commit.failure")
  }
}
