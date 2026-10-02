import Foundation

/// Where a changed-file row's diff comes from — picks the VCS revision the `DiffResolver` diffs
/// against (issue #66); each row carries its source, so a click always opens the *right* diff:
///   - `.gitWorktree`    — a git worktree's uncommitted changes vs `HEAD`.
///   - `.commit(id)`     — an arbitrary commit's *own* changes (vs its first parent), addressed by a
///     stable commit id, used by the changeset detail (issue #59); resolved structurally via
///     `VCSProviding.fileDiff`, not by shelling. The revision is part of the diff's tab identity.
enum DiffSource: Equatable, Hashable, Sendable {
  case gitWorktree
  case commit(String)
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
