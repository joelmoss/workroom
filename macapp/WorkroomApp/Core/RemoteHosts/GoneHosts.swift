import Combine
import Foundation
import WorkroomDomain

/// The remote hosts whose provider last said they are gone (#623 story 26, #629): a boxd machine
/// not found, a Railway sandbox destroyed. `HostReachability` keeps the set from each presence
/// read; this is its copy for the views. A gone workroom offers Remove Workroom and nothing else
/// (its menus, its row, its Details), and its panes stop attaching to a host that never comes back.
/// A live fact, never written to config: a later read that finds the host clears it.
@MainActor
final class GoneHosts: ObservableObject {
  static let shared = GoneHosts()

  @Published private(set) var hosts: Set<UUID> = []

  /// Whether host `id` is gone; false for no host.
  func contains(_ id: UUID?) -> Bool { id.map(hosts.contains) ?? false }

  /// Records what a presence read found, publishing only a change.
  func set(_ id: UUID, gone: Bool) {
    guard hosts.contains(id) != gone else { return }
    if gone { hosts.insert(id) } else { hosts.remove(id) }
  }

  /// `HostReachability`'s hook into the shared set, from any thread.
  nonisolated static func record(_ host: HostID, gone: Bool) {
    guard case .remote(let id) = host else { return }
    Task { @MainActor in shared.set(id, gone: gone) }
  }
}
