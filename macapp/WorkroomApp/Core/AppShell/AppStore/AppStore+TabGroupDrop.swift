import CoreGraphics
import WorkroomDomain

/// A title-bar tab let go over another tab's middle (#652): the terminal drag's rules
/// (`AppStore.terminalDrop`) for a standalone terminal's or group's whole handle on that tab.
extension AppStore {
  /// Whether `dragged`'s title-bar tab, let go over the middle of `destination`'s, drops there.
  func canDropTab(_ dragged: SidebarID, onto destination: SidebarID) -> Bool {
    canDropTerminals(.entry(dragged), on: .target(destination))
  }

  /// Drops `dragged`'s title-bar tab on `destination`'s, when it can. Whether it did.
  @discardableResult
  func dropTab(_ dragged: SidebarID, onto destination: SidebarID) async -> Bool {
    await dropTerminals(.entry(dragged), on: .target(destination))
  }
}

extension TerminalsSection {
  /// Whether group `from`'s terminals can all move into group `into`: two listed groups, neither
  /// the Quick Terminal's.
  func canMergeGroup(_ from: TargetID, into: TargetID) -> Bool {
    guard from != into, let source = group(from), let destination = group(into) else {
      return false
    }
    return !source.isBuiltIn && !destination.isBuiltIn
  }

  /// Moves every holder's terminals in group `from` to the end of group `into`, in order and
  /// keeping their shells, and deletes `from`, now empty. Whether it did.
  func mergeGroup(_ from: TargetID, into: TargetID) async -> Bool {
    guard canMergeGroup(from, into: into) else { return false }
    return await rehome([(from, into)]) {
      guard canMergeGroup(from, into: into) else { return false }
      remove(from)
      return true
    }
  }
}
