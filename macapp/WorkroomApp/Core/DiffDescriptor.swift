import Foundation

/// Where a changed-file row's diff comes from — picks the VCS revision the `DiffResolver` diffs
/// against. The Changes panel renders three contexts (issue #66 + the jj working-copy/parent split
/// landed in `2a9135e`); each row carries the source of the group it belongs to, so a click always
/// opens the *right* diff:
///   - `.gitWorktree`    — a git worktree's uncommitted changes vs `HEAD`.
///   - `.jjWorkingCopy`  — the jj working copy (`@`).
///   - `.jjParent`       — the jj working copy's parent commit (`@-`), the commit's own changes.
enum DiffSource: Equatable, Hashable, Sendable {
  case gitWorktree
  case jjWorkingCopy
  case jjParent
}

/// The `.diff` payload of a content tab (issue #66): which file, its change kind, where its diff
/// comes from, and whether the tab is still in VS-Code-style "preview" mode (italic title, replaced
/// by the next previewed file). A value type — retargeting the preview mutates a copy in place and
/// reassigns it, keeping the tab's id (and so its strip slot / split position) stable.
struct DiffDescriptor: Equatable, Hashable, Sendable {
  /// Repo-relative path (resolved against the workroom directory).
  var path: String
  var change: ChangedFile.Change
  var source: DiffSource
  /// True while this is the single preview tab for its target; false once persisted ("Keep Open",
  /// double-click, or opened persistently from the start).
  var isPreview: Bool

  /// Two descriptors address the *same* diff tab when they point at the same file from the same
  /// revision — the identity used to dedupe (re-select an already-open file) and to decide whether a
  /// preview can be retargeted in place. The preview flag is deliberately excluded.
  func sameFile(as other: DiffDescriptor) -> Bool {
    path == other.path && source == other.source
  }
}

extension DiffDescriptor: ContentDescriptor {
  func makeTabContent() -> TabContent { .diff(self) }
  func matches(_ content: TabContent) -> Bool {
    if case .diff(let d) = content { return d.sameFile(as: self) }
    return false
  }
}
