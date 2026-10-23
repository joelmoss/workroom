import DaemonConnection
import Foundation
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import WorkroomWire

/// The first `HostDriver`: a Linux container running sshd and a supervised `workroomd`
/// (`vcs/scripts/ssh-fixture`, #228), reached over plain ssh-stdio. It is the test fixture for
/// the remote path, and its ssh transport (`exec`, `attachCommand`) is the one a real
/// ssh-reachable driver shares (`BoxdHostDriver`, #256).
///
/// Its hosts are the ones the caller hands in, plus, given `Provisioning`, the containers it makes
/// itself (#252): `create` runs a workroom's host from the fixture's image, and `destroy` removes
/// it. Nothing here persists.
public final class ContainerHostDriver: HostTerminalDriver, @unchecked Sendable {
  /// How the driver makes containers of its own: a container runtime's CLI (`docker`), the
  /// fixture's image, and the client key every container authorises. Containers are reached on a
  /// loopback port the runtime publishes, as `vcs/scripts/ssh-fixture/run.sh` reaches its own.
  public struct Provisioning: Sendable {
    public let runtime: URL
    public let image: String
    public let user: String
    public let identityFile: String
    /// The public half of `identityFile`, which the entrypoint writes to `authorized_keys`.
    public let publicKey: String
    public let daemonSocket: String
    /// `key=value` labels on every container and image made, so whoever started the fixture can
    /// sweep up what a crashed test left (run.sh does).
    public let labels: [String]
    /// The Docker context every command names (`--context`, #309), or nil for whichever daemon
    /// the environment and the CLI's current context pick. Docker Desktop, OrbStack and Colima
    /// are each a context behind the one `docker`, so without it a host made on one is looked for
    /// on whichever the user switched to since.
    public var context: String?
    /// Which runtime's CLI `runtime` is: Docker's, or Apple's `container` (#309).
    public var dialect: Dialect
    /// CPUs and memory (`4G`) each container gets, or nil for the runtime's own default. Apple's is
    /// 1 GB per container VM, too little for a compiler or a daemon; Docker's containers share its
    /// VM's.
    public var cpus: Int?
    public var memory: String?

    public init(
      runtime: URL, image: String, user: String, identityFile: String, publicKey: String,
      daemonSocket: String, labels: [String], context: String? = nil, dialect: Dialect = .docker,
      cpus: Int? = nil, memory: String? = nil
    ) {
      self.runtime = runtime
      self.image = image
      self.user = user
      self.identityFile = identityFile
      self.publicKey = publicKey
      self.daemonSocket = daemonSocket
      self.labels = labels
      self.context = context
      self.dialect = dialect
      self.cpus = cpus
      self.memory = memory
    }
  }

  /// The two container CLIs a driver can speak (#309). Apple's `container` (1.5.0) runs each
  /// container in a VM of its own and has no `--restart`, no `--filter` and no Go templates
  /// (`AppleContainerCLI`).
  public enum Dialect: Sendable {
    case docker
    case apple
  }

  /// A host this driver made: its container, and for one an older build derived from a base, the
  /// image it was run from, which only it uses.
  private struct Provisioned {
    let container: String
    let image: String?
  }

  /// The label every container and image this driver makes carries, with when it was made in
  /// seconds since 1970, so `sweep` can leave one that may still be part of a create.
  public static let createdLabel = "workroom.created"

  /// Where each host's `ssh_config` and `known_hosts` are written.
  public let directory: URL
  public let provisioning: Provisioning?
  private let lock = NSLock()
  private var hosts: [UUID: SSHTransport.Host]
  private var provisioned: [UUID: Provisioned] = [:]
  /// Hosts this driver has destroyed, so destroying one again succeeds: a caller retrying after a
  /// later step of its own failed (forgetting its record) gets past the destroy it already did.
  private var destroyed: Set<UUID> = []

  public init(hosts: [UUID: SSHTransport.Host], directory: URL, provisioning: Provisioning? = nil) {
    self.hosts = hosts
    self.directory = directory
    self.provisioning = provisioning
  }

  private func target(_ host: HostID) throws -> (UUID, SSHTransport.Host) {
    guard case .remote(let id) = host, let target = lock.withLock({ hosts[id] }) else {
      throw HostDriverError.unknownHost(host)
    }
    return (id, target)
  }

  public func create() async throws -> HostID {
    guard let provisioning else { throw HostDriverError.notImplemented("Creating a host") }
    // The app announces the image step itself, around `ensureHostImage`: only its log here.
    try await ProvisioningProgress.step(.image, report: false) {
      try await ensureImage(provisioning.image)
    }
    return try await ProvisioningProgress.step(.machine) { try await run(provisioning.image) }
  }

  /// Pulls the host image unless this runtime has it. A create calls it before it names its
  /// workroom, so a download's progress (`pullProgress`) shows on the project's row, which is the
  /// one that shows it; `create` then finds the image there.
  public func ensureHostImage() async throws {
    guard let provisioning else { throw HostDriverError.notImplemented("Creating a host") }
    try await ProvisioningProgress.step(.image) { try await ensureImage(provisioning.image) }
  }

  /// Told how far a host image's pull has got, 0 to 1, then nil once it is done, for a create run
  /// inside `$pullProgress.withValue` (#309): a task-local, so `HostDriver.create` keeps its shape
  /// and two creates at once each hear only their own.
  @TaskLocal public static var pullProgress: (@Sendable (Double?) -> Void)?

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
      var onOutput: (@Sendable (Data, Bool) -> Void)?
      if let report {
        onOutput = { @Sendable data, stderr in
          if let fraction = progress.read(data, stderr: stderr) { report(fraction) }
        }
      }
      _ = try await runtime(
        apple ? ["image", "pull", "--arch", "arm64", image] : ["pull", image], timeout: 900,
        onOutput: onOutput)
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
  public static func runtimeDown(_ said: String, apple: Bool) -> Error? {
    if apple {
      guard said.contains("container system start") || said.contains("XPC connection") else {
        return nil
      }
      return HostDriverError.provisioning(
        "Apple's container runtime isn't running. Run `container system start`, then try again.")
    }
    // "Cannot connect to…", and a socket the user can't open ("permission denied while trying to
    // connect to the Docker daemon socket"), which the registry check would read as a refusal.
    // Docker 29 says "the docker API" for both ("failed to connect to the docker API at…").
    let lowered = said.lowercased()
    guard
      [
        "connect to the docker daemon", "connect to the docker api", "error during connect",
        "unable to resolve docker",
      ]
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
  public static let deriveDirectoryPrefix = "workroom-derive-"

  /// Removes the container and the image it alone was run from. A host handed in rather than
  /// made here is not this driver's to remove.
  public func destroy(_ host: HostID) async throws {
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
  public func startIfStopped(_ host: HostID) async throws {
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
  public func record(of host: HostID) -> ContainerHostRecord? {
    guard case .remote(let id) = host else { return nil }
    return lock.withLock {
      guard let target = hosts[id], let made = provisioned[id] else { return nil }
      return ContainerHostRecord(
        address: target.address, port: target.port, user: target.user, hostKey: target.hostKey,
        image: made.image, context: provisioning?.context)
    }
  }

  /// Takes a host an earlier launch made back on (#253), as its `record` describes it, so it can
  /// be reached and destroyed as if this driver had made it. Whether its container is still there
  /// is found out by using it.
  public func adopt(_ id: UUID, _ record: ContainerHostRecord) throws {
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
      hosts[id] = SSHTransport.Host(
        address: record.address, port: record.port, user: record.user,
        identityFile: provisioning.identityFile, hostKey: record.hostKey,
        daemonSocket: provisioning.daemonSocket)
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
  public func sweep(
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
  public var pendingContainers: Set<String> {
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
  public func forgetPending(_ names: [String]) {
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
  public static func pending(in directory: URL) -> [(dialect: Dialect, context: String?)] {
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
  public static let listingFailed = "listing containers: "

  public static func containerName(_ id: UUID) -> String {
    "workroom-\(id.uuidString.lowercased())"
  }

  private static func created() -> String {
    "\(createdLabel)=\(Int(Date().timeIntervalSince1970))"
  }

  /// `sha256:<64 hex>`, as `commit` prints it.
  public static func isImageID(_ text: String) -> Bool {
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
        hosts[id] = SSHTransport.Host(
          address: "127.0.0.1", port: Int(port), user: provisioning.user,
          identityFile: provisioning.identityFile, hostKey: hostKey,
          daemonSocket: provisioning.daemonSocket)
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
      if let key = try? await runtime(["exec", container, "identity.sh"], quiet: true),
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
    onOutput: (@Sendable (Data, _ stderr: Bool) -> Void)? = nil, quiet: Bool = false
  ) async throws -> String {
    guard let provisioning else { throw HostDriverError.notImplemented("Provisioning") }
    // `quiet` is for a poll, which would log the same line a hundred times. The environment is never
    // logged, and `commandLine` hides the one the arguments carry (`--env AUTHORIZED_KEY=…`).
    let full = Self.runtimeArguments(arguments, context: provisioning.context)
    let environment = ProcessInfo.processInfo.environment.filter {
      ["HOME", "PATH", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG"].contains($0.key)
    }
    // A pull streams progress bars (`onOutput`); its failure says what it printed.
    let logOutput: (Int32) -> Bool = { onOutput == nil || $0 != 0 }
    let (status, said) = try await ProvisioningProgress.logged(
      quiet ? nil : ProvisioningProgress.commandLine(provisioning.runtime.path, full),
      logOutput: logOutput
    ) {
      let (status, output) = try await HostStream.spawn(
        provisioning.runtime, full, environment: environment, handshakeTimeout: 20,
        purpose: .exchange
      ).communicate(nil, timeout: timeout, onOutput: onOutput)
      return (status, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
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
  public static func runtimeArguments(_ arguments: [String], context: String?) -> [String] {
    guard let context else { return arguments }
    return ["--context", context] + arguments
  }

  /// The Docker context the CLI would use now, to pin a new host to (#309), or nil for `default`:
  /// that one is whatever `DOCKER_HOST` says, so naming it pins nothing. Asks a driver whose own
  /// context is nil, so the answer is the environment's and the CLI's.
  public func currentContext() async throws -> String? {
    let name = try await runtime(["context", "show"])
    return name.isEmpty || name == "default" ? nil : name
  }

  public func openStream(to host: HostID) async throws -> HostStream {
    let (id, target) = try target(host)
    return try SSHTransport.exec(
      SSHTransport.relayCommand(binary: target.daemonBinary, socket: target.daemonSocket),
      on: target,
      in: directory.appendingPathComponent(id.uuidString), purpose: .connection)
  }

  public func exec(_ command: String, on host: HostID) async throws -> HostStream {
    let (id, target) = try target(host)
    return try SSHTransport.exec(
      command, on: target, in: directory.appendingPathComponent(id.uuidString),
      purpose: .exchange)
  }

  public func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)], runCommand: String?
  ) throws -> String {
    let (id, target) = try target(host)
    return try SSHTransport.attachCommand(
      to: target, in: directory.appendingPathComponent(id.uuidString), session: session,
      workingDirectory: workingDirectory, restored: restored, metadata: metadata,
      runCommand: runCommand)
  }

  /// Whether the last attach of `session` was refused by `host` in a way that does not heal: a
  /// changed host key, a key it will not take, nothing to agree a cipher on (#241). Everything
  /// else is worth trying again: a host that is booting refuses, times out, or accepts and closes
  /// before its banner, and some of those leave ssh nothing to say at `LogLevel ERROR`.
  public func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    return SSHTransport.refusedLastAttach(
      of: session, in: directory.appendingPathComponent(id.uuidString))
  }

  public func lastAttach(of session: UUID, on host: HostID) -> LastAttach {
    guard case .remote(let id) = host else { return .finished }
    return SSHTransport.lastAttach(
      of: session, in: directory.appendingPathComponent(id.uuidString))
  }
}
