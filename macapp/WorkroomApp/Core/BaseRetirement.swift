import Foundation
import OSLog

/// Takes down the base machines older builds made (#395 follow-up). Since #395 every remote
/// workroom is a fresh host with its own clone and nothing reads a base, but a project an older
/// build made a remote workroom in still records one per provider, and those machines keep running:
/// exe.dev's never stop, and boxd's keep their disk.
///
/// Once per launch the app retires every base this build owns (`retireOnce`). First each of the
/// project's remote workrooms that recorded no repository gets its base's, which is where its PR
/// and CI status used to come from; then each base is destroyed and dropped from the project's
/// record. A base it cannot take down (its provider signed out, say) keeps its record, and the next
/// launch tries again. Another build's base is left to that build.
enum BaseRetirement {
  /// What retiring writes to config and takes down, as seams so a test needs no CLI or provider.
  struct Effects: Sendable {
    /// Stores `descriptor` on the project (`workroom` nil) or one of its workrooms; nil clears it.
    var setHost:
      @Sendable (_ project: String, _ workroom: String?, _ descriptor: HostDescriptor?) async throws
        -> Void
    /// Destroys a live base's machine.
    var destroy: @Sendable (_ base: HostDescriptor) async throws -> Void
  }

  /// The effects of the real CLI and providers.
  static func live(cli: any WorkroomCLIProtocol) -> Effects {
    Effects(
      setHost: { project, workroom, descriptor in
        try await cli.setHost(
          project: project, workroom: workroom,
          descriptor: try descriptor.map { try JSONEncoder().encode($0) })
      },
      destroy: { base in
        // Signed out of the base's provider: no environment, so it stays until a later launch.
        let environment = try await MainActor.run {
          try RemoteHosts.shared.environment(toDelete: [base])?.environment(for: base)
        }
        guard let id = base.id, let environment else { throw RemoteWorkrooms.Failure.signedOut }
        try await environment.driver.destroy(.remote(id))
      })
  }

  /// The bases `host`, a project's descriptor, records: a list under `bases` since #309, else the
  /// descriptor itself.
  static func bases(of host: HostDescriptor?) -> [HostDescriptor] {
    host.map { $0.bases ?? [$0] } ?? []
  }

  /// Retires `projects`' bases, once per launch and never in a test process, which would take down
  /// the developer's real machines. `onChange` runs when config changed, so the caller can reload.
  @MainActor
  static func retireOnce(
    _ projects: [Project], effects: Effects, onChange: @escaping @MainActor () -> Void,
    isTestProcess: Bool = UITestFixture.isTestProcess
  ) {
    guard !isTestProcess, !started, projects.contains(where: { $0.host != nil }) else { return }
    started = true
    Task {
      if await retire(projects, effects: effects) { onChange() }
    }
  }
  @MainActor private static var started = false

  /// Retires each project's bases in turn; one project's failure leaves the others to go. Returns
  /// whether config changed.
  static func retire(_ projects: [Project], effects: Effects) async -> Bool {
    var changed = false
    for project in projects where project.host != nil {
      do {
        if try await stampRepositories(of: project, effects: effects) { changed = true }
        if try await retireBases(of: project, effects: effects) { changed = true }
      } catch {
        logger.error(
          "retiring \(project.path, privacy: .public)'s bases: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    return changed
  }

  /// Records on each of `project`'s remote workrooms that has none the repository of the base an
  /// older build derived it from, so its PR and CI status outlive the base's record.
  static func stampRepositories(of project: Project, effects: Effects) async throws -> Bool {
    let bases = bases(of: project.host)
    var changed = false
    for workroom in project.workrooms {
      guard var host = workroom.host, host.repository == nil,
        // A descriptor from before the `driver` field is Docker's (`deletionKey`).
        let key = try? RemoteHosts.deletionKey(host),
        let base = base(in: bases, for: key), let repository = base.repository
      else { continue }
      host.repository = repository
      host.cloneURL = host.cloneURL ?? base.cloneURL
      try await effects.setHost(project.path, workroom.name, host)
      changed = true
    }
    return changed
  }

  /// Takes down each of `project`'s bases this build owns, dropping each from the project's record
  /// as it goes, so a failure leaves only what is still live recorded. A base without an id can't
  /// be told apart from another, so its record stays. One base's failure doesn't hold up the
  /// others; the first is thrown once they have been tried.
  static func retireBases(of project: Project, effects: Effects) async throws -> Bool {
    var left = bases(of: project.host)
    var changed = false
    var failure: Error?
    for base in left {
      guard let id = base.id, RemoteWorkrooms.ownsHost(base) else { continue }
      do {
        if RemoteWorkrooms.isLive(base) { try await effects.destroy(base) }
        let rest = left.filter { $0.id != id }
        try await effects.setHost(
          project.path, nil, rest.count > 1 ? HostDescriptor(bases: rest) : rest.first)
        left = rest
        changed = true
      } catch {
        failure = failure ?? error
      }
    }
    if let failure { throw failure }
    return changed
  }

  /// The base an older build derived a workroom on `key` from: the one made on that runtime and
  /// Docker context, else for Docker one made before #309, which names no context and follows the
  /// current one, as `key` does.
  static func base(in bases: [HostDescriptor], for key: RemoteHosts.DriverKey) -> HostDescriptor? {
    let keyed = bases.map { (base: $0, key: try? RemoteHosts.deletionKey($0)) }
    if let exact = keyed.first(where: { $0.key == key }) { return exact.base }
    // Only Docker has an unpinned form; a boxd base belongs to exactly one org and account.
    guard let runtime = key.runtime else { return nil }
    return keyed.first { $0.key == RemoteHosts.DriverKey(runtime: runtime) }?.base
  }

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "BaseRetirement")
}
