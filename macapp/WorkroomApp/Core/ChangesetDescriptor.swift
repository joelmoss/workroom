import Foundation

/// The `.changeset` payload of a content tab (issue #59): a whole commit's detail — its metadata,
/// changed-file list, and per-file diff — addressed by a stable commit id. A value type like the
/// other content descriptors, so retargeting the preview mutates a copy in place and reassigns it,
/// keeping the tab's id (and thus its strip slot / split position) stable.
struct ChangesetDescriptor: Equatable, Hashable, Sendable {
  /// The commit this tab details — the dedup / retarget identity (a changeset *is* a commit).
  var commitID: String
  /// The tab's title: the commit summary (short id fallback), captured at open time so the strip
  /// needn't re-resolve the commit to name its chip.
  var title: String
  /// True while this is the target's single preview tab (italic chip, replaced by the next preview);
  /// false once persisted ("Keep Open" / double-click / opened persistently).
  var isPreview: Bool

  /// Two descriptors address the *same* changeset tab when they point at the same commit — the
  /// identity used to dedupe (re-select an already-open commit) and to retarget the preview. The
  /// preview flag and title are deliberately excluded, mirroring `DiffDescriptor.sameFile`.
  func sameChangeset(as other: ChangesetDescriptor) -> Bool { commitID == other.commitID }
}

extension ChangesetDescriptor: ContentDescriptor {
  func makeTabContent() -> TabContent { .changeset(self) }
  func matches(_ content: TabContent) -> Bool {
    if case .changeset(let c) = content { return c.sameChangeset(as: self) }
    return false
  }
}
