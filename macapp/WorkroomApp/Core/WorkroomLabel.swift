import Foundation

/// The parts of a sidebar item's display label, resolved once and formatted per surface.
///
/// Four surfaces used to format this string themselves — the workroom tab chip's tooltip, the split
/// pane title bar's tooltip, the notification origin line, and (issue #132) the quick-switcher rail —
/// and two of them had already drifted apart on the separator (`"p/fox"` vs `"p / fox"`). The parts
/// are resolved by `AppStore.label(for:)`; everything about *rendering* them lives here, pure and
/// unit-testable.
///
/// `branch` is deliberately separate from the title: a root's branch is its *state*, not its
/// identity, so it belongs in a subtitle. `RootPresentation.make` returns `"root"` as a placeholder
/// for an unresolved ref, which must never be mistaken for a real branch name — the resolver keeps
/// that case nil.
struct WorkroomLabel: Equatable {
  /// The owning project's directory name (`Project.displayName`). Empty only if the sid resolves no
  /// project — a mid-reload race, not a real state.
  let project: String
  /// This item's own label-aware workroom name; nil for a project root.
  let workroom: String?
  /// A root's resolved branch/bookmark; nil for a workroom, and nil while the ref is unresolved.
  let branch: String?

  init(project: String, workroom: String? = nil, branch: String? = nil) {
    self.project = project
    self.workroom = workroom
    self.branch = branch
  }

  /// The separator between project and workroom. One value, so no surface can drift again.
  static let separator = " / "

  /// The full, untruncated title — `"project / workroom"`, or just the project for a root. What a
  /// tooltip shows, and the widest form a rail card can render.
  var full: String {
    workroom.map { "\(project)\(Self.separator)\($0)" } ?? project
  }

  /// The one segment that *distinguishes* this item from its peers. Generated workroom names share a
  /// project prefix and differ at the end, so when the prefix carries no information this is what
  /// survives. A root's distinguishing segment is its project — never its branch, which is state.
  var distinguishing: String { workroom ?? project }

  /// Titles for a whole rail (issue #132, D12): drop the project prefix when *every* item shares it,
  /// because a prefix repeated on all N cards costs width and distinguishes nothing. With two or more
  /// projects on the rail the prefix is load-bearing, so every card keeps its full title.
  ///
  /// Index-aligned with `labels`. Callers must still render with `.truncationMode(.middle)`: tail
  /// truncation eats the end of a generated name, which is exactly where two names differ.
  static func railTitles(_ labels: [WorkroomLabel]) -> [String] {
    let projects = Set(labels.map(\.project))
    return projects.count <= 1 ? labels.map(\.distinguishing) : labels.map(\.full)
  }
}
