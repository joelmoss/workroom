import SwiftUI

/// Where each inspector section was scrolled to, per repository or folder a terminal's inspector
/// follows (#810). Not observed: a section reads it only when it switches, and a scroll writing it
/// must not re-render anything.
@MainActor
final class InspectorScrollMemory {
  private var offsets: [String: CGFloat] = [:]

  /// The offset last remembered under `key`, nil for one never scrolled.
  func offset(under key: String) -> CGFloat? { offsets[key] }

  func remember(_ offset: CGFloat, under key: String) { offsets[key] = offset }
}

/// Per-repository and per-folder inspector memory for a followed folder (#810, ADR 0081). Changes
/// and History remember their scroll per repository root, so a `cd` within one repository keeps
/// it; Files remembers its scroll per folder it shows (its expanded folders live in
/// `FileTreeModel`). Workroom and project inspectors remember nothing per target, as before.
extension AppStore {
  /// The key `section` remembers its state under for the inspector's subject, nil for a subject
  /// other than a followed folder.
  func inspectorMemoryKey(for section: InspectorSectionKind) -> String? {
    guard case .followed = inspectorSubject else { return nil }
    switch section {
    case .changes, .history, .pullRequest:
      return "\(section)\u{1F}\(inspectorSubject.repositoryKey)"
    case .files:
      return followedFilesRoot.map { "files\u{1F}\($0.fileRoot)\u{1F}\($0.path)" }
    }
  }
}

/// Keeps a SwiftUI inspector scroll view's offset in `memory` under `key` as the user scrolls, and
/// puts it back when the view returns to that key (#810). A nil `key` (a workroom's inspector) or
/// `memory` leaves the scroll view alone. Jumps, never animates: the inspector's existing content change is
/// the only transition.
struct InspectorScrollMemoryModifier: ViewModifier {
  let key: String?
  let memory: InspectorScrollMemory?
  @State private var position = ScrollPosition(edge: .top)
  /// The key whose offset the view now shows. Until a restore lands no scroll is recorded, so the
  /// last folder's offset is never kept under the next one's key.
  @State private var restored: String?

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
  func inspectorScrollMemory(key: String?, in memory: InspectorScrollMemory?) -> some View {
    modifier(InspectorScrollMemoryModifier(key: key, memory: memory))
  }
}
