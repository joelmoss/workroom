import Combine
import Foundation
import Synchronization
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
  /// The newest update applied to each host, so one that reaches the main actor late (its hop
  /// overtaken by a newer one's) never overwrites it.
  private var applied: [UUID: UInt64] = [:]
  /// Numbers each update as it is recorded, from any thread, in the order recorded.
  private nonisolated static let sequence = Mutex<UInt64>(0)

  /// Whether host `id` is gone; false for no host.
  func contains(_ id: UUID?) -> Bool { id.map(hosts.contains) ?? false }

  /// Records what a presence read found, publishing only a change.
  func set(_ id: UUID, gone: Bool) {
    apply(id, gone: gone, sequence: Self.nextSequence())
  }

  /// Applies update number `sequence` for `id`, unless a newer one was applied already.
  func apply(_ id: UUID, gone: Bool, sequence: UInt64) {
    guard sequence > applied[id, default: 0] else { return }
    applied[id] = sequence
    guard hosts.contains(id) != gone else { return }
    if gone { hosts.insert(id) } else { hosts.remove(id) }
  }

  nonisolated static func nextSequence() -> UInt64 {
    sequence.withLock {
      $0 += 1
      return $0
    }
  }

  /// `HostReachability`'s hook into the shared set, from any thread: numbered here, in the order
  /// recorded, and applied on the main actor in that order whatever order the hops arrive in.
  nonisolated static func record(_ host: HostID, gone: Bool) {
    guard case .remote(let id) = host else { return }
    let number = nextSequence()
    Task { @MainActor in shared.apply(id, gone: gone, sequence: number) }
  }
}
