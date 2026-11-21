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
