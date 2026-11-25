import AppKit
import Defaults
import DesignSystem
import SwiftUI
import WorkroomDomain
import WorkroomVCS

/// One changed-file row: a colored change-kind letter (M/A/D/…), the filename, then its parent
/// directory dimmed (issue #24 feedback). Clicking opens the file's diff in the workroom's tab strip
/// (issue #66): a single click opens it in preview mode (eagerly — the diff appears at once), a quick
/// double-click persists it. `source` is the row's group, so the diff resolves
/// against the right revision. The directory yields first when space is tight
/// (truncates from the head). The change kind is spelled out in the accessibility label.
///
/// Deliberately `internal`, not `private` (mirrors `HistoryRow`): `ChangedFileRowInvalidationTests`
/// reads `bodyPasses` to assert that a terminal pulse rebuilds nothing here either.
struct ChangedFileRow: View, Equatable {
  let file: ChangedFile
  /// Which revision this row's diff comes from — the Changes group it's rendered under.
  let source: DiffSource
  /// What the focused content tab is showing, resolved ONCE by the panel. The row used to hold
  /// `@ObservedObject TerminalPanes` and compute this itself, which meant every terminal
  /// title/activity publish rebuilt all `renderCap` rows (WORKROOM-2B's defect, one pane over).
  let selection: FocusedTabSelection?
  /// The repository the row's path is relative to, as its tabs name it
  /// (`FocusedTabSelection.changedFileRoot`): nil for the target's own. Reaches `==` through
  /// `isSelected`.
  var root: String? = nil
  /// Whether the inspector's workroom has no directory on this Mac (a remote or missing one), which
  /// disables "Open File in…". Part of the equality gate: it is the one window state the row shows.
  let targetIsMissing: Bool
  /// What a click, the hover toolbar and the context menu do. Behaviour-constant (the file and its
  /// source are arguments, not captures), which is what lets `==` leave it out.
  let actions: ChangedFileActions
  @State private var hovering = false

  #if DEBUG
    /// Body evaluations across all rows this process — the Changes-panel counterpart of
    /// `HistoryRow.bodyPasses`, read by `ChangedFileRowInvalidationTests`.
    static var bodyPasses = 0
  #endif
  /// Observed so the hover toolbar / context-menu "Open file in <editor>" label updates live when
  /// the user changes Settings → "Open file paths in" (issue #93); otherwise it'd be stale until an
  /// unrelated redraw.
  @Default(.filePathEditor) private var filePathEditorID
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    #if DEBUG
      Self.bodyPasses += 1
    #endif
    let (dir, name) = ChangesPanel.splitPath(file.path)
    // Baseline-aligned, not centered: the path is a smaller face than the filename, so centering
    // would float it off the name's baseline.
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(letter)
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(color)
        .frame(width: 14, alignment: .leading)
      Text(name)
        .font(.callout)
        .foregroundStyle(isSelected ? tokens.accent : .primary)
        .lineLimit(1).truncationMode(.middle)
        .layoutPriority(1)
      if !dir.isEmpty {
        // Same face as the History detail file list's path line (`ChangesetDetailView.fileRow`):
        // caption, monospaced, `.tertiary`. Matching the tint matters — the two panels sit one tab
        // apart, and `.secondary` beside `.tertiary` reads as two different kinds of text rather
        // than the same one.
        //
        // Truncation is the one thing that deliberately differs. History stacks the full path UNDER
        // the name and truncates it in the middle; here the directory sits INLINE before a
        // `layoutPriority(1)` name, where the tail (the directory the file is actually in) is the
        // part that identifies it — so it truncates from the head. Middle-truncation on a one-line
        // inline dir would clip both ends and leave the least useful segment.
        Text(dir)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.tertiary)
          .lineLimit(1).truncationMode(.head)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      // Square, full-width band (no corner radius): bleed past the section's 12pt inset so the
      // hover/selection highlight fills the inspector width edge-to-edge (issue #93 feedback).
      Rectangle()
        .fill(isSelected ? tokens.rowSelection : (hovering ? tokens.rowHover : .clear))
        .padding(.horizontal, -12)
    )
    // The row's tooltip describes its click action (open the diff). Applied BEFORE the hover overlay
    // so it scopes to the row content only — the trailing "Open file" button, painted on top, keeps
    // its OWN tooltip. A `.help` applied after the overlay covers the whole row and occludes the
    // button's, so hovering the button wrongly showed "Open diff for …" (issue #117 follow-up).
    // A moved file's old path has nowhere to go in this single-line row, so the tooltip carries it
    // (`old → new`); the wider changeset detail list shows it inline.
    .help(file.oldPath == nil ? "Open diff" : "Open diff — \(renamePath)")
    // Hover toolbar (issue #93): a content-sized cluster pinned to the trailing edge, painted over
    // the path. Only the button area intercepts clicks (it opens the file) — the rest of the row
    // still opens the diff. Built only while hovering, so the editor-name lookup runs on hover only.
    .overlay(alignment: .trailing) { if hovering { rowToolbar } }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture {
      if NSEvent.modifierFlags.contains(.command) {
        actions.openInEditor(file)  // ⌘-click → open the file, not the diff (issue #93)
        return
      }
      // Eager: the first click previews immediately; a double-click's second click persists.
      actions.openDiff(file, source, RepeatClick.isCurrentRepeat)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("changes.file.\(file.path)")
    .accessibilityLabel(
      accessibilityLabel(name: name, dir: dir)
    )
    // A non-pointer path to the open-file actions (the hover toolbar is mouse-only): keyboard /
    // VoiceOver reach them here. "Open File" opens the in-app viewer (issue #117); "Open File in …"
    // keeps the external-editor path (issue #93). Both no-op for a deleted file (no working copy).
    .contextMenu {
      Button {
        actions.openInApp(file)
      } label: {
        Label("Open File", systemImage: "doc.text")
      }
      .disabled(file.change == .deleted)
      Button {
        actions.openInEditor(file)
      } label: {
        Label("Open File in \(openFileEditorName)", systemImage: "arrow.up.forward.app")
      }
      // A remote workroom's files aren't on this Mac.
      .disabled(file.change == .deleted || targetIsMissing)
    }
  }

  /// The trailing hover toolbar: the in-app "Open File" button (extensible to more buttons; issue
  /// #117). Hidden for a deleted file — there's no working copy to open — so the toolbar renders
  /// nothing. Its backing is the same opaque `rowHover`/`rowSelection` token the row uses for its
  /// highlight, so the toolbar is solid (occludes the path text) and exactly the same colour as the row.
  @ViewBuilder private var rowToolbar: some View {
    if file.change != .deleted {
      HStack(spacing: 2) {
        TabToolbarButton(
          systemImage: "doc.text", help: "Open file",
          accessibilityLabel: "Open file",
          identifier: "changes.file.openFile.\(file.path)"
        ) {
          actions.openInApp(file)
        }
      }
      .padding(.horizontal, 2)
      .background(
        // The same opaque token the row fills its highlight with — solid (occludes the path text) and
        // identical in colour to the row by construction.
        RoundedRectangle(cornerRadius: 5)
          .fill(isSelected ? tokens.rowSelection : tokens.rowHover)
      )
      .fixedSize()
    }
  }

  /// Display name of the editor the "Open file in…" action targets — the Settings "Open file paths
  /// in" choice (`ExternalEditor.forFilePaths`), or "your default app" when unset. Recomputes when
  /// `filePathEditorID` changes (issue #93).
  private var openFileEditorName: String {
    ExternalEditor.forFilePaths?.name ?? "your default app"
  }

  /// True when the focused content tab is this row — either its diff (opened by a row click) or its
  /// file (opened by the in-app "Open File", issue #117) — so the row that's showing in the pane reads
  /// as selected. The matching rule itself lives in `FocusedTabSelection.selectsChangedFile` now, next
  /// to the History pane's equivalent: the file match ignores `source` since a file tab has no
  /// revision; the diff match keeps it so the same path from the worktree vs a commit selects the right
  /// row.
  nonisolated fileprivate var isSelected: Bool {
    selection?.selectsChangedFile(path: file.path, source: source, root: root) ?? false
  }

  /// The equality gate behind `.equatable()` in `fileList`: a panel body pass that rebuilds the rows,
  /// such as a status sweep that changes one file, re-creates every row value, and only the ones whose
  /// file, group, selected-ness or target availability actually changed get a body. `@State` and
  /// `@Default` still invalidate past this gate, so hover and the editor-preference label are
  /// unaffected. A theme change needs no input here, unlike `HistoryRow`'s: every row reads `tokens`
  /// outside any ternary (the change letter's `color`), so the theme environment repaints each row
  /// past the gate.
  nonisolated static func == (lhs: ChangedFileRow, rhs: ChangedFileRow) -> Bool {
    lhs.file == rhs.file && lhs.source == rhs.source && lhs.isSelected == rhs.isSelected
      && lhs.targetIsMissing == rhs.targetIsMissing
  }

  // Letter / colour / word live in `ChangeBadge` (Core) so the mapping is unit-testable — see its
  // doc for why `.conflicted` is `"!"` in its own colour rather than `"C"` in deletion's red.
  private var letter: String { ChangeBadge.letter(file.change) }
  private var color: Color { ChangeBadge.color(file.change, tokens) }
  private var changeWord: String { ChangeBadge.word(file.change) }
  /// `old → new`, for the tooltip and accessibility label of a moved file.
  private var renamePath: String {
    ChangeBadge.pathLine(path: file.path, oldPath: file.oldPath)
  }

  /// The row's spoken label. A moved file says where it came from — VoiceOver has no tooltip to fall
  /// back on, and the row only shows the new path.
  private func accessibilityLabel(name: String, dir: String) -> String {
    let place = dir.isEmpty ? "" : ", in \(dir)"
    let from = file.oldPath.map { ", from \($0)" } ?? ""
    return "\(name), \(changeWord)\(place)\(from), open diff"
  }
}

/// What a changed-file row's clicks do: open its diff (as a preview, or persisted), open the file in
/// the app, or in the external editor.
struct ChangedFileActions {
  /// The diff of `file` from `source`; `persist` keeps the tab rather than previewing it.
  var openDiff: (_ file: ChangedFile, _ source: DiffSource, _ persist: Bool) -> Void
  var openInApp: (ChangedFile) -> Void
  var openInEditor: (ChangedFile) -> Void
}

/// What the Changes panel shows from the window: the inspector's subject and, read lazily, the
/// focused content tab.
struct ChangesPanelInputs {
  /// What the inspector is about (`AppStore.inspectorSubject`).
  var subject: InspectorSubject
  /// Its sidebar item's target, nil once it has gone; for a followed repository, the repository
  /// itself (`AppStore.inspectorHistoryTarget`), which a changed file opens against.
  var target: TerminalTarget?
  /// What the focused content tab shows. A closure, called only while the file list renders, so the
  /// focused-tab and `TerminalPanes` reads stay the panel's own (see `ChangesPanel.fileList`).
  var selection: () -> FocusedTabSelection?
  /// Whether a followed folder's repository has been pending long enough to show the loader
  /// (`AppStore.followedFolderLoaderShown`); before that the pane stays blank.
  var showsPendingLoader = false

  /// Whether a changed file has nowhere to open: what disables its "Open File in …".
  var fileTargetIsMissing: Bool { target?.isMissing != false }
}

/// The Changes section body: the selected workroom's branch, sync state, working-tree changes
/// (relative to HEAD), and CI. Reads its inputs' target + the subject's status in `vcsStatus`.
/// Covers the empty/edge states the design review enumerated: nothing selected, a project
/// (non-target), missing directory, still-loading, unknown (probe failed), and clean.
///
/// Store-free: `ChangesPanelAdapter` builds `inputs` and `actions` from the window's `AppStore`.
struct ChangesPanel: View {
  @EnvironmentObject var vcsStatus: VCSStatusService
  let inputs: ChangesPanelInputs
  let actions: ChangedFileActions
  /// Hard cap on rendered rows so a huge change set can't blow up the list (the underlying
  /// output is already byte-capped by `StatusCommandRunner`).
  private let renderCap = 200

  var body: some View {
    Group {
      switch inputs.subject {
      case .target(let sid) where sid.isStatusable:
        content
      case .followed(let followed):
        // A terminal's followed folder (#807): its repository's changes, committed from here as a workroom's are (#808).
        if followed.repositoryPending {
          // Its repository is still resolving: blank at first, so a fast answer never flashes a
          // loader, then the section's own loader.
          if inputs.showsPendingLoader {
            checkingMessage.accessibilityIdentifier(pendingRepositoryLoaderID)
          } else {
            EmptyView()
          }
        } else if followed.repository == nil
          || vcsStatus.status(for: inputs.subject)?.failure?.meansNoRepository == true
        {
          NotARepositoryMessage(
            path: followed.folder, undetermined: followed.repositoryUndetermined)
        } else {
          content
        }
      case .target, .nothing:
        inspectorMessage("Select a workroom to see its changes.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The section's loader: while a workroom's status is read, and once a followed folder's
  /// repository has been pending a moment.
  private var checkingMessage: some View {
    inspectorCheckingMessage(help: "Reading the repository's changes")
  }

  /// Read here, in the panel, so a status sweep re-runs the panel and not its adapter.
  @ViewBuilder
  private var content: some View {
    let target = inputs.target
    let status = vcsStatus.status(for: inputs.subject)
    // `terminalUnavailability`: a remote workroom this app reaches has its changes read on its host.
    if let reason = target?.terminalUnavailability {
      inspectorMessage("\(reason.title).")
    } else if status == nil || status?.lastChecked == nil {
      checkingMessage
    } else if let status {
      // The branch name is NOT repeated here — the VCS toolbar above this section shows it, through
      // the same `AppStore.branchName(for:)` accessor this panel used to read, so the pill was saying
      // the same thing twice about 40pt apart. git's working tree carries no metadata of its own, so
      // it renders as a bare change list.
      gitContent(status: status)
    }
  }

  /// Just the working-tree change list (or clean/failure). No header — git's working tree
  /// isn't a commit, so with the branch name moved to the toolbar there is nothing left to head it with,
  /// and the divider went with it rather than ruling off an empty row. CI is GitHub-derived, so it lives
  /// in the Pull Request section — not here.
  @ViewBuilder
  private func gitContent(status: WorkroomStatus) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let failure = status.failure {
        inspectorMessage(failureText(failure))
      } else if status.isClean {
        cleanState
      } else {
        fileList(
          status.changedFiles ?? [], total: status.changedFileCount, source: .gitWorktree)
      }
    }
    .padding(12)
  }

  /// The clean (no working-tree changes) state, styled like the Notifications empty state (issue
  /// #24 feedback): a small, dim, icon-first line rather than a full-size centered message.
  private var cleanState: some View {
    HStack(spacing: 6) {
      Image(systemName: "checkmark.circle").font(.callout).foregroundStyle(.tertiary)
      Text("No uncommitted changes").font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("No uncommitted changes")
  }

  @ViewBuilder
  private func fileList(_ files: [ChangedFile], total: Int, source: DiffSource) -> some View {
    let shown = Array(files.prefix(renderCap))
    // Resolved once for the whole list, not once per row: this is the read that used to make every row
    // observe `TerminalPanes`. While each `ChangedFileRow` observed it directly, every terminal
    // title/activity write rebuilt all `renderCap` rows — the same defect that produced the
    // WORKROOM-2B App Hang in the History pane (see `HistoryPanel`'s invalidation diagram). Read
    // here, in the panel's body, only the selected target's pane changes re-run the panel, and no
    // row rebuilds (`ChangedFileRowInvalidationTests`).
    let selection = inputs.selection()
    let root = FocusedTabSelection.changedFileRoot(for: inputs.subject)
    let targetIsMissing = inputs.fileTargetIsMissing
    VStack(alignment: .leading, spacing: 1) {
      ForEach(shown) { file in
        ChangedFileRow(
          file: file, source: source, selection: selection, root: root,
          targetIsMissing: targetIsMissing, actions: actions
        )
        .equatable()
      }
      // `total`, not the list: a recalled status lists only its first files (#812).
      if total > shown.count {
        Text("Showing first \(shown.count) of \(total)")
          .font(.footnote).foregroundStyle(.tertiary)
      }
    }
  }

  /// Split a repo-relative path into (directory, filename). A root-level file → empty directory.
  static func splitPath(_ path: String) -> (dir: String, name: String) {
    guard let slash = path.lastIndex(of: "/") else { return ("", path) }
    return (String(path[..<slash]), String(path[path.index(after: slash)...]))
  }

  private func failureText(_ f: VCSStatusFailure) -> String {
    switch f {
    case .unavailable: return "Repository service unavailable."
    case .registrationRequired: return "Reload projects to register this repository."
    case .missingPath: return "Directory not found."
    case .notRepository: return "Not a repository."
    case .timeout: return "Status unavailable (timed out)."
    case .busy: return "Repository is busy — another VCS command is running."
    case .staleWorkingCopy: return "The working tree changed while it was read. Try again."
    case .asleep: return RepositoryRoutingError.asleepMessage
    case .olderLayout: return HostID.olderLayoutMessage
    case .signedOut: return RepositoryRoutingError.signedOutMessage
    case .gone: return RepositoryRoutingError.goneMessage
    }
  }
}

/// Builds `ChangesPanel`'s inputs and actions from the window's `AppStore`.
///
/// It reads the inspector's subject, as the panel's body did; the focused tab and the statuses are
/// read by the panel, so a terminal pulse reaches the panel and not this, and a status sweep re-runs
/// the panel alone.
struct ChangesPanelAdapter: View {
  @EnvironmentObject var store: AppStore

  var body: some View {
    ChangesPanel(inputs: Self.inputs(store: store), actions: actions)
  }

  /// The panel's inputs from `store`.
  static func inputs(store: AppStore) -> ChangesPanelInputs {
    let subject = store.inspectorRepositorySubject
    let target: TerminalTarget? =
      if case .followed = subject {
        store.inspectorHistoryTarget
      } else {
        subject.sidebarID.flatMap { $0.isStatusable ? store.target(for: $0) : nil }
      }
    return ChangesPanelInputs(
      subject: subject,
      target: target,
      // `store.terminals` is read only in here, which the panel calls (see `ChangesPanelInputs`).
      selection: { [store] in
        FocusedTabSelection.current(store: store)
      },
      showsPendingLoader: store.followedFolderLoaderShown)
  }

  /// `[store]` only, and the file and source as arguments: the capture list is what makes these
  /// behaviour-constant, which is what lets `ChangedFileRow.==` exclude them.
  private var actions: ChangedFileActions {
    ChangedFileActions(
      openDiff: { [store] file, source, persist in
        if persist {
          store.openDiffPersistent(file, source: source)
        } else {
          store.openDiffPreview(file, source: source)
        }
      },
      openInApp: { [store] file in store.openChangedFileInApp(file) },
      openInEditor: { [store] file in store.openChangedFileInEditor(file) }
    )
  }
}

extension SidebarID {
  /// A row whose VCS status the inspector can show: the project root or a workroom, but not the
  /// collapsed `.project` group header. Shared by the Changes and Pull Request panels.
  var isStatusable: Bool {
    if case .project = self { return false }
    return true
  }
}

/// The inspector's "nothing to show" placeholder line (e.g. "Select a workroom…"), shared by the
/// Changes and Pull Request panels so they read identically.
func inspectorMessage(_ text: String) -> some View {
  Text(text)
    .font(.body)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
}

/// The inspector's "Checking…" loader line, shared by the Changes and Pull Request panels: what
/// they show while a status is read, and once a followed folder's repository has been pending a
/// moment. `help` is its tooltip and accessibility label.
/// The accessibility identifier of a section's loader for a followed folder whose repository is
/// still pending (`AppStore.followedFolderLoaderShown`), the same in every section.
let pendingRepositoryLoaderID = "inspector.pendingRepository"

func inspectorCheckingMessage(help: String) -> some View {
  inspectorMessage("Checking\u{2026}")
    .help(help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(help)
}

#if DEBUG
  #Preview("Changes") {
    // Three changed files in a workroom, the second open as a diff.
    let sid = SidebarID.workroom(project: "/tmp/platform", name: "fix-auth")
    let target = TerminalTarget(
      id: .workroom(project: "/tmp/platform", name: "fix-auth"), title: "fix-auth",
      path: "/tmp/platform/fix-auth", unavailability: nil)
    let status = VCSStatusService(projectStore: ProjectStore())
    status.workroomStatuses[sid] = WorkroomStatus(
      dirty: true,
      changedFiles: [
        ChangedFile(path: "README.md", change: .modified),
        ChangedFile(path: "Sources/Auth/Token.swift", change: .added),
        ChangedFile(path: "Sources/Auth/Legacy.swift", change: .deleted),
      ],
      lastChecked: Date())
    return ChangesPanel(
      inputs: ChangesPanelInputs(
        subject: .target(sid), target: target,
        selection: { .diff(path: "Sources/Auth/Token.swift", source: .gitWorktree) }),
      actions: ChangedFileActions(
        openDiff: { _, _, _ in }, openInApp: { _ in }, openInEditor: { _ in })
    )
    .environmentObject(status)
    .themeTokensRoot()
    .frame(width: 320, height: 200)
  }
#endif
