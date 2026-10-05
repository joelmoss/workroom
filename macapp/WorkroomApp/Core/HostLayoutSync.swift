import Foundation
import WorkroomSessionProtocol
import os

/// Where a remote workroom's layout is kept: its host's agent (`AgentLayoutService`), or a fake.
protocol HostLayoutStore: Sendable {
  func get(_ key: String) async throws -> AgentLayout
  func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64
}

extension AgentLayoutService: HostLayoutStore {}

/// What a Mac restores for a remote workroom when it opens it, and what it remembers about the
/// host's copy (#255, D4).
struct HostLayoutResolution: Equatable {
  /// The tabs to restore, or nil for none.
  var session: TargetSession?
  /// The host's revision this Mac now holds.
  var revision: UInt64
  /// This Mac's copy has not reached the host: it wins at the next open, and is written then.
  var stale = false
  /// A write the host refused because another Mac wrote first, as opposed to one that could not
  /// reach it.
  var refused = false
  /// The host's layout is from a newer build: this Mac restores its own copy, and never writes
  /// over the host's (D5).
  var readOnly = false
}

/// Deciding between this Mac's copy of a remote workroom's layout and its host's, and the host's
/// sessions the layout does not name. Pure apart from `store`, so it is tested against a fake.
enum HostLayoutSync {
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "HostLayout")

  /// What to restore for workroom `key` (this Mac's target `targetID`), from `held`, this Mac's own
  /// copy, if it has one, and the host's.
  ///
  /// - The host's is from a newer build: this Mac's copy is restored and nothing is written, even
  ///   over a stale mark, and on every open, not only the one that first saw it (D5).
  /// - This Mac's copy is newer (stale): it wins and is written, with the host's current revision
  ///   as the one it read, so the last Mac to change the layout wins (D9).
  /// - The host has none: this Mac's copy seeds it. A seed another Mac got in first is refused, and
  ///   that Mac's layout is adopted instead of being overwritten (R3-3).
  /// - The host's is another revision than the one this Mac last saw: it wins, with this Mac's
  ///   focus and popped-out frames put back (D12). Usually a newer one; an older one only when the
  ///   host's layouts were reset, and it is still the host's.
  /// - Otherwise this Mac's copy is the host's already.
  static func resolve(
    held: TargetSession?, key: String, targetID: String, store: HostLayoutStore
  ) async throws -> HostLayoutResolution {
    var answer = try await store.get(key)
    let newer = { (answer: AgentLayout) in
      answer.blob.map { HostLayout.decode($0, targetID: targetID) } == .newer
    }
    if newer(answer) {
      return HostLayoutResolution(session: held, revision: answer.revision, readOnly: true)
    }
    if let held, held.hostLayoutStale == true {
      return await write(held, key: key, expected: answer.revision, store: store)
    }
    if answer.revision == 0 {
      guard let held else { return HostLayoutResolution(session: nil, revision: 0) }
      do {
        let revision = try await store.put(
          key, expected: 0, blob: try HostLayout.encode(held, key: key))
        return HostLayoutResolution(session: held, revision: revision)
      } catch AgentLayoutError.stale {
        answer = try await store.get(key)
        if newer(answer) {
          return HostLayoutResolution(session: held, revision: answer.revision, readOnly: true)
        }
      } catch {
        return HostLayoutResolution(session: held, revision: 0, stale: true)
      }
    }
    if let blob = answer.blob, held == nil || answer.revision != held?.hostRevision {
      switch HostLayout.decode(blob, targetID: targetID) {
      case .layout(let layout):
        return HostLayoutResolution(
          session: HostLayout.refilled(layout, from: held), revision: answer.revision)
      case .empty:
        return HostLayoutResolution(session: nil, revision: answer.revision)
      case .newer:
        return HostLayoutResolution(session: held, revision: answer.revision, readOnly: true)
      case .unreadable:
        // Nothing to restore from it; this Mac's copy replaces it on the next write, as a copy
        // that has not reached the host.
        return HostLayoutResolution(session: held, revision: answer.revision, stale: held != nil)
      }
    }
    return HostLayoutResolution(session: held, revision: answer.revision)
  }

  /// Writes `held` over the host's layout at `expected`, once more at the current revision if
  /// another Mac wrote in between (its whole snapshot wins, D9), and says whether it got there.
  /// With one attempt a refusal is final: for a Mac that has not read the host's layout this
  /// launch, which must not replace one it never saw. Unless the host holds exactly `ownWrite`, a
  /// write of this Mac's own whose answer came too late to count: then it has seen that layout,
  /// and writes once more at its revision.
  static func write(
    _ held: TargetSession, key: String, expected: UInt64, store: HostLayoutStore, attempts: Int = 3,
    ownWrite: String? = nil
  ) async -> HostLayoutResolution {
    guard let blob = try? HostLayout.encode(held, key: key) else {
      return HostLayoutResolution(session: held, revision: expected, stale: true)
    }
    var expected = expected
    for _ in 0..<attempts {
      do {
        let revision = try await store.put(key, expected: expected, blob: blob)
        return HostLayoutResolution(session: held, revision: revision)
      } catch AgentLayoutError.stale(let current) {
        // Another Mac wrote first. A newer build's layout is never written over (D5), whoever
        // reads it first, and a layout that could not be read is not taken to be an older one.
        guard let answer = try? await store.get(key) else {
          return HostLayoutResolution(session: held, revision: expected, stale: true)
        }
        if let blob = answer.blob, HostLayout.decode(blob, targetID: held.targetID) == .newer {
          return HostLayoutResolution(session: held, revision: answer.revision, readOnly: true)
        }
        expected = current
      } catch {
        logger.error("Host refused workroom \(key, privacy: .public)'s layout: \(error)")
        return HostLayoutResolution(session: held, revision: expected, stale: true)
      }
    }
    if let ownWrite, let answer = try? await store.get(key), answer.blob == ownWrite,
      let revision = try? await store.put(key, expected: answer.revision, blob: blob)
    {
      return HostLayoutResolution(session: held, revision: revision)
    }
    logger.notice("Workroom \(key, privacy: .public)'s layout lost \(attempts) races on its host")
    return HostLayoutResolution(session: held, revision: expected, stale: true, refused: true)
  }

  /// `session` with a tab added, at the end of the strip, for each of the host's `sessions` tagged
  /// with workroom `key` that it does not name, oldest first. A session another Mac opened, or one
  /// a stale write left out, is never lost from view (premise 3).
  static func appending(
    _ sessions: [SessionDescriptor], key: String, to session: TargetSession?, targetID: String
  ) -> TargetSession? {
    let named = session?.sessionIDs ?? []
    let missing =
      sessions
      .filter { $0.value(forMetadataKey: SessionMetadataKey.workroom) == key }
      .filter { descriptor in
        guard let id = descriptor.identifier.uuid else { return false }
        return !named.contains(id)
      }
      .sorted { created($0) < created($1) }
    guard !missing.isEmpty else { return session }
    var result = session ?? TargetSession(targetID: targetID, tabs: [])
    for descriptor in missing {
      guard result.tabs.count < SessionLimits.maxTabsPerTarget,
        let id = descriptor.identifier.uuid
      else { break }
      let title = descriptor.value(forMetadataKey: SessionMetadataKey.title) ?? "Terminal"
      result.tabs.append(
        TabSession(
          key: UUID().uuidString, kind: TabSession.terminalKind,
          terminal: TerminalPayload(
            defaultTitle: title,
            cwd: descriptor.workingDirectory.isEmpty ? nil : descriptor.workingDirectory,
            sessionID: id.uuidString)))
    }
    return result
  }

  private static func created(_ descriptor: SessionDescriptor) -> UInt64 {
    descriptor.value(forMetadataKey: SessionMetadataKey.created).flatMap(UInt64.init) ?? 0
  }
}
