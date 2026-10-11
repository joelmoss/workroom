import Foundation

/// Opening diff, file and changeset content tabs, and opening a workroom's files in the external
/// editor. Moved out of `AppStore.swift` as is; the openers hold no state of their own. They lean on
/// three things that stay on `AppStore`: `selectedTarget` (which workroom a panel's click acts on),
/// `whenHostLayoutRestored` (holds an open until a remote host has returned its layout, see
/// `AppStore+HostLayout.swift`), and `terminals`, which owns the tabs.
extension AppStore {
  // MARK: Diff content tabs (issue #66)

  /// Open a changed file as a diff in the selected workroom's tab strip, in preview mode
  /// (single-click in the Changes panel). `source` is the row's group, so the diff
  /// resolves against the right revision. No-op if nothing's selected.
  func openDiffPreview(_ file: ChangedFile, source: DiffSource) {
    guard let target = selectedTarget else { return }
    let diff = DiffDescriptor(
      path: file.path, change: file.change, source: source, isPreview: true)
    whenHostLayoutRestored(target) { [terminals] target in
      terminals.openDiffPreview(diff, for: target)
    }
  }

  /// Open a changed file as a *persisted* diff tab (double-click in the Changes panel) — skips
  /// preview mode. No-op if nothing's selected.
  func openDiffPersistent(_ file: ChangedFile, source: DiffSource) {
    guard let target = selectedTarget else { return }
    let diff = DiffDescriptor(
      path: file.path, change: file.change, source: source, isPreview: false)
    whenHostLayoutRestored(target) { [terminals] target in
      terminals.openDiffPersistent(diff, for: target)
    }
  }

  /// Open a repo file as the selected target's single PREVIEW content tab (single-click in the Files
  /// inspector section), read-only. Shares the preview slot with diffs. No-op if nothing's selected.
  ///
  /// Resolving `selectedTarget` is right for the Files inspector, which acts on the selection by
  /// definition. It is WRONG for anything attached to a specific pane — see the overload below.
  func openFilePreview(path: String) {
    guard let target = selectedTarget else { return }
    openFilePreview(path: path, for: target)
  }

  /// Open a repo file as `target`'s preview content tab — for callers that belong to a particular
  /// pane rather than to the selection (issue #150's per-pane title bar, `PaneTitleBar`'s "Open
  /// File").
  ///
  /// The distinction is only visible in a WORKROOM split, where two workrooms are co-displayed and
  /// exactly one of them is `selectedTarget`: without an explicit target, a button sitting on the
  /// non-focused workroom's diff pane opened the file into the *other* workroom's tab strip. A pane's
  /// own controls must act on that pane's target, which is the whole point of moving them there.
  func openFilePreview(path: String, for target: TerminalTarget) {
    whenHostLayoutRestored(target) { [terminals] target in
      terminals.openFilePreview(FileDescriptor(path: path, isPreview: true), for: target)
    }
  }

  /// Open a repo file as a *persisted* content tab (double-click in the Files section). No-op if
  /// nothing's selected.
  func openFilePersistent(path: String) {
    guard let target = selectedTarget else { return }
    whenHostLayoutRestored(target) { [terminals] target in
      terminals.openFilePersistent(FileDescriptor(path: path, isPreview: false), for: target)
    }
  }

  /// Open a commit's changeset detail as the selected target's single PREVIEW content tab
  /// (single-click a History row, issue #59). Shares the preview slot with diffs/files. No-op if
  /// nothing's selected.
  func openChangesetPreview(commitID: String, title: String) {
    guard let target = selectedTarget else { return }
    let changeset = ChangesetDescriptor(commitID: commitID, title: title, isPreview: true)
    whenHostLayoutRestored(target) { [terminals] target in
      terminals.openContentPreview(changeset, for: target)
    }
  }

  /// Open a commit's changeset detail as a *persisted* content tab (double-click a History row).
  /// No-op if nothing's selected.
  func openChangesetPersistent(commitID: String, title: String) {
    guard let target = selectedTarget else { return }
    let changeset = ChangesetDescriptor(commitID: commitID, title: title, isPreview: false)
    whenHostLayoutRestored(target) { [terminals] target in
      terminals.openContentPersistent(changeset, for: target)
    }
  }

  /// Select a file within a changeset tab (a tap in the History detail's file list). Updates the tab
  /// so `ChangesetDetailView` shows that file's diff (no reload — its `.task` keys on the commit).
  /// Each in-commit selection is its own back/forward step, recorded by `.tabContentChanged` rather
  /// than here — one seam, so no opener can forget. A plain forward: `setChangesetSelectedPath` already
  /// applies the same two preconditions (the tab exists and is a changeset, and the path actually
  /// changed), so re-checking them here would just be two guards to keep in sync.
  ///
  /// `path` is optional because "the commit's first file" has exactly ONE representation: `nil`. The
  /// detail view renders the first file when the selection is empty, so recording that same file
  /// *by name* would create a second location that renders identically to the first — Back would spend a
  /// press going nowhere visible. The caller canonicalises, because only it knows the file list.
  func selectChangesetFile(_ path: String?, tab tabID: TerminalTab.ID, in target: TerminalTarget) {
    terminals.setChangesetSelectedPath(path, forTab: tabID, in: target)
  }

  /// Open a repo file in the configured external editor (⌘-click / context menu in the Files
  /// section), reusing the shared editor path. No-op if nothing's selected.
  func openFileInEditor(path: String) {
    guard let target = selectedTarget else { return }
    openWorkroomFile(relativePath: path, for: target)
  }

  /// Open a workroom-relative file in the configured "Open file paths in" editor — the single path
  /// resolution shared by `openDiffTabFile` (#72) and `openChangedFileInEditor` (#93). Reuses
  /// `TerminalLinkOpener`, so it honours `Defaults[.filePathEditor]`; for a folder-capable editor CLI
  /// (VS Code/Zed/Xcode) the file opens *inside* the workroom folder window, while the default-app
  /// fallback just opens the file (no folder/window targeting). Fire-and-forget; a missing file
  /// no-ops in `openFilePath`.
  private func openWorkroomFile(relativePath: String, for target: TerminalTarget) {
    // A remote workroom's path is a path on its host: on this Mac it is nothing, or another file.
    guard !target.isMissing else { return }
    let absPath = (target.path as NSString).appendingPathComponent(relativePath)
    TerminalLinkOpener.openFilePath(absPath, cwd: nil, project: target.path)
  }

  /// Open a diff tab's underlying file in the configured editor (the tab toolbar / context-menu
  /// "Open file in…", issue #72). Caller disables this for a deleted-source diff (the working file
  /// is gone — `DiffDescriptor.change == .deleted`); for a commit diff it opens the working copy,
  /// which may differ from the displayed revision (editing the live file is the useful action).
  func openDiffTabFile(_ descriptor: DiffDescriptor, for target: TerminalTarget) {
    openWorkroomFile(relativePath: descriptor.path, for: target)
  }

  /// Open a changed file's working copy in the configured editor — the Changes-panel row's ⌘-click
  /// and the row context-menu "Open File in …" (issue #93). No-op when nothing's selected or the
  /// file was deleted (no working file to open — see `resolveOpenTarget`).
  func openChangedFileInEditor(_ file: ChangedFile) {
    guard let target = selectedTarget, let rel = Self.resolveOpenTarget(file: file) else { return }
    openWorkroomFile(relativePath: rel, for: target)
  }

  /// Open a changed file's working copy in the in-app viewer as a preview tab — the Changes-panel
  /// hover-toolbar button and the row context-menu "Open File" (issue #117). No-op when nothing's
  /// selected or the file was deleted (no working copy — see `resolveOpenTarget`). Shares the single
  /// preview slot with diffs, so it recycles the row's diff preview (a persisted diff tab is kept).
  func openChangedFileInApp(_ file: ChangedFile) {
    guard let rel = Self.resolveOpenTarget(file: file) else { return }
    openFilePreview(path: rel)
  }

  /// The repo-relative path to open for a changed file, or nil when there's nothing to open (a
  /// deleted source — the working file is gone). `nonisolated` + pure so the open decision is
  /// unit-testable from a synchronous context, without the side-effecting opener (issue #93).
  nonisolated static func resolveOpenTarget(file: ChangedFile) -> String? {
    file.change == .deleted ? nil : file.path
  }
}
