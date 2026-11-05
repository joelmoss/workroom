import DaemonConnection
import Foundation
import WorkroomVCS

/// The services on a daemon connection that return the app's own types: repository reads and
/// writes, the disk facts the write classifier uses, files, layouts and port forwarding. They live
/// here, not in the DaemonConnection package with the transport, because those types are the app's.
extension DaemonVCSConnection: HostServiceConnection {
  /// The VCS `capabilities` request, which connecting asked already: the daemon answers it with a
  /// constant from a thread of its own, under no session lock, so a repaint can't hold it up. Any
  /// bytes arriving meanwhile answer too: on a slow link the reply can queue behind a large one
  /// still coming in, which proves the link alive. The caller bounds the wait: a short request
  /// timeout would also shorten the stall bound that fails the whole connection when a large send
  /// is slow (`request`).
  func ping() async throws {
    let before = bytesReceived
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { _ = try await self.request(DaemonVCSRequest(method: "capabilities")) }
      group.addTask {
        while self.bytesReceived == before { try await Task.sleep(for: .milliseconds(50)) }
      }
      try await group.next()
      group.cancelAll()
    }
  }

  func reader(context: RepositoryContext) throws -> VCSProviding {
    guard context.location.host == host else { throw HostConnectionError.mismatchedContext }
    guard !isClosed else { throw HostConnectionError.connectionLost }
    return DaemonVCSReader(context: context, connection: self)
  }

  /// `reader` is the SAME daemon-routed `VCSProviding` `HostConnectionManager.writer(context:)` just
  /// built — threaded through rather than reconstructed so `CLIVCSWriter.remoteState`'s `currentRef`
  /// read goes through the daemon too (`DaemonCurrentRefProvider`), not a fresh native process. A
  /// still-running pre-upgrade daemon has no write service at all; that is reported the same way an
  /// unsupported read version is, so `RepositoryRouter` falls back to native writes rather than
  /// leaving the repository unwritable.
  func writer(context: RepositoryContext, reader: VCSProviding) throws -> VCSWriting {
    guard context.location.host == host else { throw HostConnectionError.mismatchedContext }
    guard !isClosed else { throw HostConnectionError.connectionLost }
    // A remote host's writes need what exec version 3 added (#229): the host's own environment and
    // `stat` for the classifier's disk facts. An older
    // daemon there fails closed rather than writing on Mac-side assumptions.
    let remote = host != .local
    if remote {
      guard let exec = capabilities?.exec, exec >= Self.remoteWriteVersion else {
        throw HostConnectionError.serviceUnavailable(
          "The host's daemon is too old to change a repository there.")
      }
    }
    // Presence and version of the SERVICE, not a count of the caller's own methods. `>=` rather
    // than `==` so a daemon that gains a version 3 does not refuse a client speaking 1 — the daemon
    // is what decides whether it still accepts this request, and it answers that on the request
    // itself (`exec`'s version guard), which is the only place that can know.
    //
    // KNOWN GAP in that reasoning: a per-request refusal does NOT reach the native fallback. A
    // `BackendVersion` error arriving in a REPLY is decoded in `DaemonCommandRunner.exec`, throws,
    // and becomes `neverRan`/`launchFailed` — not the `VCSError.backendVersion` that
    // `RepositoryRouter.writer(for:)` falls back on. So a future daemon that DROPS version 1 would
    // fail every write as "launch failed" rather than writing natively. Nothing can hit this today
    // (no such daemon exists, and 2 still accepts 1), but the `>=` is justified by a mechanism that
    // is not wired up, and that is worth knowing before the first version that drops one.
    guard let exec = capabilities?.exec, exec >= Self.execVersion else {
      throw VCSError.backendVersion("Daemon does not support VCS writes.")
    }
    var engine = CLIVCSWriter(
      runner: DaemonCommandRunner(connection: self),
      makeProvider: { _ in DaemonCurrentRefProvider(reader: reader) }, gate: .shared)
    if remote {
      engine.host = host
      engine.stat = { [self] paths, read in try await stat(paths: paths, read: read) }
    }
    return try BoundLocalWriter(context: context, reader: reader, writer: engine)
  }

  /// Facts from the host's disk for `CLIVCSWriter`'s failure classifier (`stat` in `vcs.rs`):
  /// whether each path exists, is a directory and when it changed, and the text of those in `read`.
  func stat(paths: [String], read: [String]) async throws -> DiskSnapshot {
    let reply = try await request(DaemonStatRequest(paths: paths, read: read), timeout: 15)
    var entries: [String: DiskEntry?] = [:]
    var texts: [String: String] = [:]
    for entry in try DaemonVCSReply<DaemonStatReply>.decode(reply).entries {
      let found =
        entry.exists
        ? DiskEntry(
          isDirectory: entry.isDir,
          modifiedAt: entry.modifiedAt.map { Date(timeIntervalSince1970: $0) })
        : nil
      // `.some(nil)`: asked about and absent, which a snapshot tells apart from never asked.
      entries[entry.path] = .some(found)
      if let text = entry.text { texts[entry.path] = text }
    }
    return DiskSnapshot(entries: entries, texts: texts)
  }

  func files(context: FileContext) throws -> FileProviding {
    guard context.location.host == host else { throw HostConnectionError.mismatchedContext }
    guard !isClosed else { throw HostConnectionError.connectionLost }
    switch fileNegotiation {
    case .ready:
      return DaemonFileProvider(context: context, connection: self)
    case .unsupported:
      throw VCSError.backendVersion("Daemon does not support the file service.")
    case .failed:
      Task { await close() }
      throw HostConnectionError.serviceUnavailable("File service negotiation failed; reconnecting.")
    }
  }

  /// The layout service on this connection, or `VCSError.backendVersion` when the peer predates it
  /// (#255), checked against the peer's greeting as File is.
  func layouts() throws -> DaemonLayoutService {
    guard !isClosed else { throw HostConnectionError.connectionLost }
    // `helloVersion` is fixed at connect, so it needs no lock.
    guard helloVersion >= DaemonHandshake.minLayoutVersion else {
      throw VCSError.backendVersion("Daemon does not support the layout service.")
    }
    return DaemonLayoutService(connection: self)
  }

  /// A Layout request. 15s: a `put` syncs a file and its directory, and a `get` reads one.
  func layoutRequest(_ request: DaemonLayoutRequest) async throws -> Data {
    try await self.request(request, timeout: 15, service: Self.layoutService)
  }

  /// The port-forwarding service on this connection, or `VCSError.backendVersion` when the peer
  /// predates it (issue #208).
  ///
  /// There is no probe and no negotiation state to keep: `Service::Forward` has no `capabilities`
  /// method — its only request opens a real socket — so the peer's raw greeting version is the whole
  /// answer, checked the way File checks its own. A protocol-4 daemon drops a Forward
  /// envelope without answering it, so it is never sent one.
  func forwarding() throws -> DaemonForwardService {
    guard !isClosed else { throw HostConnectionError.connectionLost }
    // `helloVersion` is fixed at connect, so it needs no lock.
    guard helloVersion >= DaemonHandshake.minForwardVersion else {
      throw VCSError.backendVersion("Daemon does not support port forwarding.")
    }
    return DaemonForwardService(connection: self)
  }
}
