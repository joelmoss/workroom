import Foundation

/// What kind of reference the working copy is on. Drives the root row's label treatment
/// (see RootPresentation). `ref_kind`-style, self-describing — the renderer needs no
/// `project.vcs` cross-reference.
public enum RefKind: Hashable, Sendable {
  case branch  // on a branch
  case detached  // detached HEAD — showing a short SHA
  case none  // no branch resolvable, or not yet resolved
}

/// A project root's resolved label. `branch` is normalized to nil (never "") so an empty
/// result is unambiguously `.none`.
public struct RootRef: Hashable, Sendable {
  public let branch: String?
  public let kind: RefKind

  public init(branch: String?, kind: RefKind) {
    self.branch = branch
    self.kind = kind
  }

  public static let unresolved = RootRef(branch: nil, kind: .none)
}
