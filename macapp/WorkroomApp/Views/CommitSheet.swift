import SwiftUI

/// Record a commit: what will be included, the message, and the failure when there is one.
///
/// **Why a dialog rather than a box in the Changes pane.** Measured against the pane it would have
/// lived in: the composer is ~152pt and `InspectorPanePolicy.expandedMinHeight` leaves 86pt of body,
/// so at the pane's own drag floor the Commit button was below the fold. At a default third of a
/// 900pt window it left two file rows for git and one for jj — for a list whose entire job is letting
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
  private let theme = ThemeService.shared

  @State private var summary = ""
  @State private var messageBody = ""
  /// EXCLUSIONS, not selections — see `CommitDraft.selected(from:excluding:)`. A file written while
  /// this sheet is open arrives checked; a file the user unticked stays unticked.
  @State private var excluded: Set<String> = []
  @State private var phase: Phase = .editing
  @State private var prefilled = false
  /// A parked merge/rebase/cherry-pick/revert/bisect in this worktree, resolved on appear.
  ///
  /// The engine refuses one of these outright, so leaving it out of `blockedReason` meant composing a
  /// whole message and pressing Commit to be told. Read once: finishing a merge is something the user
  /// does in the terminal, and re-polling for it would be a timer against the filesystem for a state
  /// that changes at human speed.
  @State private var sequencer: String?
  /// The commit `Amend last commit` would rewrite, so the message being replaced is visible BEFORE
  /// the click rather than recoverable only from the reflog afterwards.
  @State private var amendTarget: String?
  /// jj's stored description exactly as read, so an unedited Describe rewrites nothing.
  @State private var originalMessage: String?
  @FocusState private var summaryFocused: Bool

  private enum Phase: Equatable {
    case editing
    /// Selected paths whose staged content this commit would discard, awaiting confirmation.
    case confirmingStagedLoss([String])
    case committing
    case failed(VCSFailureDialog)
    /// The commit LANDED but a later step failed. Terminal: the only honest action left is to close.
    /// Distinct from `.failed` because retrying here would record the work a second time, and the
    /// notice says so — so the buttons that would do it are disabled rather than merely discouraged.
    case landedThenFailed(VCSFailureDialog)
  }

  /// The commit is on disk; nothing in this dialog can be pressed again without duplicating it.
  private var isSpent: Bool {
    if case .landedThenFailed = phase { return true }
    return false
  }

  /// Hard cap on rendered rows, matching `ChangesPanel`'s. See `fileSection`.
  private static let renderCap = 200

  private var isJJ: Bool { pending.vcs == .jj }
  private var status: WorkroomStatus? { store.workroomStatuses[pending.sid] }

  /// Every changed file, from whichever shape this backend reports.
  private var files: [ChangedFile] {
    guard let status else { return [] }
    if let workingCopy = status.jjWorkingCopy { return workingCopy.files }
    return status.changedFiles ?? []
  }

  private var selectedFiles: [ChangedFile] {
    // jj commits the whole change, so the exclusion set is never applied to it.
    isJJ ? files : CommitDraft.selected(from: files, excluding: excluded)
  }

  /// How many files the commit would record, WITHOUT building the filtered array.
  ///
  /// `body` asks this several times per evaluation — the caption, the button label, the blocked
  /// reason, the select-all glyph — and re-evaluates on every keystroke, so `selectedFiles.count`
  /// meant several full copies of the change set per typed character.
  private var selectedCount: Int {
    isJJ ? files.count : files.reduce(into: 0) { if !excluded.contains($1.path) { $0 += 1 } }
  }

  private var blockedReason: String? {
    CommitDraft.blockedReason(
      vcs: pending.vcs, summary: summary, selectedCount: selectedCount,
      totalCount: files.count, conflicted: status?.conflicted ?? false, sequencer: sequencer)
  }

  /// The secondary verb rewrites a message and takes no pathspec, so it answers to the repo-state and
  /// summary rules but not the file-count ones — see `CommitDraft.messageOnlyBlockedReason`.
  private var secondaryBlockedReason: String? {
    CommitDraft.messageOnlyBlockedReason(
      summary: summary, conflicted: status?.conflicted ?? false, sequencer: sequencer)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      fileSection
      messageSection
      amendTargetNotice
      if case .confirmingStagedLoss(let paths) = phase { stagedLossNotice(paths) }
      if case .failed(let dialog) = phase { CommitFailureNotice(dialog: dialog) }
      if case .landedThenFailed(let dialog) = phase { CommitFailureNotice(dialog: dialog) }
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
      Text(isJJ ? "Describe this change" : "Commit changes")
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
    if case .confirmingStagedLoss = phase { return "Commit anyway" }
    return CommitDraft.commitLabel(selectedCount: selectedCount, vcs: pending.vcs)
  }

  private var countCaption: String {
    isJJ
      ? "\(files.count) file\(files.count == 1 ? "" : "s") in this change"
      : "\(selectedCount) of \(files.count) file\(files.count == 1 ? "" : "s")"
  }

  // MARK: Files

  @ViewBuilder private var fileSection: some View {
    if files.isEmpty {
      // jj can legitimately describe an empty change, so this is a note rather than a blocker there.
      Text(
        isJJ
          ? "This change has no file changes yet. You can still give it a message."
          : "Nothing has changed in this workroom yet."
      )
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
        if !isJJ { selectAllRow }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { file in
              CommitFileRow(
                file: file, showsCheckbox: !isJJ,
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
        if isJJ {
          Text("jj commits the whole change. Splitting isn’t supported yet.")
            .font(.caption).foregroundStyle(.tertiary)
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
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(
            paths.count == 1
              ? "1 file has staged changes that differ from the file on disk"
              : "\(paths.count) files have staged changes that differ from the files on disk"
          )
          .font(.subheadline.weight(.semibold))
          Text(
            "Committing records what is on disk, so the version you staged will be replaced. "
              + "Stage and commit it from the terminal instead if you meant to keep it."
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Text(paths.prefix(5).joined(separator: ", ") + (paths.count > 5 ? ", …" : ""))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
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
      .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.tokens.border, lineWidth: 1))
    }
  }

  // MARK: Buttons

  private var buttons: some View {
    HStack(spacing: 8) {
      // A persistent line, never a tooltip: nobody hovers a button that looks dead, and a tooltip is
      // unreachable by keyboard and invisible to VoiceOver.
      if let blockedReason, phase == .editing {
        Text(blockedReason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("commit.blocked")
      }
      if phase == .committing {
        ProgressView().controlSize(.small)
        Text("Running hooks…").font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      // Disabled mid-commit, Escape included. The subprocess cannot be called back — a hook is
      // already running — so dismissing here would only tear down the `@State` the completion writes
      // its outcome into. A rejected hook, a signing failure or a left-behind `index.lock` would then
      // be reported to a view that no longer exists, and the user would be told nothing at all.
      Button(isSpent ? "Close" : "Cancel") { onDismiss() }
        .keyboardShortcut(.cancelAction)
        .disabled(phase == .committing)
        .accessibilityIdentifier("commit.cancel")
      secondaryButton
      Button(primaryLabel) {
        // Once the warning is on screen the same button confirms it — the guard has already told the
        // user what it is about to replace, so a second warning would just be a speed bump.
        if case .confirmingStagedLoss = phase {
          commit(mode: .commit)
        } else {
          commitChecking(mode: .commit)
        }
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .disabled(blockedReason != nil || phase == .committing || isSpent)
      .help(isJJ ? "Describe this change and start a new one on top" : "Commit the selected files")
      .accessibilityIdentifier("commit.commit")
    }
  }

  /// The backend's second verb, as its own button rather than behind a menu.
  ///
  /// There is exactly ONE alternative per backend, and a menu holding a single item is a click that
  /// buys nothing — it hides the choice behind a disclosure and gives the control no name until you
  /// open it. Naming it outright also stops the "same shape, opposite contract" problem an ellipsis
  /// split button would have had beside `MergeButton`, whose menu CHANGES what its primary does
  /// rather than performing a second action.
  ///
  /// The label is the command for jj — "Describe" is the verb jj users already have — with what it
  /// actually does in the help text, since the two verbs differ in a way the word alone can't carry.
  @ViewBuilder private var secondaryButton: some View {
    Button(isJJ ? "Describe" : "Amend last commit") {
      commit(mode: isJJ ? .describe : .amendMessage)
    }
    .disabled(secondaryBlockedReason != nil || phase == .committing || isSpent)
    .help(
      isJJ
        ? "Set this change’s message and stay on it, instead of starting a new change (jj describe)"
        : amendTarget.map {
          "Replace the message of \($0). Nothing else about that commit changes."
        }
          ?? "Replace the last commit’s message. Nothing else about that commit changes."
    )
    .accessibilityIdentifier(isJJ ? "commit.describe" : "commit.amend")
  }

  /// Which commit Amend would rewrite, named on screen rather than only in a tooltip.
  ///
  /// Amend replaces `HEAD`'s message with whatever is in the summary field — and that field starts
  /// EMPTY for git and is normally filled with a message written for a NEW commit. So the button one
  /// position left of the default action silently destroys a message the user cannot see, recoverable
  /// only through the reflog. Showing the target is the cheapest thing that makes the trade visible
  /// before the click instead of after it.
  @ViewBuilder private var amendTargetNotice: some View {
    if !isJJ, let amendTarget, phase == .editing {
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

  /// Everything the dialog has to read from the repo before it can be honest: jj's existing
  /// description, git's amend target, and any parked sequencer operation. Once, on appear.
  ///
  /// The jj description is read in FULL rather than from `JJCommitChanges.description`, which is only
  /// its first line — prefilling the summary from that and then describing again would silently
  /// discard the body the user wrote earlier.
  private func prefill() {
    summaryFocused = true
    guard !prefilled else { return }
    prefilled = true
    guard let item = store.selectedStatusWorkItem(for: pending.sid) else { return }
    // The fixture's paths are not repos, so every read below would fail and the dialog would show
    // nothing — which is the state these seeds exist to keep testable. Same rationale as
    // `FixtureVCSWriter`.
    if UITestFixture.isActive {
      if isJJ {
        let existing = CommitDraft.split(message: status?.jjWorkingCopy?.description ?? "")
        summary = existing.summary
        messageBody = existing.body
      } else {
        amendTarget = UITestFixture.amendTargetLabel
      }
      return
    }
    Task {
      // Off the main actor: both of these touch the filesystem.
      let parked = await Task.detached {
        CLIVCSWriter.sequencerState(gitDir: CLIVCSWriter.worktreeGitDir(at: item.path))
      }.value
      if !isJJ { sequencer = parked }

      if isJJ {
        let result = await StatusCommandRunner().run(
          "jj", CLIVCSWriter.jjDescriptionArgs(), in: item.path, timeout: 5)
        guard result.ok else { return }
        let existing = CommitDraft.split(message: result.stdout)
        // Never clobber something typed while the read was in flight.
        if summary.isEmpty && messageBody.isEmpty {
          summary = existing.summary
          messageBody = existing.body
          // Kept verbatim so an untouched Describe re-records the message byte for byte — see
          // `CommitDraft.message(summary:body:preserving:)`.
          originalMessage = result.stdout
        }
      } else {
        let result = await StatusCommandRunner().run(
          "git", CLIVCSWriter.gitHeadSubjectArgs(), in: item.path, timeout: 5)
        guard result.ok else { return }
        let subject = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        amendTarget = subject.isEmpty ? nil : subject
      }
    }
  }

  /// Commit, but check first whether doing so would throw away staged work.
  ///
  /// Only for the plain git commit path: amend takes no pathspec, and jj has no index. The check is
  /// skipped once confirmed so pressing "Commit anyway" cannot re-raise the same warning (that path
  /// calls `commit` directly, never this).
  ///
  /// Deliberately NOT conditioned on `phase == .editing`. It was, and that made the guard skip itself
  /// on exactly the attempt that needs it most: after a rejected hook the phase is `.failed`, so a
  /// retry fell through to `commit` unchecked — and anything the user staged with `git add -p` while
  /// fixing the rejection was discarded with no warning, unrecoverable except as a dangling blob.
  private func commitChecking(mode: VCSCommitMode) {
    guard mode == .commit, !isJJ else { return commit(mode: mode) }
    let files = selectedFiles
    store.stagedContentAtRisk(on: pending.sid, files: files) { atRisk in
      // The sheet can move on while that `git status` runs — the secondary verb stays pressable
      // during the round-trip. Without this re-check, a late result would stamp
      // `.confirmingStagedLoss` over a commit already in flight, re-enabling the primary and letting
      // a second concurrent commit through on the same repo.
      guard phase != .committing, !isSpent else { return }
      if atRisk.isEmpty {
        commit(mode: mode)
      } else {
        phase = .confirmingStagedLoss(atRisk)
      }
    }
  }

  private func commit(mode: VCSCommitMode) {
    guard phase != .committing else { return }
    let message = CommitDraft.message(
      summary: summary, body: messageBody, preserving: originalMessage)
    // Describing a change with the message it already has is a no-op jj reports as "Nothing changed."
    // — a failure notice for having changed nothing, which is not what the user asked about. Closing
    // is the honest answer: the message is already exactly what they wanted.
    if mode == .describe, let originalMessage, message == originalMessage { return onDismiss() }
    phase = .committing
    let request = VCSCommitRequest(
      message: message,
      files: mode == .amendMessage ? [] : selectedFiles, mode: mode)
    store.performCommit(request, on: pending.sid) { result in
      switch result {
      case .ok:
        onDismiss()
      case .committedThenFailed(_, let detail):
        // The commit LANDED. Closing would be a lie by omission, and offering a retry would create a
        // second commit, so the sheet stays up saying exactly that — and `.landedThenFailed` disables
        // the buttons that would do it, rather than leaving the advice and the affordance in
        // contradiction.
        phase = .landedThenFailed(
          VCSFailureDialog(
            title: "Committed, but something afterwards failed",
            message:
              "The commit was recorded. A step that runs after it — usually a post-commit hook — "
              + "then failed. Do not commit again; the change is already saved.",
            details: detail, recovery: nil, lockPath: nil))
      case .failed(let failure):
        phase = .failed(VCSSyncPresenter.commitFailureDialog(failure, mode: mode))
      }
    }
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
  let showsCheckbox: Bool
  let isIncluded: Bool
  let toggle: () -> Void
  let only: () -> Void
  private let theme = ThemeService.shared

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if showsCheckbox {
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
      }
      // Combined SEPARATELY from the checkbox, not across the whole row. An
      // `.accessibilityElement(children: .combine)` on the row collapses everything inside it into one
      // element, which takes the checkbox with it — the control then isn't individually clickable and
      // XCUITest cannot toggle it. Caught by `CommitSheetUITests`; same family as the
      // `children: .contain` note on `VCSFailureSheet`.
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(ChangeBadge.letter(file.change))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(ChangeBadge.color(file.change, theme.tokens))
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
    .opacity(showsCheckbox && !isIncluded ? 0.45 : 1)
    .contentShape(Rectangle())
    // `.contain`, never `.combine`: the row holds two things a user acts on separately — the
    // checkbox and the file — and combining them would merge the checkbox into the row, leaving no
    // individually clickable control. The label halves live on the two children instead.
    .accessibilityElement(children: .contain)
    .contextMenu {
      if showsCheckbox {
        Button("Commit Only This File", action: only)
        Button(isIncluded ? "Exclude This File" : "Include This File", action: toggle)
      }
    }
  }
}

/// A commit failure, inline. Same content as `VCSFailureSheet` — a sheet cannot present another
/// sheet over itself, and the draft has to stay on screen because it survives the failure.
private struct CommitFailureNotice: View {
  let dialog: VCSFailureDialog
  @State private var showDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(dialog.title).font(.subheadline.weight(.semibold))
          Text(dialog.message)
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
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
          Text("Output").font(.caption.weight(.semibold))
        }
        .accessibilityIdentifier("commit.failure.detailsToggle")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("commit.failure")
  }
}
