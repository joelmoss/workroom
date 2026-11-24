import SwiftUI

/// Where each inspector section was scrolled to, per repository or folder a terminal's inspector
/// follows (#810). Not observed: a section reads it only when it switches, and a scroll writing it
/// must not re-render anything.
///
/// Bounded, least recently used first (#812 F7), and apart per kind, so browsing many folders in
/// one repository never evicts other repositories' Changes and History offsets.
@MainActor
final class InspectorScrollMemory {
  /// Changes, History and Pull Request, for this many repositories.
  nonisolated static let repositoryCapacity = 64
  /// Files, for this many folders.
  nonisolated static let folderCapacity = 256

  private var sections = RecentCache<InspectorMemoryKey, CGFloat>(
    capacity: repositoryCapacity * 3)
  private var folders = RecentCache<InspectorMemoryKey, CGFloat>(capacity: folderCapacity)

  /// The offset last remembered under `key`, nil for one never scrolled.
  func offset(under key: InspectorMemoryKey) -> CGFloat? {
    switch key {
    case .section: sections[key]
    case .files: folders[key]
    }
  }

  func remember(_ offset: CGFloat, under key: InspectorMemoryKey) {
    switch key {
    case .section: sections[key] = offset
    case .files: folders[key] = offset
    }
  }
}

/// What an inspector section remembers its scroll under for a followed folder (#810).
enum InspectorMemoryKey: Hashable, Sendable {
  /// Changes, History or Pull Request, per repository (or folder outside one).
  case section(InspectorSectionKind, InspectorSubject.Key)
  /// Files, per folder it shows: the root files open against, and the folder within it.
  case files(fileRoot: String, path: String)
}

/// Per-repository and per-folder inspector memory for a followed folder (#810, ADR 0081). Changes
/// and History remember their scroll per repository root, so a `cd` within one repository keeps
/// it; Files remembers its scroll per folder it shows (its expanded folders live in
/// `FileTreeModel`). Workroom and project inspectors remember nothing per target, as before.
extension AppStore {
  /// The key `section` remembers its state under for the inspector's subject, nil for a subject
  /// other than a followed folder.
  /// Nil too while the folder's repository is pending, whose sections show nothing to scroll.
  func inspectorMemoryKey(for section: InspectorSectionKind) -> InspectorMemoryKey? {
    // The repository part alone, so the version-control sections observe no `cd` within one
    // repository; Files reads its folder.
    let subject = inspectorRepositorySubject
    guard case .followed(let followed) = subject, !followed.repositoryPending else {
      return nil
    }
    switch section {
    case .changes, .history, .pullRequest:
      return .section(section, subject.repositoryKey)
    case .files:
      return followedFilesRoot.map { .files(fileRoot: $0.fileRoot, path: $0.path) }
    }
  }
}

/// Keeps a SwiftUI inspector scroll view's offset in `memory` under `key` as the user scrolls, and
/// puts it back when the view returns to that key (#810). A nil `key` (a workroom's inspector) or
/// `memory` leaves the scroll view alone. Jumps, never animates: the inspector's existing content change is
/// the only transition.
struct InspectorScrollMemoryModifier: ViewModifier {
  let key: InspectorMemoryKey?
  let memory: InspectorScrollMemory?
  @State private var position = ScrollPosition(edge: .top)
  /// The key whose offset the view now shows. Until a restore lands no scroll is recorded, so the
  /// last folder's offset is never kept under the next one's key.
  @State private var restored: InspectorMemoryKey?

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onScrollGeometryChange(for: CGFloat.self) {
        $0.contentOffset.y
      } action: { _, offset in
        guard let key, restored == key else { return }
        memory?.remember(offset, under: key)
      }
      .task(id: key) {
        restored = nil
        guard let key, let memory else { return }
        // After the content's first layout, so there is something to scroll.
        await Task.yield()
        guard !Task.isCancelled else { return }
        if let offset = memory.offset(under: key) {
          position.scrollTo(y: offset)
        } else {
          position.scrollTo(edge: .top)
        }
        restored = key
      }
  }
}

extension View {
  /// Remember this scroll view's offset per followed repository or folder (#810).
  func inspectorScrollMemory(key: InspectorMemoryKey?, in memory: InspectorScrollMemory?)
    -> some View
  {
    modifier(InspectorScrollMemoryModifier(key: key, memory: memory))
  }
}
