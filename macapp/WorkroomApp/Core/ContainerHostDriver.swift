import Foundation
import WorkroomWire

/// The first `HostDriver`: a Linux container running sshd and a supervised `wr-agent`
/// (`vcs/scripts/ssh-fixture`, #228), reached over plain ssh-stdio. It is the test fixture for
/// the remote path, and its ssh transport (`exec`, `attachCommand`) is the one a real
/// ssh-reachable driver shares (`BoxdHostDriver`, #256).
///
/// Its hosts are the ones the caller hands in, plus, given `Provisioning`, the containers it makes
/// itself (#252): `create` runs a workroom's host from the fixture's image, and `destroy` removes
/// it. Nothing here persists.
final class ContainerHostDriver: HostTerminalDriver, @unchecked Sendable {
  struct Host: Sendable {
    let address: String
    let port: Int
    let user: String
    /// The private key ssh authenticates with. The only credential used: `IdentitiesOnly` and
    /// `IdentityAgent none` keep the Mac's ssh agent and default keys out of it.
    let identityFile: String
    /// The host's public key, `<type> <base64>`, delivered out of band. It is the only key ssh
    /// accepts, and a mismatch fails closed: `BatchMode` cannot prompt to accept a new one.
    let hostKey: String
    /// The supervised agent's socket on the host.
    let agentSocket: String

    /// The agent's binary, beside its socket: what the app installs there (`AgentBootstrap`,
    /// #231), the supervisor starts, and the relay and the attach run. One directory per host,
    /// the socket's 0700 one, so the file has the socket's protection (design doc, the hand-off
    /// trust model: the socket is the boundary).
    var agentBinary: String { AgentBootstrap.binary(besideSocket: agentSocket) }
    /// Ghostty's terminfo and shell integration, which the bootstrap puts beside the agent (#239).
    var resources: String { AgentBootstrap.resources(besideSocket: agentSocket) }
  }

  /// How the driver makes containers of its own: a container runtime's CLI (`docker`), the
  /// fixture's image, and the client key every container authorises. Containers are reached on a
  /// loopback port the runtime publishes, as `vcs/scripts/ssh-fixture/run.sh` reaches its own.
  struct Provisioning: Sendable {
    let runtime: URL
    let image: String
    let user: String
    let identityFile: String
    /// The public half of `identityFile`, which the entrypoint writes to `authorized_keys`.
    let publicKey: String
    let agentSocket: String
    /// `key=value` labels on every container and image made, so whoever started the fixture can
    /// sweep up what a crashed test left (run.sh does).
    let labels: [String]
    /// The Docker context every command names (`--context`, #309), or nil for whichever daemon
    /// the environment and the CLI's current context pick. Docker Desktop, OrbStack and Colima
    /// are each a context behind the one `docker`, so without it a host made on one is looked for
    /// on whichever the user switched to since.
    var context: String? = nil
    /// Which runtime's CLI `runtime` is: Docker's, or Apple's `container` (#309).
    var dialect: Dialect = .docker
    /// CPUs and memory (`4G`) each container gets, or nil for the runtime's own default. Apple's is
    /// 1 GB per container VM, too little for a compiler or an agent; Docker's containers share its
    /// VM's.
    var cpus: Int? = nil
    var memory: String? = nil
  }

  /// The two container CLIs a driver can speak (#309). Apple's `container` (1.5.0) runs each
  /// container in a VM of its own and has no `--restart`, no `--filter` and no Go templates
  /// (`AppleContainerCLI`).
  enum Dialect: Sendable {
    case docker
    case apple
  }

  /// A host this driver made: its container, and for one an older build derived from a base, the
  /// image it was run from, which only it uses.
  private struct Provisioned {
    let container: String
    let image: String?
  }

  /// What a host this driver made needs to be reached and destroyed again by a driver in a later
  /// launch (#253): the `container` part of its host descriptor. The client key and the agent's
  /// socket are the driver's own (`Provisioning`), and the container's name follows from the
  /// host's ID.
  struct Record: Codable, Hashable, Sendable {
    let address: String
    let port: Int
    let user: String
    let hostKey: String
    /// The image a workroom an older build derived from a base was run from, which only it uses;
    /// nil for any other host.
    let image: String?
    /// The Docker context it runs in (`Provisioning.context`). nil, as every record made before
    /// #309 has it, follows the environment and the CLI's current context, as those always did.
    var context: String? = nil

    enum CodingKeys: String, CodingKey {
      case address, port, user, image, context
      case hostKey = "host_key"
    }
  }

  /// The label every container and image this driver makes carries, with when it was made in
  /// seconds since 1970, so `sweep` can leave one that may still be part of a create.
  static let createdLabel = "workroom.created"

  /// Where each host's `ssh_config` and `known_hosts` are written.
  let directory: URL
  let provisioning: Provisioning?
  private let lock = NSLock()
  private var hosts: [UUID: Host]
  private var provisioned: [UUID: Provisioned] = [:]
  /// Hosts this driver has destroyed, so destroying one again succeeds: a caller retrying after a
  /// later step of its own failed (forgetting its record) gets past the destroy it already did.
  private var destroyed: Set<UUID> = []

  init(hosts: [UUID: Host], directory: URL, provisioning: Provisioning? = nil) {
    self.hosts = hosts
    self.directory = directory
    self.provisioning = provisioning
  }

  private func target(_ host: HostID) throws -> (UUID, Host) {
    guard case .remote(let id) = host, let target = lock.withLock({ hosts[id] }) else {
      throw HostDriverError.unknownHost(host)
    }
    return (id, target)
  }

  func create() async throws -> HostID {
    guard let provisioning else { throw HostDriverError.notImplemented("Creating a host") }
    try await ensureImage(provisioning.image)
    return try await run(provisioning.image)
  }

  /// Pulls the host image unless this runtime has it. A create calls it before it names its
  /// workroom, so a download's progress (`pullProgress`) shows on the project's row, which is the
  /// one that shows it; `create` then finds the image there.
  func ensureHostImage() async throws {
    guard let provisioning else { throw HostDriverError.notImplemented("Creating a host") }
    try await ensureImage(provisioning.image)
  }

  /// Told how far a host image's pull has got, 0 to 1, then nil once it is done, for a create run
  /// inside `$pullProgress.withValue` (#309): a task-local, so `HostDriver.create` keeps its shape
  /// and two creates at once each hear only their own.
  @TaskLocal static var pullProgress: (@Sendable (Double?) -> Void)?

  /// Pulls `image` unless the runtime already has it (#309). `run` itself never pulls
  /// (`--pull=never`): left to it, a missing `workroom-host` was looked for on Docker Hub as
  /// `library/workroom-host`, and failed with a registry error that said nothing about why.
  private func ensureImage(_ image: String) async throws {
    let apple = provisioning?.dialect == .apple
    let inspect =
      apple ? ["image", "inspect", image] : ["image", "inspect", "--format", "{{.Id}}", image]
    do {
      _ = try await runtime(inspect)
      return
    } catch {
      // Missing, unless it's the runtime itself that didn't answer.
      if let down = Self.runtimeDown(error.localizedDescription, apple: apple) { throw down }
    }
    do {
      // Silence-bounded, and a pull reports its progress as it goes. Apple's unpacks every
      // platform of a multi-arch image unless told which, and it runs on Apple silicon only.
      let report = Self.pullProgress
      let progress = PullReader()
      _ = try await runtime(
        apple ? ["image", "pull", "--arch", "arm64", image] : ["pull", image], timeout: 900,
        onOutput: report.map { report in
          { data, stderr in
            if let fraction = progress.read(data, stderr: stderr) { report(fraction) }
          }
        })
      // The rest of the create (the setup, the clone) can take minutes, and isn't a download.
      report?(nil)
    } catch {
      let said = error.localizedDescription
      if let down = Self.runtimeDown(said, apple: apple) { throw down }
      if ["denied", "unauthorized", "forbidden", "manifest unknown"].contains(where: {
        said.lowercased().contains($0)
      }) {
        throw HostDriverError.provisioning(
          "the registry refused the workroom host image \(image): it isn't public, or this build "
            + "names one that doesn't exist. (\(said))")
      }
      throw HostDriverError.provisioning(
        "couldn't download the workroom host image \(image). Check your network connection, "
          + "then try again. (\(said))")
    }
  }

  /// The error for a runtime that didn't answer at all, by what it printed, or nil when it did
  /// (#309): every create's first command would otherwise blame the image or the network.
  static func runtimeDown(_ said: String, apple: Bool) -> Error? {
    if apple {
      guard said.contains("container system start") || said.contains("XPC connection") else {
        return nil
      }
      return HostDriverError.provisioning(
        "Apple's container runtime isn't running. Run `container system start`, then try again.")
    }
    // "Cannot connect to…", and a socket the user can't open ("permission denied while trying to
    // connect to the Docker daemon socket"), which the registry check would read as a refusal.
    let lowered = said.lowercased()
    guard
      ["connect to the docker daemon", "error during connect", "unable to resolve docker"]
        .contains(where: lowered.contains)
    else { return nil }
    return HostDriverError.provisioning(
      "Docker didn't answer. Start it (Docker Desktop, OrbStack or Colima), or check that the "
        + "Docker context is one on this Mac, then try again.")
  }

  /// A pull's output, read as it arrives from two streams at once.
  private final class PullReader: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = ImagePullProgress()
    private var last: Double?

    /// The fraction now, when it moved by a whole percent or more since the last one told.
    func read(_ data: Data, stderr: Bool) -> Double? {
      lock.withLock {
        progress.read(String(decoding: data, as: UTF8.self), stderr: stderr)
        guard let fraction = progress.fraction,
          last.map({ abs(fraction - $0) >= 0.01 }) ?? true
        else { return nil }
        last = fraction
        return fraction
      }
    }
  }

  /// Where an older build's Apple derive staged a base's exported disk, and the derived image's
  /// name: what a crash left with it is still swept.
  static let deriveDirectoryPrefix = "workroom-derive-"

  /// Removes the container and the image it alone was run from. A host handed in rather than
  /// made here is not this driver's to remove.
  func destroy(_ host: HostID) async throws {
    if case .remote(let id) = host, lock.withLock({ destroyed.contains(id) }) { return }
    guard case .remote(let id) = host, let made = lock.withLock({ provisioned[id] }) else {
      if case .remote(let id) = host, lock.withLock({ hosts[id] }) != nil {
        throw HostDriverError.notImplemented("Destroying a host this driver did not make")
      }
      throw HostDriverError.unknownHost(host)
    }
    if provisioning?.dialect == .apple {
      _ = try await runtime(["delete", "--force", made.container])
    } else {
      _ = try await runtime(["rm", "--force", "--volumes", made.container])
      if let image = made.image { _ = try await runtime(["rmi", "--force", image]) }
    }
    lock.withLock {
      hosts[id] = nil
      provisioned[id] = nil
      destroyed.insert(id)
    }
    forgetPending([made.container])
    try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
  }

  /// Starts `host`'s container if it is stopped, and waits until it can be logged in to (#309): a
  /// container someone stopped stays stopped, and a runtime with no restart policy (Apple's) leaves
  /// every one stopped after a reboot. Only for a workroom the user opens (`RemoteHosts.activate`),
  /// never for a background probe, which would start every container the app knows.
  func startIfStopped(_ host: HostID) async throws {
    guard case .remote(let id) = host, let made = lock.withLock({ provisioned[id] }) else {
      throw HostDriverError.unknownHost(host)
    }
    let stopped: Bool
    if provisioning?.dialect == .apple {
      let containers = try AppleContainerCLI.objects(
        try await runtime(["inspect", made.container], allLines: true))
      stopped = containers.first.flatMap(AppleContainerCLI.state) == "stopped"
    } else {
      stopped =
        try await runtime(["inspect", "--format", "{{.State.Running}}", made.container]) == "false"
    }
    guard stopped else { return }
    _ = try await runtime(["start", made.container])
    try await awaitLogin(host)
  }

  /// What a later launch's driver needs to `adopt` `host`, or nil for a host this driver did not
  /// make.
  func record(of host: HostID) -> Record? {
    guard case .remote(let id) = host else { return nil }
    return lock.withLock {
      guard let target = hosts[id], let made = provisioned[id] else { return nil }
      return Record(
        address: target.address, port: target.port, user: target.user, hostKey: target.hostKey,
        image: made.image, context: provisioning?.context)
    }
  }

  /// Takes a host an earlier launch made back on (#253), as its `record` describes it, so it can
  /// be reached and destroyed as if this driver had made it. Whether its container is still there
  /// is found out by using it.
  func adopt(_ id: UUID, _ record: Record) throws {
    guard let provisioning else { throw HostDriverError.notImplemented("Adopting a host") }
    // `destroy` removes it by this, with `--force`: a config edited by hand must not name an image
    // that is not an older derive's commit.
    if let image = record.image, !Self.isImageID(image) {
      throw HostDriverError.invalidConfiguration("image \(image) is not an image ID")
    }
    // Its container is on that context's daemon, which this driver's commands don't reach.
    guard record.context == provisioning.context else {
      throw HostDriverError.invalidConfiguration(
        "host is in Docker context \(record.context ?? "(current)"), not "
          + (provisioning.context ?? "(current)"))
    }
    lock.withLock {
      hosts[id] = Host(
        address: record.address, port: record.port, user: record.user,
        identityFile: provisioning.identityFile, hostKey: record.hostKey,
        agentSocket: provisioning.agentSocket)
      provisioned[id] = Provisioned(container: Self.containerName(id), image: record.image)
      destroyed.remove(id)
    }
  }

  /// Removes the containers and images carrying this driver's labels that are not `known` hosts'
  /// (#252, #253): what a crash left, a `commit` or `run` that finished in the daemon after its
  /// killed CLI's cleanup, a host whose record was lost. Anything made within `grace` is left,
  /// since it may belong to a create or derive still under way, in this app or another sharing
  /// the daemon. Returns what it could not remove.
  /// ponytail: a resource made before `createdLabel` existed has no age and counts as old.
  /// `images` are images other drivers' hosts were run from, kept too: a driver for another Docker
  /// context can reach the same daemon (#309).
  ///
  /// A container is a live workroom's until proven otherwise, and removing one loses its unpushed
  /// work (#284), so it goes only once two sweeps in a row (two launches: the app sweeps once per
  /// launch) found it unknown, and at most `cap` go per sweep (`confirmedUnknown`). A config that
  /// was lost, restored or half-written then costs nothing on the launch that reads it. Images are
  /// not held back: one a container still runs from is never removed.
  ///
  /// `onlyPending` sweeps only containers a create began and no record has named since
  /// (`pendingContainers`), and no images: for when config records nothing, which is also what a
  /// lost config or a launch with a throwaway `HOME` reads, where every live container would
  /// otherwise look unknown.
  func sweep(
    keeping known: Set<UUID>, images: Set<String> = [], grace: TimeInterval = 20 * 60,
    cap: Int = 3, onlyPending: Bool = false
  ) async -> [String] {
    guard let provisioning, !provisioning.labels.isEmpty else { return [] }
    if provisioning.dialect == .apple {
      return await appleSweep(
        keeping: known, images: images, grace: grace, cap: cap, onlyPending: onlyPending)
    }
    let filters = provisioning.labels.flatMap { ["--filter", "label=\($0)"] }
    let cutoff = Date().timeIntervalSince1970 - grace
    func old(_ created: Substring) -> Bool { (TimeInterval(created) ?? 0) <= cutoff }
    var failed: [String] = []

    let keptContainers = Set(known.map(Self.containerName))
    let keptImages = Set(
      (lock.withLock { known.compactMap { provisioned[$0]?.image } } + images).map(
        Self.shortImageID))
    let pending = onlyPending ? pendingContainers : []
    do {
      var unknown: [String] = []
      for line in try await runtime(
        ["ps", "-a"] + filters + ["--format", "{{.Names}}\t{{.Label \"\(Self.createdLabel)\"}}"],
        allLines: true
      ).split(separator: "\n") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        let name = String(fields[0])
        if !keptContainers.contains(name), old(fields.count > 1 ? fields[1] : ""),
          !onlyPending || pending.contains(name)
        {
          unknown.append(name)
        }
      }
      var removed: [String] = []
      for name in confirmedUnknown(unknown, cap: cap, failed: &failed) {
        do {
          _ = try await runtime(["rm", "--force", "--volumes", name])
          removed.append(name)
        } catch {
          failed.append("container \(name): \(error.localizedDescription)")
        }
      }
      forgetPending(removed)
    } catch { failed.append(Self.listingFailed + error.localizedDescription) }
    guard !onlyPending else { return failed }

    do {
      let images = try await runtime(["images", "-aq"] + filters, allLines: true)
        .split(separator: "\n").map(String.init)
      for image in Set(images) where !keptImages.contains(Self.shortImageID(image)) {
        // One that cannot be inspected is left for the next sweep.
        guard
          let created = try? await runtime(
            [
              "image", "inspect", "--format", "{{index .Config.Labels \"\(Self.createdLabel)\"}}",
              image,
            ]),
          old(Substring(created))
        else { continue }
        // Without `--force`: an image any container was run from is in use, and stays, so a
        // `known` host this driver has not adopted keeps its image too.
        do { _ = try await runtime(["rmi", image]) } catch {
          failed.append("image \(image): \(error.localizedDescription)")
        }
      }
    } catch { failed.append("listing images: \(error.localizedDescription)") }
    return failed
  }

  /// Apple's sweep (#309): the same rules as Docker's, read from JSON, since its CLI has no
  /// `--filter` and no templates. An image is kept while any container at all was run from it:
  /// Apple removes an image a container still uses, where Docker refuses.
  private func appleSweep(
    keeping known: Set<UUID>, images kept: Set<String>, grace: TimeInterval, cap: Int,
    onlyPending: Bool
  ) async -> [String] {
    guard let provisioning else { return [] }
    let cutoff = Date().timeIntervalSince1970 - grace
    func ours(_ labels: [String: String]) -> Bool {
      provisioning.labels.allSatisfy { label in
        let parts = label.split(separator: "=", maxSplits: 1).map(String.init)
        return parts.count == 2 && labels[parts[0]] == parts[1]
      }
    }
    func old(_ labels: [String: String]) -> Bool {
      (labels[Self.createdLabel].flatMap(TimeInterval.init) ?? 0) <= cutoff
    }
    var failed: [String] = []
    // A derive a crash cut short leaves its staged disk behind, the size of a base's whole disk. One
    // still under way is writing to it, which keeps its newest time recent.
    let temp = FileManager.default.temporaryDirectory
    for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
    where name.hasPrefix(Self.deriveDirectoryPrefix) {
      let directory = temp.appendingPathComponent(name)
      let times =
        ([directory]
        + ((try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []))
        .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }
        .compactMap(\.contentModificationDate)
      if let newest = times.max(), newest.timeIntervalSince1970 <= cutoff {
        try? FileManager.default.removeItem(at: directory)
      }
    }
    let keptContainers = Set(known.map(Self.containerName))
    var inUse = kept
    let pending = onlyPending ? pendingContainers : []
    do {
      var unknown: [String] = []
      for container in try AppleContainerCLI.objects(
        try await runtime(["list", "--all", "--format", "json"], allLines: true))
      {
        // A derive's snapshot is the exception: its container runs without it (1.5.0, measured),
        // and one whose delete failed would otherwise hold a whole disk for the workroom's life.
        if let image = AppleContainerCLI.imageReference(of: container),
          !image.contains(Self.deriveDirectoryPrefix)
        {
          inUse.insert(image)
        }
        let labels = AppleContainerCLI.labels(of: container)
        if let id = AppleContainerCLI.id(of: container), ours(labels), old(labels),
          !keptContainers.contains(id), !onlyPending || pending.contains(id)
        {
          unknown.append(id)
        }
      }
      var removed: [String] = []
      for id in confirmedUnknown(unknown, cap: cap, failed: &failed) {
        do {
          _ = try await runtime(["delete", "--force", id])
          removed.append(id)
        } catch {
          failed.append("container \(id): \(error.localizedDescription)")
        }
      }
      forgetPending(removed)
    } catch {
      // Without the list, no image is known to be unused.
      return [Self.listingFailed + error.localizedDescription]
    }
    guard !onlyPending else { return failed }
    do {
      for image in try AppleContainerCLI.objects(
        try await runtime(["image", "list", "--format", "json"], allLines: true))
      {
        let labels = AppleContainerCLI.labels(ofImage: image)
        guard let name = AppleContainerCLI.name(ofImage: image), ours(labels), old(labels),
          !inUse.contains(name)
        else { continue }
        do { _ = try await runtime(["image", "delete", name]) } catch {
          failed.append("image \(name): \(error.localizedDescription)")
        }
      }
    } catch { failed.append("listing images: \(error.localizedDescription)") }
    return failed
  }

  /// Which of `unknown`, this sweep's unknown containers, it removes (#284): those the previous
  /// sweep found unknown too, and of them at most `cap`, in listing order. Writes `unknown` down for
  /// the next sweep, so the ones past the cap go on later launches, `cap` at a time; one this sweep
  /// removes is gone from the next one's listing. Only a sweep whose listing was read writes it,
  /// so a failed listing keeps the last one.
  private func confirmedUnknown(_ unknown: [String], cap: Int, failed: inout [String]) -> [String] {
    let file = unknownContainersFile
    let before = Set(
      (try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) ?? [])
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(unknown).write(to: file, options: .atomic)
    } catch {
      // The list left behind is an older sweep's, not this one's predecessor: confirming against
      // it, now or next time, would take a container that was known in between. So it goes, and
      // this sweep removes nothing.
      try? FileManager.default.removeItem(at: file)
      failed.append("recording unknown containers: \(error.localizedDescription)")
      return []
    }
    let confirmed = unknown.filter(before.contains)
    if confirmed.count > cap {
      failed.append(
        "\(confirmed.count - cap) unknown container(s) left for a later launch: at most \(cap) go "
          + "per sweep")
    }
    return Array(confirmed.prefix(cap))
  }

  /// Where a sweep writes down the containers it found unknown (#284): beside this driver's hosts,
  /// one file per runtime and Docker context, since each context is swept by its own driver.
  private var unknownContainersFile: URL {
    directory.appendingPathComponent(
      "unknown-containers-\(Self.suffix(provisioning?.dialect ?? .docker, provisioning?.context)).json"
    )
  }

  /// The containers this driver began running that no config record names yet (#284), one file per
  /// runtime and Docker context. A name goes in before its `run`, and out once config records its
  /// host (`RemoteHosts.adopt`) or it is removed. So a crash before a new workroom's host was
  /// recorded still leaves its container named here, and a launch whose config records nothing
  /// sweeps only these (`sweep(onlyPending:)`), never a live workroom that config fails to show.
  /// ponytail: a container removed by hand stays listed, costing its runtime one listing a launch;
  /// a name is not dropped for being missing, since a context with none named lists whichever
  /// daemon is current, and the leftover may be on another.
  var pendingContainers: Set<String> {
    pendingLock.withLock { Set(readPending()) }
  }
  private var pendingFile: URL {
    directory.appendingPathComponent(
      Self.pendingPrefix + Self.suffix(provisioning?.dialect ?? .docker, provisioning?.context)
        + ".json")
  }
  private static let pendingPrefix = "pending-containers-"
  private let pendingLock = NSLock()

  private func readPending() -> [String] {
    (try? JSONDecoder().decode([String].self, from: Data(contentsOf: pendingFile))) ?? []
  }

  /// Rewrites the pending list as `change` leaves it, removing the file once it is empty.
  private func updatePending(_ change: (inout [String]) -> Void) throws {
    try pendingLock.withLock {
      var names = readPending()
      let before = names
      change(&names)
      guard names != before else { return }
      guard !names.isEmpty else {
        try FileManager.default.removeItem(at: pendingFile)
        return
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONEncoder().encode(names).write(to: pendingFile, options: .atomic)
    }
  }

  /// Takes `names` off the pending list: config records their hosts now, or they are gone.
  func forgetPending(_ names: [String]) {
    guard !names.isEmpty else { return }
    let drop = Set(names)
    try? updatePending { $0.removeAll(where: drop.contains) }
  }

  /// A file name's runtime and Docker context. `@` is in no context's name, so no context (the
  /// current one) is told apart from one named `default`.
  private static func suffix(_ dialect: Dialect, _ context: String?) -> String {
    (dialect == .apple ? "apple" : "docker") + (context.map { "@\($0)" } ?? "")
  }

  /// The runtimes and Docker contexts whose drivers, with hosts in `directory`, have containers
  /// pending (`pendingContainers`).
  static func pending(in directory: URL) -> [(dialect: Dialect, context: String?)] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).compactMap {
      guard $0.hasPrefix(pendingPrefix), $0.hasSuffix(".json") else { return nil }
      let parts = $0.dropFirst(pendingPrefix.count).dropLast(".json".count)
        .split(separator: "@", maxSplits: 1)
      let context = parts.count > 1 ? String(parts[1]) : nil
      switch parts.first {
      case "docker": return (.docker, context)
      case "apple": return (.apple, nil)
      default: return nil
      }
    }
  }

  /// How a sweep's failure starts when it could not list the containers, so swept nothing: the
  /// runtime was down, say. `RemoteHosts.adopt` sweeps that runtime again on a later reload.
  static let listingFailed = "listing containers: "

  static func containerName(_ id: UUID) -> String { "workroom-\(id.uuidString.lowercased())" }

  private static func created() -> String {
    "\(createdLabel)=\(Int(Date().timeIntervalSince1970))"
  }

  /// `sha256:<64 hex>`, as `commit` prints it.
  static func isImageID(_ text: String) -> Bool {
    let hex = text.dropFirst("sha256:".count)
    return text.hasPrefix("sha256:") && hex.count == 64
      && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  /// `images -q` prints the first 12 hex digits; `commit` the whole `sha256:` ID.
  private static func shortImageID(_ image: String) -> String {
    String(image.replacingOccurrences(of: "sha256:", with: "").prefix(12))
  }

  /// Runs a container from `source` and waits until it can be reached: its identity minted, its
  /// host key pinned, and an ssh login through this driver's own configuration answering. A
  /// container that gets no further is removed.
  private func run(_ source: String) async throws -> HostID {
    guard let provisioning else { throw HostDriverError.notImplemented("Provisioning") }
    // A port of its own rather than an ephemeral one (`127.0.0.1::22`): a restart keeps it, so the
    // host's address outlives a reboot, as a provider's box keeps its address.
    // ponytail: the port is free when chosen, not when the runtime binds it; a run that loses
    // that race fails and is rolled back like any other.
    guard let (probe, port) = LoopbackSocket.listen() else {
      throw HostDriverError.provisioning("no free loopback port: errno \(errno)")
    }
    Darwin.close(probe)
    let id = UUID()
    // Named here, not by the runtime's own ID, which is known only from its output: a run that
    // outlives its CLI still leaves a container this name removes.
    let container = Self.containerName(id)
    // Before the container exists: a crash from here on leaves its name pending (#284).
    try updatePending { $0.append(container) }
    do {
      // Docker's `unless-stopped`: a Docker or Mac restart brings it back, on the port its record
      // names. Apple's runtime has no restart policy; opening the workroom starts it
      // (`startIfStopped`), on the port it keeps.
      // In steps, typed: as one expression, CI's Swift gave up type-checking it.
      var arguments: [String] =
        provisioning.dialect == .apple
        ? ["run", "--detach", "--init", "--arch", "arm64"]
        : ["run", "--pull=never", "--detach", "--init", "--restart", "unless-stopped"]
      if let cpus = provisioning.cpus { arguments += ["--cpus", String(cpus)] }
      if let memory = provisioning.memory { arguments += ["--memory", memory] }
      arguments += ["--name", container, "--publish", "127.0.0.1:\(port):22"]
      for label in provisioning.labels + [Self.created()] { arguments += ["--label", label] }
      arguments += ["--env", "AUTHORIZED_KEY=\(provisioning.publicKey)", source]
      _ = try await runtime(arguments)
      let hostKey = try await identity(of: container)
      lock.withLock {
        hosts[id] = Host(
          address: "127.0.0.1", port: Int(port), user: provisioning.user,
          identityFile: provisioning.identityFile, hostKey: hostKey,
          agentSocket: provisioning.agentSocket)
        provisioned[id] = Provisioned(container: container, image: nil)
      }
      try await awaitLogin(.remote(id))
      return .remote(id)
    } catch {
      lock.withLock {
        hosts[id] = nil
        provisioned[id] = nil
      }
      let remove =
        provisioning.dialect == .apple
        ? ["delete", "--force", container] : ["rm", "--force", "--volumes", container]
      let removal = await Task { () -> String? in
        do {
          _ = try await self.runtime(remove)
          return nil
        } catch { return "container \(container): \(error.localizedDescription)" }
      }.value
      if removal == nil { forgetPending([container]) }
      // The login wait wrote the host's ssh_config and pinned key here.
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
      guard let removal else { throw error }
      throw HostDriverError.leftBehind(cause: error.localizedDescription, leftover: [removal])
    }
  }

  /// The container's ssh host key, read through the runtime once its entrypoint has minted it
  /// (the image's `identity.sh`, which run.sh reads it through too): delivered out of band, as
  /// every driver's must be (design doc, host-key policy).
  private func identity(of container: String) async throws -> String {
    for _ in 0..<100 {
      if let key = try? await runtime(["exec", container, "identity.sh"]),
        key.split(separator: " ").count == 2
      {
        return key
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw HostDriverError.provisioning("\(container) never minted its identity")
  }

  /// sshd starts a moment after the identity is minted, so the first login can be refused.
  private func awaitLogin(_ host: HostID) async throws {
    var last = ""
    for _ in 0..<50 {
      let (status, output) = try await exec("true", on: host).communicate(nil, timeout: 20)
      if status == 0 { return }
      last = output
      try await Task.sleep(for: .milliseconds(200))
    }
    throw HostDriverError.provisioning("ssh never let us in: \(last)")
  }

  /// One runtime command; its first line of output, which is all most of these print on success,
  /// or with `allLines` all of it. Its environment is the few variables that say which daemon to
  /// talk to, never the app's whole one.
  private func runtime(
    _ arguments: [String], timeout: TimeInterval = 120, allLines: Bool = false,
    onOutput: (@Sendable (Data, _ stderr: Bool) -> Void)? = nil
  ) async throws -> String {
    guard let provisioning else { throw HostDriverError.notImplemented("Provisioning") }
    let environment = ProcessInfo.processInfo.environment.filter {
      ["HOME", "PATH", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG"].contains($0.key)
    }
    let (status, output) = try await HostStream.spawn(
      provisioning.runtime, Self.runtimeArguments(arguments, context: provisioning.context),
      environment: environment, handshakeTimeout: 20, purpose: .exchange
    ).communicate(nil, timeout: timeout, onOutput: onOutput)
    let said = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard status == 0 else {
      if let context = provisioning.context, said.contains("context not found") {
        throw HostDriverError.provisioning(
          "the Docker context \(context) this host was made in no longer exists. Create it "
            + "again (`docker context create \(context)`), or delete the workroom.")
      }
      throw HostDriverError.provisioning(
        "\(provisioning.runtime.lastPathComponent) \(arguments[0]) exited \(status): \(said)")
    }
    return allLines ? said : said.split(separator: "\n").first.map(String.init) ?? ""
  }

  /// `arguments` for the runtime, naming `context` when there is one. `--context` is global, so it
  /// goes before the command (after it, Docker refuses it), and it outranks both `DOCKER_HOST` and
  /// `DOCKER_CONTEXT` (Docker 29, measured).
  static func runtimeArguments(_ arguments: [String], context: String?) -> [String] {
    guard let context else { return arguments }
    return ["--context", context] + arguments
  }

  /// The Docker context the CLI would use now, to pin a new host to (#309), or nil for `default`:
  /// that one is whatever `DOCKER_HOST` says, so naming it pins nothing. Asks a driver whose own
  /// context is nil, so the answer is the environment's and the CLI's.
  func currentContext() async throws -> String? {
    let name = try await runtime(["context", "show"])
    return name.isEmpty || name == "default" ? nil : name
  }

  func openStream(to host: HostID) async throws -> HostStream {
    let (id, target) = try target(host)
    return try Self.exec(
      Self.relayCommand(binary: target.agentBinary, socket: target.agentSocket), on: target,
      in: directory.appendingPathComponent(id.uuidString), purpose: .connection)
  }

  func exec(_ command: String, on host: HostID) async throws -> HostStream {
    let (id, target) = try target(host)
    return try Self.exec(
      command, on: target, in: directory.appendingPathComponent(id.uuidString),
      purpose: .exchange)
  }

  func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)]
  ) throws -> String {
    let (id, target) = try target(host)
    return try Self.attachCommand(
      to: target, in: directory.appendingPathComponent(id.uuidString), session: session,
      workingDirectory: workingDirectory, restored: restored, metadata: metadata)
  }

  /// Whether the last attach of `session` was refused by `host` in a way that does not heal: a
  /// changed host key, a key it will not take, nothing to agree a cipher on (#241). Everything
  /// else is worth trying again: a host that is booting refuses, times out, or accepts and closes
  /// before its banner, and some of those leave ssh nothing to say at `LogLevel ERROR`.
  func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    return Self.refusedLastAttach(of: session, in: directory.appendingPathComponent(id.uuidString))
  }

  func lastAttachLostLink(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    return Self.lostLinkLastAttach(of: session, in: directory.appendingPathComponent(id.uuidString))
  }

  // MARK: The ssh transport, which any ssh-reachable driver shares (boxd's, #256)

  /// Runs `command` on `host` over ssh, with the host's `ssh_config` and `known_hosts` written to
  /// `hostDirectory` first.
  static func exec(
    _ command: String, on host: Host, in hostDirectory: URL, purpose: HostStream.Purpose
  ) throws -> HostStream {
    try exec(command, via: route(to: host, in: hostDirectory), purpose: purpose)
  }

  /// How `/usr/bin/ssh` reaches a host: the options ahead of the destination, the destination,
  /// and the environment ssh runs with.
  struct Route: Sendable {
    let options: [String]
    let destination: String
    var environment: [String: String] = [:]
  }

  /// `host` through its own `ssh_config`, written to `hostDirectory`, and nothing from the app's
  /// environment: ssh needs none of it with this configuration, and `SSH_AUTH_SOCK` in particular
  /// is a Mac credential. `-F` also keeps `/etc/ssh/ssh_config` out, whose `SendEnv LANG LC_*`
  /// would send the Mac's locale across.
  static func route(to host: Host, in hostDirectory: URL) throws -> Route {
    Route(
      options: ["-F", try writeConfiguration(for: host, in: hostDirectory).path],
      destination: alias)
  }

  /// Runs `command` over `route`.
  static func exec(_ command: String, via route: Route, purpose: HostStream.Purpose) throws
    -> HostStream
  {
    try HostStream.spawn(
      URL(fileURLWithPath: "/usr/bin/ssh"), route.options + [route.destination, command],
      environment: route.environment,
      // ssh connects and authenticates before the agent can greet. `ConnectTimeout` bounds the
      // connect; this leaves room for the rest.
      handshakeTimeout: 20, purpose: purpose)
  }

  /// The command a pane runs to attach to `session` on `host` over ssh, with the host's
  /// configuration written to `hostDirectory`.
  static func attachCommand(
    to host: Host, in hostDirectory: URL, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)] = []
  ) throws -> String {
    attachCommand(
      via: try route(to: host, in: hostDirectory), in: hostDirectory,
      agentSocket: host.agentSocket, session: session, workingDirectory: workingDirectory,
      restored: restored, metadata: metadata)
  }

  /// The command a pane runs to attach to `session` over `route`, keeping ssh's log in
  /// `hostDirectory`.
  static func attachCommand(
    via route: Route, in hostDirectory: URL, agentSocket: String, session: UUID,
    workingDirectory: String, restored: Bool, metadata: [(key: String, value: String)] = []
  ) -> String {
    // `-t`: the attach client on the far side wants a terminal, for raw mode and the pane's size,
    // and ssh forwards the pane's resizes to it. It outranks the config's `RequestTTY no`, which
    // is right for the service stream.
    let log = attachLog(session, in: hostDirectory).path
    let environment = route.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    let ssh =
      (environment.isEmpty ? [] : ["/usr/bin/env"] + environment) + ["/usr/bin/ssh"]
      + route.options + [
        "-E", log, "-o", "PermitLocalCommand=yes", "-o", "LocalCommand=printf '\\0338\\033[J'",
        "-t", route.destination,
        remoteAttachCommand(
          binary: AgentBootstrap.binary(besideSocket: agentSocket), session: session,
          socket: agentSocket, resources: AgentBootstrap.resources(besideSocket: agentSocket),
          workingDirectory: workingDirectory, restored: restored, metadata: metadata),
      ]
    return (["/bin/sh", "-c", attachWrapper, "workroom-attach", log] + ssh)
      .map(shellQuoted).joined(separator: " ")
  }

  /// What a pane runs around its ssh (#241), as `sh -c <this> workroom-attach <log> <ssh argv>`.
  ///
  /// ssh's own messages go to the session's log (`-E`), so the app can read why the last attach
  /// failed (`hostRefusedLastAttach`) rather than guess from the status, which is 255 for all of
  /// them. A refusal's message is then copied onto the screen, where ssh would have printed it:
  /// the pane stops retrying one, and its reason (a changed host key, a refused key) is what the
  /// user has to act on. Any other lost link says, in plain words, that the pane keeps trying
  /// (`retryNotice`); ssh's own reason stays in the log.
  /// Until ssh is in, the pane says what it is waiting for; `LocalCommand`, which ssh runs once it
  /// has authenticated and before the session starts, restores the cursor saved ahead of that line
  /// and erases from there (DECSC, DECRC, ED), so an attach that goes through shows only the
  /// session, however many rows the line wrapped onto. `SHELL` is what ssh runs `LocalCommand`
  /// with, so it is a POSIX one.
  ///
  /// ssh's status goes beside the log (`attachStatus`), because the pane's own exit status never
  /// carries it: on macOS libghostty starts every command under `/usr/bin/login`, which exits 0
  /// whatever ran under it (#392). The status is removed before ssh starts, so a wrapper killed
  /// before it writes one leaves none rather than the last attach's.
  static let attachWrapper = """
    log=$1; shift; printf '\\0337%s' "workroom: waiting for this terminal's host..."; \
    : > "$log"; rm -f "${log%.log}.status"; \
    SHELL=/bin/sh "$@"; status=$?; echo "$status" > "${log%.log}.status"; \
    if [ "$status" = 255 ] && ! grep -qiF \(refusalPatterns) "$log"; then \
    printf '\\r\\n%s\\r\\n' \(shellQuoted(retryNotice)) >&2; \
    elif [ -s "$log" ]; then printf '\\r\\n'; cat "$log" >&2; fi; exit "$status"
    """

  /// `refusals` as `grep -e` arguments.
  private static let refusalPatterns = refusals.map { "-e " + shellQuoted($0) }.joined(
    separator: " ")

  /// What a pane whose link dropped says while it keeps trying (#392).
  static let retryNotice =
    "Can't reach this terminal's host right now. Workroom will keep trying, and your session "
    + "will be restored when it connects."

  /// Where a pane's ssh writes its messages (`-E`): one file per session, emptied by each attach.
  static func attachLog(_ session: UUID, in hostDirectory: URL) -> URL {
    hostDirectory.appendingPathComponent("attach-\(session.uuidString).log")
  }

  /// Where the attach wrapper writes ssh's exit status, beside `attachLog`.
  static func attachStatus(_ session: UUID, in hostDirectory: URL) -> URL {
    hostDirectory.appendingPathComponent("attach-\(session.uuidString).status")
  }

  /// Whether the last attach of `session` ended with ssh's own failure, 255: the link dropped or
  /// never came up, as after laptop sleep, a network change or the host restarting.
  static func lostLinkLastAttach(of session: UUID, in hostDirectory: URL) -> Bool {
    (try? String(contentsOf: attachStatus(session, in: hostDirectory), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) == "255"
  }

  /// Whether the last attach of `session`, whose log is in `hostDirectory`, was refused.
  static func refusedLastAttach(of session: UUID, in hostDirectory: URL) -> Bool {
    isRefusal(
      (try? String(contentsOf: attachLog(session, in: hostDirectory), encoding: .utf8)) ?? "")
  }

  /// ssh's messages for a host that answered and will keep saying no. Listed rather than the
  /// failures that heal, because those are open-ended: a gateway in front of a rebooting VM, or a
  /// socket-activated sshd, can fail in words no list has seen. An authentication denial is
  /// `Permission denied (<methods>)`; a bare `Permission denied` is a connect a firewall refused,
  /// which can heal.
  static func isRefusal(_ log: String) -> Bool {
    let log = log.lowercased()
    return refusals.contains { log.contains($0) }
  }

  /// `isRefusal`'s messages, lowercase. The attach wrapper matches the same ones, ignoring case.
  static let refusals = [
    "host key verification failed", "remote host identification has changed",
    "permission denied (", "too many authentication failures", "unable to negotiate",
    "load key", "bad owner or permissions",
  ]

  /// What runs on the host, in the pty ssh allocates there.
  ///
  /// The session contract is the environment `wr-agent attach` reads, set with `env` because ssh
  /// carries none of the pane's own. Deliberately absent: the shell (the host's own login shell
  /// applies).
  ///
  /// The terminal is the pane's own `xterm-ghostty`, with Ghostty's shell integration, when the
  /// bootstrap has put its terminfo and integration at `resources` (#239), and `xterm-256color`
  /// without the integration when it has not: a host rarely has `xterm-ghostty` terminfo of its
  /// own, and a `TERM` the host cannot look up is worse than a plainer one. The fallback also
  /// drops any integration variables the host's own login environment set, and keeps its
  /// `TERMINFO`, which is the user's. Decided on the host as
  /// the attach starts, since the set may be gone (a reboot empties a tmpfs `/run`) or not there
  /// yet. The integration's features are Ghostty's defaults less `path`, which needs the `ghostty`
  /// binary on the host, plus `sudo`: `sudo` keeps `TERM` and drops `TERMINFO`, so without the
  /// integration's wrapper (`sudo --preserve-env=TERMINFO`) a `sudo vim` on the host could not
  /// look up `xterm-ghostty`. It covers `sudo` to root; `sudo -u` another user cannot read the
  /// set in the ssh user's 0700 directory, and `su -` is not wrapped. The title then follows the
  /// shell; the pane's working directory does not, because libghostty takes an OSC 7 report only
  /// from its own host.
  ///
  /// A host with no agent installed yet (rebooted from tmpfs, or never bootstrapped) has no
  /// binary to run, and the shell's 127 for that would read as the session's own exit. It exits
  /// 255 instead, ssh's own status for a lost link, which the app answers by attaching again with
  /// backoff: by then the bootstrap, which nothing orders panes after, has installed it.
  /// `metadata`'s workroom and title go in under the same variables a local pane's attach gets
  /// (`SessionMetadataKey.environmentVariables`), which the host's agent keeps (#255). Nothing
  /// else does: the project is this Mac's path, which the host neither keeps nor needs, and an ssh
  /// command line is visible to everything on the host.
  static func remoteAttachCommand(
    binary: String, session: UUID, socket: String, resources: String, workingDirectory: String,
    restored: Bool, metadata: [(key: String, value: String)] = []
  ) -> String {
    let integrated = [
      "TERM=xterm-ghostty", "TERMINFO=\(resources)/terminfo",
      "WORKROOM_SESSION_RESOURCES=\(resources)", "GHOSTTY_SHELL_FEATURES=cursor,sudo,title",
    ]
    let names = Dictionary(uniqueKeysWithValues: SessionMetadataKey.environmentVariables)
      .filter { [SessionMetadataKey.workroom, SessionMetadataKey.title].contains($0.key) }
    let variables =
      [
        "WORKROOM_SESSION_ID=\(session.uuidString)",
        "WORKROOM_SESSION_SOCKET=\(socket)",
        "WORKROOM_SESSION_CWD=\(workingDirectory)",
      ]
      + metadata.compactMap { entry in
        names[entry.key].flatMap { entry.value.isEmpty ? nil : "\($0)=\(entry.value)" }
      }
    return "test -x \(shellQuoted(binary)) || { echo "
      + shellQuoted("workroom: no agent is installed at \(binary) yet") + " >&2; exit 255; }; "
      + "if test -r \(shellQuoted(resources + "/terminfo/x/xterm-ghostty")); then set -- "
      + integrated.map(shellQuoted).joined(separator: " ")
      + "; else unset WORKROOM_SESSION_RESOURCES GHOSTTY_SHELL_FEATURES; "
      + "set -- 'TERM=xterm-256color'; fi; 'env' \"$@\" "
      + (variables + [binary, "attach", "--no-spawn"] + (restored ? ["--no-create"] : []))
      .map(shellQuoted).joined(separator: " ")
  }

  static let alias = "workroom-host"

  /// The command ssh runs on the host, quoted for the remote shell. The installed binary by its
  /// path: a host has no `wr-agent` on its PATH, only what the bootstrap put beside the socket.
  static func relayCommand(binary: String, socket: String) -> String {
    shellQuoted(binary) + " relay --socket " + shellQuoted(socket)
  }

  /// Writes the host's `ssh_config` and `known_hosts`, and returns the config's path.
  ///
  /// The whole policy is here, so nothing in `~/.ssh/config` can change it:
  /// - **It cannot prompt.** `BatchMode` turns a password, passphrase or unknown-host prompt into a
  ///   failure, and `StrictHostKeyChecking` with only the pinned key known makes any other key one
  ///   of those failures. `HostKeyAlgorithms` is deliberately not pinned to the key's type: it
  ///   names signature algorithms, so for an RSA key it would pin SHA-1 `ssh-rsa`, which OpenSSH
  ///   8.8+ servers no longer offer.
  /// - **No Mac credential crosses.** No agent forwarding, no X11, no port forwards, and the Mac's
  ///   ssh agent is not consulted for keys.
  /// - **What a pane types is only ever the user's.** A pane's ssh has a terminal, and ssh reads
  ///   `~.` and friends from one as its own commands (`~.` disconnects, `~^Z` suspends ssh and
  ///   freezes the pane), so `EscapeChar none`.
  /// - **A dead link is noticed.** `ServerAliveInterval` ends ssh after about 45s of silence from a
  ///   host that stopped answering, which ends the stream and so the connection. It is what bounds
  ///   a link that dies with nothing to send (#228).
  static func writeConfiguration(for host: Host, in directory: URL) throws -> URL {
    for (name, value) in [
      ("address", host.address), ("user", host.user), ("identity file", host.identityFile),
      ("host key", host.hostKey), ("agent socket", host.agentSocket),
    ] {
      guard !value.isEmpty, !value.contains(where: { $0.isNewline || $0 == "\"" || $0 == "\0" })
      else {
        throw HostDriverError.invalidConfiguration("\(name) is empty or has a quote or newline")
      }
    }
    guard (1...65535).contains(host.port) else {
      throw HostDriverError.invalidConfiguration("port \(host.port) is out of range")
    }
    // The agent's binary is derived from it (`agentBinary`), and run by path from any cwd.
    guard host.agentSocket.hasPrefix("/") else {
      throw HostDriverError.invalidConfiguration("agent socket must be an absolute path")
    }
    let key = host.hostKey.split(separator: " ")
    guard key.count >= 2 else {
      throw HostDriverError.invalidConfiguration("host key must be `<type> <base64>`")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let knownHosts = directory.appendingPathComponent("known_hosts")
    let name = host.port == 22 ? host.address : "[\(host.address)]:\(host.port)"
    try "\(name) \(key[0]) \(key[1])\n".write(to: knownHosts, atomically: true, encoding: .utf8)
    let config = directory.appendingPathComponent("ssh_config")
    try """
    Host \(alias)
      HostName "\(host.address)"
      Port \(host.port)
      User "\(host.user)"
      IdentityFile "\(host.identityFile)"
      IdentitiesOnly yes
      IdentityAgent none
      BatchMode yes
      StrictHostKeyChecking yes
      UserKnownHostsFile "\(knownHosts.path)"
      GlobalKnownHostsFile /dev/null
      UpdateHostKeys no
      ForwardAgent no
      ForwardX11 no
      ClearAllForwardings yes
      ControlMaster no
      ControlPath none
      EscapeChar none
      RequestTTY no
      ServerAliveInterval 15
      ServerAliveCountMax 3
      ConnectTimeout 10
      LogLevel ERROR

    """.write(to: config, atomically: true, encoding: .utf8)
    return config
  }

  /// One POSIX shell word, whatever `text` holds.
  static func shellQuoted(_ text: String) -> String { PosixShell.quoted(text) }
}
