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
  /// Still an `@EnvironmentObject`: the row's click/context-menu actions need the store, and those are
  /// four call sites, not one value. `AppStore` publishes on status sweeps — seconds apart — not per
  /// terminal keystroke, so it is not the invalidation source this fix was about.
  @EnvironmentObject var store: AppStore
  @State private var hovering = false
  /// Time of the last click, so a quick second click promotes the preview tab to persisted (eager
  /// single/double discrimination — the single click never waits).
  @State private var lastClick: Date?

  #if DEBUG
    /// Body evaluations across all rows this process — the Changes-panel counterpart of
    /// `HistoryRow.bodyPasses`, read by `ChangedFileRowInvalidationTests`.
    static var bodyPasses = 0
  #endif
  /// Observed so the hover toolbar / context-menu "Open file in <editor>" label updates live when
  /// the user changes Settings → "Open file paths in" (issue #93); otherwise it'd be stale until an
  /// unrelated redraw.
  @Default(.filePathEditor) private var filePathEditorID
  private let theme = ThemeService.shared

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
        .foregroundStyle(isSelected ? theme.tokens.accent : .primary)
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
        .fill(isSelected ? theme.tokens.rowSelection : (hovering ? theme.tokens.rowHover : .clear))
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
        store.openChangedFileInEditor(file)  // ⌘-click → open the file, not the diff (issue #93)
        lastClick = nil  // clear any pending double-click state so the next plain click is fresh
        return
      }
      let now = Date()
      if let last = lastClick, now.timeIntervalSince(last) < 0.35 {
        store.openDiffPersistent(file, source: source)  // quick second click → persist
        lastClick = nil
      } else {
        store.openDiffPreview(file, source: source)  // eager: open the preview immediately
        lastClick = now
      }
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
        store.openChangedFileInApp(file)
      } label: {
        Label("Open File", systemImage: "doc.text")
      }
      .disabled(file.change == .deleted)
      Button {
        store.openChangedFileInEditor(file)
      } label: {
        Label("Open File in \(openFileEditorName)", systemImage: "arrow.up.forward.app")
      }
      // A remote workroom's files aren't on this Mac.
      .disabled(file.change == .deleted || store.inspectorTarget?.isMissing != false)
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
          store.openChangedFileInApp(file)
        }
      }
      .padding(.horizontal, 2)
      .background(
        // The same opaque token the row fills its highlight with — solid (occludes the path text) and
        // identical in colour to the row by construction.
        RoundedRectangle(cornerRadius: 5)
          .fill(isSelected ? theme.tokens.rowSelection : theme.tokens.rowHover)
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
    selection?.selectsChangedFile(path: file.path, source: source) ?? false
  }

  /// The equality gate behind `.equatable()` in `fileList`: a panel body pass that rebuilds the rows,
  /// such as a status sweep that changes one file, re-creates every row value, and only the ones whose
  /// file, group or selected-ness actually changed get a body. `@EnvironmentObject`/`@State`/
  /// `@Default` still invalidate past this gate, so hover, the editor-preference label and
  /// store-driven updates are unaffected. A theme change needs no input here, unlike `HistoryRow`'s:
  /// every row reads `theme.tokens` outside any ternary (the change letter's `color`), so
  /// Observation repaints each row past the gate.
  nonisolated static func == (lhs: ChangedFileRow, rhs: ChangedFileRow) -> Bool {
    lhs.file == rhs.file && lhs.source == rhs.source && lhs.isSelected == rhs.isSelected
  }

  // Letter / colour / word live in `ChangeBadge` (Core) so the mapping is unit-testable — see its
  // doc for why `.conflicted` is `"!"` in its own colour rather than `"C"` in deletion's red.
  private var letter: String { ChangeBadge.letter(file.change) }
  private var color: Color { ChangeBadge.color(file.change, theme.tokens) }
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

/// The Changes section body: the selected workroom's branch, sync state, working-tree changes
/// (relative to HEAD), and CI. Reads `store.selectedTargetID` + `vcsStatus.workroomStatuses`.
/// Covers the empty/edge states the design review enumerated: nothing selected, a project
/// (non-target), missing directory, still-loading, unknown (probe failed), and clean.
struct ChangesPanel: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var vcsStatus: VCSStatusService
  /// Read HERE so the rows don't have to. While each `ChangedFileRow` observed `TerminalPanes`
  /// directly, every terminal title/activity write rebuilt all `renderCap` rows — the same defect
  /// that produced the WORKROOM-2B App Hang in the History pane (see `HistoryPanel`'s invalidation
  /// diagram). The panel reads the selected target's focused tab through Observation, so only that
  /// target's pane changes re-run it, and no row rebuilds (`ChangedFileRowInvalidationTests`).
  let sessions: TerminalPanes
  /// Hard cap on rendered rows so a huge change set can't blow up the list (the underlying
  /// output is already byte-capped by `StatusCommandRunner`).
  private let renderCap = 200

  var body: some View {
    Group {
      if let sid = store.inspectorTargetID, sid.isStatusable {
        content(for: sid)
      } else {
        inspectorMessage("Select a workroom to see its changes.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func content(for sid: SidebarID) -> some View {
    let target = store.target(for: sid)
    let status = vcsStatus.workroomStatuses[sid]
    // `terminalUnavailability`: a remote workroom this app reaches has its changes read on its host.
    if let reason = target?.terminalUnavailability {
      inspectorMessage("\(reason.title).")
    } else if status == nil || status?.lastChecked == nil {
      inspectorMessage("Checking\u{2026}")
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
        fileList(status.changedFiles ?? [], source: .gitWorktree)
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
  private func fileList(_ files: [ChangedFile], source: DiffSource) -> some View {
    let shown = Array(files.prefix(renderCap))
    // Resolved once for the whole list, not once per row: this is the read that used to make every row
    // observe `TerminalPanes`.
    let selection = FocusedTabSelection.current(store: store, sessions: sessions)
    VStack(alignment: .leading, spacing: 1) {
      ForEach(shown) { file in
        ChangedFileRow(file: file, source: source, selection: selection)
          .equatable()
      }
      if files.count > shown.count {
        Text("Showing first \(shown.count) of \(files.count)")
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
    }
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
