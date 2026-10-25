import DaemonConnection
import Foundation
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import WorkroomWire

/// The first `HostDriver`. Its hosts are the ones the caller hands in over ssh (the ssh fixture,
/// `vcs/scripts/ssh-fixture`, #228, whose ssh transport, `exec` and `attachCommand`, a real
/// ssh-reachable driver shares: `BoxdHostDriver`, #256), plus, given `Provisioning`, the containers
/// it makes itself: `create` runs a workroom's container from any image with the bundled
/// `workroomd` as its entrypoint, reached through the runtime's own `exec` (#308), and `destroy`
/// removes it. Nothing here persists.
public final class ContainerHostDriver: HostTerminalDriver, ProvisioningHostDriver,
  DaemonPlacingDriver,
  @unchecked Sendable
{
  /// How the driver makes containers of its own: a container runtime's CLI (`docker`, or Apple's
  /// `container`), the image a container without a devcontainer.json is made from, and the labels
  /// that mark what it made.
  public struct Provisioning: Sendable {
    public let runtime: URL
    public let image: String
    public let user: String
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
    /// The bundled Linux daemon for an architecture (`aarch64`, `x86_64`): a container's
    /// entrypoint (#308).
    public var daemon: (@Sendable (String) -> URL?)?
    /// The folder on this Mac Apple's containers mount the daemon from (Apple can't copy into a
    /// container before it starts).
    public var daemonFolder: URL?

    public init(
      runtime: URL, image: String, user: String,
      daemonSocket: String, labels: [String], context: String? = nil, dialect: Dialect = .docker,
      cpus: Int? = nil, memory: String? = nil, daemon: (@Sendable (String) -> URL?)? = nil,
      daemonFolder: URL? = nil
    ) {
      self.daemon = daemon
      self.daemonFolder = daemonFolder
      self.runtime = runtime
      self.image = image
      self.user = user
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
    var volumes: [String] = []
  }

  /// The label every container and image this driver makes carries, with when it was made in
  /// seconds since 1970, so `sweep` can leave one that may still be part of a create.
  public static let createdLabel = "workroom.created"
  /// The label naming a container's owned volumes (`ContainerSpec.ownedVolumes`), comma-separated,
  /// which a sweep removes after it.
  static let volumesLabel = "workroom.volumes"

  /// How a host is reached: one handed in over ssh (the ssh fixture, and the path boxd and exe.dev
  /// share, which its tests run through this driver), or a container this driver made, through its
  /// runtime's `exec` (#308), as `user`, its daemon on `socket`. `older` is a container made before
  /// #308, reached over ssh, as its record says: it can be destroyed, and reaching it throws
  /// `olderContainer`.
  private enum Reach {
    case ssh(SSHTransport.Host)
    case exec(user: String, socket: String)
    case older(ContainerHostRecord)
  }

  /// What a container is made from (#308): the image, run as `user`, with the container settings a
  /// devcontainer.json and its features ask for, resolved by the create.
  public struct ContainerSpec: Sendable {
    public var image: String
    /// The remote user; nil for the image's own, else root.
    public var user: String?
    public var environment: [String: String]
    public var mounts: [Mount]
    /// Docker's run flags, as written; Apple's runtime takes none of them.
    public var runArgs: [String]
    public var privileged: Bool
    public var capAdd: [String]
    public var securityOpt: [String]
    /// Made by the daemon, as root, for the remote user, before anything runs: the clone's parent.
    public var workspaceFolder: String?
    /// The named volumes of `mounts` made for this container alone, which `destroy` removes after
    /// it (`ContainerHostRecord.volumes`).
    public var ownedVolumes: [String]

    public init(
      image: String, user: String? = nil, environment: [String: String] = [:],
      mounts: [Mount] = [], runArgs: [String] = [], privileged: Bool = false,
      capAdd: [String] = [], securityOpt: [String] = [], workspaceFolder: String? = nil,
      ownedVolumes: [String] = []
    ) {
      self.ownedVolumes = ownedVolumes
      self.image = image
      self.user = user
      self.environment = environment
      self.mounts = mounts
      self.runArgs = runArgs
      self.privileged = privileged
      self.capAdd = capAdd
      self.securityOpt = securityOpt
      self.workspaceFolder = workspaceFolder
    }
  }

  /// A mount, as both runtimes' `--mount` take it.
  public struct Mount: Sendable, Equatable {
    public var type: String
    public var source: String?
    public var target: String
    public var readOnly: Bool

    public init(type: String, source: String?, target: String, readOnly: Bool = false) {
      self.type = type
      self.source = source
      self.target = target
      self.readOnly = readOnly
    }

    /// `type=…,source=…,target=…[,readonly]`.
    var flag: String {
      (["type=\(type)"] + (source.map { ["source=\($0)"] } ?? []) + ["target=\(target)"]
        + (readOnly ? ["readonly"] : [])).joined(separator: ",")
    }
  }

  /// Where each host's `ssh_config` and `known_hosts`, and each pane's attach log, are written.
  public let directory: URL
  public let provisioning: Provisioning?
  private let lock = NSLock()
  private var hosts: [UUID: Reach]
  private var provisioned: [UUID: Provisioned] = [:]
  /// Hosts this driver has destroyed, so destroying one again succeeds: a caller retrying after a
  /// later step of its own failed (forgetting its record) gets past the destroy it already did.
  private var destroyed: Set<UUID> = []

  public init(hosts: [UUID: SSHTransport.Host], directory: URL, provisioning: Provisioning? = nil) {
    self.hosts = hosts.mapValues { .ssh($0) }
    self.directory = directory
    self.provisioning = provisioning
  }

  private func reach(_ host: HostID) throws -> (UUID, Reach) {
    guard case .remote(let id) = host, let reach = lock.withLock({ hosts[id] }) else {
      throw HostDriverError.unknownHost(host)
    }
    if case .older = reach { throw HostDriverError.olderContainer }
    return (id, reach)
  }

  /// How `exec` reaches `host`, a container this driver made.
  private func execTarget(_ host: HostID) throws -> ContainerExecTransport.Target {
    guard let provisioning, case .remote(let id) = host,
      let (reach, made) = lock.withLock({
        hosts[id].flatMap { r in provisioned[id].map { (r, $0) } }
      }),
      case .exec(let user, let socket) = reach
    else { throw HostDriverError.unknownHost(host) }
    return ContainerExecTransport.Target(
      runtime: provisioning.runtime, dialect: provisioning.dialect, context: provisioning.context,
      container: made.container, user: user, daemonSocket: socket,
      daemonBinary: Self.containerDaemon)
  }

  /// Whether `host` is a container reached through its runtime (rather than a host handed in over
  /// ssh): the bootstrap places its daemon itself (#308).
  public func isContainer(_ host: HostID) -> Bool {
    guard case .remote(let id) = host, case .exec = lock.withLock({ hosts[id] }) else {
      return false
    }
    return true
  }

  /// A container from the provisioned image, as the provisioned user, else the image's own: a
  /// create with no spec to say otherwise. The app makes its containers from a spec
  /// (`create(spec:)`); this is the generic `HostDriver` create the provisioning tests use.
  public func create() async throws -> HostID {
    guard let provisioning else { throw HostDriverError.notImplemented("Creating a host") }
    return try await create(
      spec: ContainerSpec(
        image: provisioning.image, user: provisioning.user.isEmpty ? nil : provisioning.user))
  }

  /// A container made from `spec` (#308), its image pulled first when this runtime hasn't it.
  public func create(spec: ContainerSpec) async throws -> HostID {
    // The app pulls and builds before it names the workroom (`ContainerCreate.prepare`), so a
    // download's progress shows on its own row; this finds the image there, and only logs.
    try await ProvisioningProgress.step(.image, report: false) {
      try await ensureImage(spec.image)
    }
    return try await ProvisioningProgress.step(.machine) { try await run(spec) }
  }

  /// Told how far a host image's pull has got, 0 to 1, then nil once it is done, for a create run
  /// inside `$pullProgress.withValue` (#309): a task-local, so `HostDriver.create` keeps its shape
  /// and two creates at once each hear only their own.
  @TaskLocal public static var pullProgress: (@Sendable (Double?) -> Void)?

  /// Pulls `image` unless the runtime already has it (#309). `create` itself never pulls
  /// (`--pull=never`): left to it, a missing local image was looked for on Docker Hub as
  /// `library/<name>`, and failed with a registry error that said nothing about why.
  public func ensureImage(_ image: String) async throws {
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
          "the registry refused the image \(image): it isn't public, you aren't logged in to "
            + "its registry, or it doesn't exist. (\(said))")
      }
      throw HostDriverError.provisioning(
        "couldn't download the image \(image). Check your network connection, then try again. "
          + "(\(said))")
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
    try await removeContainer(made.container)
    try await removeVolumes(made.volumes)
    if provisioning?.dialect != .apple, let image = made.image {
      _ = try await runtime(["rmi", "--force", image])
    }
    lock.withLock {
      hosts[id] = nil
      provisioned[id] = nil
      destroyed.insert(id)
    }
    forgetPending([made.container])
    try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
  }

  /// Runs `host`'s postStartCommand when the container has one that hasn't run since it started
  /// (#308, eng review D12): after a Docker restart, a Mac restart or start-on-open, its first
  /// connect does. Panes wait for it (`postStartWait`). Nil when there was nothing to run; else how
  /// it ended and what it printed. It is marked done whatever its status, so a failing one never
  /// holds panes back; a second connect at the same time finds it under way and leaves it.
  public func runPostStartIfNeeded(on host: HostID) async throws -> (status: Int32, output: String)?
  {
    guard isContainer(host) else { return nil }
    let q = PosixShell.quoted
    let lock = q(Self.postStartDone + ".lock")
    let command = """
      if [ -e \(q(Self.postStartDone)) ] || [ ! -e \(q(Self.postStartHook)) ]; then exit 0; fi
      mkdir \(lock) 2>/dev/null || exit 0
      echo 'WRB ran'
      \(q(Self.containerDaemon)) run-script --dir / --timeout 600 -- \(q(Self.postStartHook))
      status=$?; : > \(q(Self.postStartDone)); rmdir \(lock); exit "$status"
      """
    let (status, output) = try await exec(command, on: host).communicate(nil, timeout: 630)
    guard output.contains("WRB ran") else { return nil }
    return (status, output.replacingOccurrences(of: "WRB ran\n", with: ""))
  }

  /// Starts `host`'s container if it is stopped, and waits until it can be logged in to (#309): a
  /// container someone stopped stays stopped, and a runtime with no restart policy (Apple's) leaves
  /// every one stopped after a reboot. Only for a workroom the user opens (`RemoteHosts.activate`),
  /// never for a background probe, which would start every container the app knows.
  public func startIfStopped(_ host: HostID) async throws {
    _ = try reach(host)
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
    try await awaitDaemon(host)
  }

  /// What a later launch's driver needs to `adopt` `host`, or nil for a host this driver did not
  /// make: the container's user (its name is its id's), its older derive's image, its context.
  public func record(of host: HostID) -> ContainerHostRecord? {
    guard case .remote(let id) = host else { return nil }
    return lock.withLock {
      guard let made = provisioned[id] else { return nil }
      switch hosts[id] {
      case .exec(let user, _):
        return ContainerHostRecord(
          user: user, image: made.image, context: provisioning?.context,
          volumes: made.volumes.isEmpty ? nil : made.volumes)
      case .older(let record): return record
      case .ssh, nil: return nil
      }
    }
  }

  /// Takes a host an earlier launch made back on (#253), as its `record` describes it, so it can
  /// be reached and destroyed as if this driver had made it. Whether its container is still there
  /// is found out by using it. A container made before #308, reached over ssh, is taken on only to
  /// be destroyed: its image's entrypoint is the ssh one, which this build doesn't speak, so
  /// reaching it throws `olderContainer` and its workroom says to make it again.
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
      hosts[id] =
        record.hostKey == nil
        ? .exec(user: record.user, socket: Self.containerSocket) : .older(record)
      provisioned[id] = Provisioned(
        container: Self.containerName(id), image: record.image, volumes: record.volumes ?? [])
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
      var volumes: [String: [String]] = [:]
      for line in try await runtime(
        ["ps", "-a"] + filters + [
          "--format",
          "{{.Names}}\t{{.Label \"\(Self.createdLabel)\"}}\t{{.Label \"\(Self.volumesLabel)\"}}",
        ],
        allLines: true
      ).split(separator: "\n") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        let name = String(fields[0])
        if !keptContainers.contains(name), old(fields.count > 1 ? fields[1] : ""),
          !onlyPending || pending.contains(name)
        {
          unknown.append(name)
          if fields.count > 2 { volumes[name] = fields[2].split(separator: ",").map(String.init) }
        }
      }
      var removed: [String] = []
      for name in confirmedUnknown(unknown, cap: cap, failed: &failed) {
        do {
          _ = try await runtime(["rm", "--force", "--volumes", name])
          removed.append(name)
        } catch {
          failed.append("container \(name): \(error.localizedDescription)")
          continue
        }
        do { try await removeVolumes(volumes[name] ?? []) } catch {
          failed.append("volumes of \(name): \(error.localizedDescription)")
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
          // Docker's refusal for an image in use, by a container or as another image's base (a
          // devcontainer.json's build, #308), is that rule working, not a failure.
          let said = error.localizedDescription
          guard !said.contains("conflict: unable to delete") else { continue }
          failed.append("image \(image): \(said)")
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
      var volumes: [String: [String]] = [:]
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
          volumes[id] = labels[Self.volumesLabel]?.split(separator: ",").map(String.init)
        }
      }
      var removed: [String] = []
      for id in confirmedUnknown(unknown, cap: cap, failed: &failed) {
        do {
          _ = try await runtime(["delete", "--force", id])
          removed.append(id)
        } catch {
          failed.append("container \(id): \(error.localizedDescription)")
          continue
        }
        do { try await removeVolumes(volumes[id] ?? []) } catch {
          failed.append("volumes of \(id): \(error.localizedDescription)")
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

  /// Where a container's daemon is, inside it: the bundled binary, put there before the container
  /// starts (Docker's `cp`, Apple's read-only mount), out of the socket's folder, which a mount
  /// would make read-only.
  public static let daemonFolder = "/.workroom/bin"
  public static var containerDaemon: String { daemonFolder + "/workroomd" }
  /// Where its socket is: the folder the daemon makes, as root, for the remote user.
  public static let containerSocket = DaemonInstall.defaultSocket
  /// Where it keeps each session's screen: in the remote user's home, which survives a restart.
  static let containerScreens = "~/.local/state/workroom/screens"
  /// Where a create writes the devcontainer.json lifecycle commands it runs, one script each, named
  /// by its key (#308): in the socket's folder, the remote user's, which survives a restart.
  public static let hooksFolder = (containerSocket as NSString).deletingLastPathComponent + "/hooks"
  /// The postStartCommand, run again after each start of the container (`runPostStartIfNeeded`).
  public static var postStartHook: String { hooksFolder + "/postStartCommand" }
  /// Written once postStartCommand has run since the container started: `/dev/shm` is a tmpfs made
  /// afresh at each start, on both runtimes (measured on Apple's 1.5.0), and the daemon is the
  /// container's entrypoint, so a new start of one is a new start of the other.
  public static let postStartDone = "/dev/shm/workroom-poststart"

  /// What a pane runs in the container before it attaches, when the container has a
  /// postStartCommand that hasn't run since it started: it waits for it (#308, eng review D12),
  /// up to the 10 minutes a lifecycle command may run.
  static let postStartWait = """
    if [ -e \(postStartHook) ] && [ ! -e \(postStartDone) ]; then \
    printf '%s\\r\\n' 'Waiting for the dev container'"'"'s postStartCommand to finish…'; i=0; \
    while [ ! -e \(postStartDone) ] && [ "$i" -lt 600 ]; do sleep 1; i=$((i + 1)); done; fi
    """

  /// Runs a container from `spec` and waits until its daemon serves the remote user, then checks
  /// the image has what a workroom needs (a shell for panes, git for the clone and the daemon's
  /// VCS service). Its entrypoint is the bundled daemon, started as root to make the socket's and
  /// the workspace's folders for the remote user, which it then becomes (`serve --user`). The
  /// image's own entrypoint and command don't run, as the devcontainers CLI's `overrideCommand`
  /// default. A container that gets no further is removed.
  private func run(_ spec: ContainerSpec) async throws -> HostID {
    guard let provisioning else { throw HostDriverError.notImplemented("Provisioning") }
    let apple = provisioning.dialect == .apple
    let id = UUID()
    // Named here, not by the runtime's own ID, which is known only from its output: a run that
    // outlives its CLI still leaves a container this name removes.
    let container = Self.containerName(id)
    // Before the container exists: a crash from here on leaves its name pending (#284).
    try updatePending { $0.append(container) }
    do {
      let user = try await remoteUser(spec)
      let daemon = try await bundledDaemon(for: spec.image)
      // Docker's `unless-stopped`: a daemon that exits, or a Docker or Mac restart, brings it back.
      // Apple's runtime has no restart policy; opening the workroom starts it (`startIfStopped`).
      // In steps, typed: as one expression, CI's Swift gave up type-checking it.
      var arguments: [String] =
        apple
        ? ["create", "--init", "--arch", "arm64"]
        : ["create", "--pull=never", "--init", "--restart", "unless-stopped"]
      if let cpus = provisioning.cpus { arguments += ["--cpus", String(cpus)] }
      if let memory = provisioning.memory { arguments += ["--memory", memory] }
      arguments += ["--name", container, "--user", "0"]
      for label in provisioning.labels + [Self.created()] { arguments += ["--label", label] }
      // So a sweep of a container a crash left can take its volumes too (names have no commas).
      if !spec.ownedVolumes.isEmpty {
        arguments += [
          "--label", "\(Self.volumesLabel)=\(spec.ownedVolumes.joined(separator: ","))",
        ]
      }
      for (key, value) in spec.environment.sorted(by: { $0.key < $1.key }) {
        arguments += ["--env", "\(key)=\(value)"]
      }
      for mount in spec.mounts { arguments += ["--mount", mount.flag] }
      arguments += spec.capAdd.flatMap { ["--cap-add", $0] }
      if !apple {
        if spec.privileged { arguments.append("--privileged") }
        arguments += spec.securityOpt.flatMap { ["--security-opt", $0] } + spec.runArgs
      }
      if apple {
        arguments += [
          "--mount",
          "type=bind,source=\(try appleDaemonFolder(holding: daemon).path),"
            + "target=\(Self.daemonFolder),readonly",
        ]
      }
      arguments +=
        ["--entrypoint", Self.containerDaemon, spec.image]
        + Self.serveArguments(
          user: user, workspaceFolder: spec.workspaceFolder)
      _ = try await runtime(arguments)
      if !apple { try await copyDaemon(daemon, into: container) }
      _ = try await runtime(["start", container])
      lock.withLock {
        hosts[id] = .exec(user: user, socket: Self.containerSocket)
        provisioned[id] = Provisioned(container: container, image: nil, volumes: spec.ownedVolumes)
      }
      try await awaitDaemon(.remote(id))
      try await checkImage(.remote(id), user: user)
      return .remote(id)
    } catch {
      lock.withLock {
        hosts[id] = nil
        provisioned[id] = nil
      }
      let removal = await Task { () -> String? in
        do {
          try await self.removeContainer(container)
          try await self.removeVolumes(spec.ownedVolumes)
          return nil
        } catch { return "container \(container): \(error.localizedDescription)" }
      }.value
      if removal == nil { forgetPending([container]) }
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
      guard let removal else { throw error }
      throw HostDriverError.leftBehind(cause: error.localizedDescription, leftover: [removal])
    }
  }

  /// Removes `container`, and its anonymous volumes on Docker. One already gone is removed: a
  /// create whose `create` failed made none, and Apple's `delete --force` says "not found" where
  /// Docker's `rm --force` says nothing (Apple's 1.5.0, measured).
  private func removeContainer(_ container: String) async throws {
    let apple = provisioning?.dialect == .apple
    do {
      _ = try await runtime(
        apple ? ["delete", "--force", container] : ["rm", "--force", "--volumes", container])
    } catch {
      let said = error.localizedDescription.lowercased()
      guard ["not found", "notfound", "no such container"].contains(where: said.contains) else {
        throw error
      }
    }
  }

  /// The named volumes a container's own mounts made (`ContainerSpec.ownedVolumes`), after the
  /// container: a volume in use can't be removed. One already gone counts as removed.
  private func removeVolumes(_ volumes: [String]) async throws {
    guard !volumes.isEmpty else { return }
    do {
      _ = try await runtime(["volume", "rm"] + volumes)
    } catch {
      let said = error.localizedDescription.lowercased()
      guard ["not found", "notfound", "no such volume"].contains(where: said.contains) else {
        throw error
      }
    }
  }

  /// The daemon's arguments as a container's entrypoint (`serve --user`).
  static func serveArguments(user: String, workspaceFolder: String?) -> [String] {
    [
      "serve", "--socket", containerSocket, "--idle-timeout", "never", "--screens",
      containerScreens, "--user", user,
    ] + (workspaceFolder.map { ["--own", $0] } ?? [])
  }

  /// The user a container's workroom runs as: the spec's, else the one the image's devcontainer
  /// metadata names, else the image's own, else root (the devcontainers CLI's rule).
  private func remoteUser(_ spec: ContainerSpec) async throws -> String {
    if let user = spec.user, !user.isEmpty { return user }
    let image = try await imageConfig(spec.image)
    return image.metadataUser ?? image.user ?? "root"
  }

  /// What an image says about how it runs (#308).
  public struct ImageConfig: Equatable, Sendable {
    /// Its config's `User`; nil for root.
    public var user: String?
    /// The user its `devcontainer.metadata` label names: the last `remoteUser`, else the last
    /// `containerUser` (the devcontainers images run as root and name `vscode` there).
    public var metadataUser: String?
    /// Its config's `Env`, which `${containerEnv:…}` reads.
    public var environment: [String: String]

    public init(user: String?, metadataUser: String?, environment: [String: String]) {
      self.user = user
      self.metadataUser = metadataUser
      self.environment = environment
    }
  }

  public func imageConfig(_ image: String) async throws -> ImageConfig {
    let user: String?
    let labels: [String: String]
    let environment: [String]
    if provisioning?.dialect == .apple {
      let images = try AppleContainerCLI.objects(
        try await runtime(["image", "inspect", image], allLines: true))
      let first = images.first ?? [:]
      user = AppleContainerCLI.user(ofImage: first)
      labels = AppleContainerCLI.labels(ofImage: first)
      environment = AppleContainerCLI.environment(ofImage: first)
    } else {
      let said = try await runtime(
        ["image", "inspect", "--format", "{{json .Config}}", image], allLines: true)
      let config =
        (try? JSONSerialization.jsonObject(with: Data(said.utf8))) as? [String: Any] ?? [:]
      user = config["User"] as? String
      labels = config["Labels"] as? [String: String] ?? [:]
      environment = config["Env"] as? [String] ?? []
    }
    return ImageConfig(
      user: user.flatMap { $0.isEmpty ? nil : $0 },
      metadataUser: Self.metadataUser(labels["devcontainer.metadata"]),
      environment: environment.reduce(into: [:]) { result, pair in
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { result[parts[0]] = parts[1] }
      })
  }

  /// The user a `devcontainer.metadata` label names: a JSON list of objects, or one object.
  static func metadataUser(_ label: String?) -> String? {
    guard let data = label?.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data)
    else { return nil }
    let entries = parsed as? [[String: Any]] ?? (parsed as? [String: Any]).map { [$0] } ?? []
    func last(_ key: String) -> String? {
      entries.reversed().lazy.compactMap { $0[key] as? String }.first { !$0.isEmpty }
    }
    return last("remoteUser") ?? last("containerUser")
  }

  /// Builds `dockerfile` in `context` into `tag` (#308): a devcontainer.json's `build`, or its
  /// features on top of an image. Labelled as this build's, so the sweep removes it once no
  /// container uses it. Its output goes to the create's log as it comes.
  public func build(
    dockerfile: URL, context: URL, tag: String, arguments: [String: String] = [:],
    target: String? = nil, options: [String] = []
  ) async throws {
    guard let provisioning else { throw HostDriverError.notImplemented("Building an image") }
    let apple = provisioning.dialect == .apple
    var command = ["build", "--file", dockerfile.path, "--tag", tag]
    for label in provisioning.labels + [Self.created()] { command += ["--label", label] }
    for (key, value) in arguments.sorted(by: { $0.key < $1.key }) {
      command += ["--build-arg", "\(key)=\(value)"]
    }
    if let target { command += ["--target", target] }
    // Apple's builds arm64 only, as it runs; its `build` takes none of Docker's other options.
    command +=
      apple ? ["--arch", "arm64", "--progress", "plain"] : ["--progress", "plain"] + options
    command.append(context.path)
    let lines = LineLog(ProvisioningProgress.log, step: ProvisioningProgress.current)
    defer { lines.finish() }
    // Silence-bounded: a build that prints nothing for 15 minutes is stuck, however long it runs.
    _ = try await runtime(command, timeout: 900, onOutput: { data, _ in lines.add(data) })
  }

  /// A command's output, line by line, into the create's log under the step it began in: the
  /// output arrives on another thread, where the step's task-local isn't set.
  private final class LineLog: @unchecked Sendable {
    private let log: (@Sendable (ProvisioningProgress.Step, String) -> Void)?
    private let step: ProvisioningProgress.Step?
    private let lock = NSLock()
    private var pending = Data()

    init(
      _ log: (@Sendable (ProvisioningProgress.Step, String) -> Void)?,
      step: ProvisioningProgress.Step?
    ) {
      self.log = log
      self.step = step
    }

    func add(_ data: Data) {
      let lines: [String] = lock.withLock {
        pending.append(data)
        var complete: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
          complete.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
          pending = Data(pending[pending.index(after: newline)...])
        }
        return complete
      }
      guard let log, let step else { return }
      for line in lines where !line.isEmpty { log(step, line) }
    }

    func finish() {
      let rest = lock.withLock { () -> String in
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
      }
      if let log, let step, !rest.isEmpty { log(step, rest) }
    }
  }

  /// The bundled daemon for the image's architecture.
  private func bundledDaemon(for image: String) async throws -> URL {
    guard let provisioning, let daemon = provisioning.daemon else {
      throw HostDriverError.notImplemented("A container's daemon")
    }
    let architecture: String
    if provisioning.dialect == .apple {
      architecture = "aarch64"  // Apple's runtime runs arm64 images only (`--arch arm64`).
    } else {
      let said = try await runtime(["image", "inspect", "--format", "{{.Architecture}}", image])
      architecture = ["arm64": "aarch64", "amd64": "x86_64"][said] ?? said
    }
    guard let binary = daemon(architecture) else {
      throw HostDriverError.provisioning(
        "the image \(image) is for \(architecture), and this build has no daemon for it")
    }
    return binary
  }

  /// Docker: the daemon into the container, named `name` in the daemon's folder, as a tar the
  /// runtime unpacks at `/` (`cp -` makes the folders). A create copies it before the container
  /// starts; a later build stages it beside the running one (`placeDaemon`).
  private func copyDaemon(
    _ binary: URL, into container: String, as name: String = "workroomd"
  ) async throws {
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workroom-daemon-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let folder = staging.appendingPathComponent(String(Self.daemonFolder.dropFirst()))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent(name)
    try FileManager.default.copyItem(at: binary, to: copy)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
    let tar = staging.appendingPathComponent("daemon.tar")
    let archive = Process()
    archive.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    // Root's, and no macOS extended attributes, which Docker can't set inside a container.
    archive.arguments = [
      "--no-xattrs", "--no-mac-metadata", "--uid", "0", "--gid", "0", "-cf", tar.path, "-C",
      staging.path, String(Self.daemonFolder.dropFirst().split(separator: "/").first ?? ""),
    ]
    try archive.run()
    archive.waitUntilExit()
    guard archive.terminationStatus == 0 else {
      throw HostDriverError.provisioning("couldn't package the daemon for the container")
    }
    _ = try await runtime(["cp", "-", "\(container):/"], input: tar)
  }

  public func daemonPath(on host: HostID) -> String? {
    isContainer(host) ? Self.containerDaemon : nil
  }

  /// Docker stages the daemon beside the running one, under a name of its own so two connects at
  /// once don't share a file; Apple replaces the one its containers mount, which only takes effect
  /// for a container whose daemon is handed off to it, or that starts again.
  public func placeDaemon(_ binary: URL, on host: HostID) async throws -> (
    path: String, staged: Bool
  ) {
    let target = try execTarget(host)
    if provisioning?.dialect == .apple {
      _ = try appleDaemonFolder(holding: binary)
      return (Self.containerDaemon, false)
    }
    let name = "workroomd.new.\(UUID().uuidString.prefix(8).lowercased())"
    try await copyDaemon(binary, into: target.container, as: name)
    return (Self.daemonFolder + "/" + name, true)
  }

  /// As root: the daemon's folder is root's, so the remote user can't replace the entrypoint.
  public func settleDaemon(_ staged: String, keep: Bool, on host: HostID) async throws {
    let target = try execTarget(host)
    _ = try await runtime(
      ["exec", "-u", "0", target.container]
        + (keep ? ["mv", "-f", staged, Self.containerDaemon] : ["rm", "-f", staged]))
  }

  /// Apple: the folder on this Mac its containers mount the daemon from, holding `binary`'s bytes.
  /// One per build (a container is only ever opened by the build that made it), replaced in place.
  private func appleDaemonFolder(holding binary: URL) throws -> URL {
    guard let folder = provisioning?.daemonFolder else {
      throw HostDriverError.notImplemented("A folder for Apple containers' daemon")
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = folder.appendingPathComponent("workroomd")
    if FileManager.default.contentsEqual(atPath: binary.path, andPath: target.path) {
      return folder
    }
    let staged = folder.appendingPathComponent(".workroomd-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: binary, to: staged)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
    _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
    return folder
  }

  /// Until the container's daemon answers its remote user: it starts a moment after the container.
  /// Run directly, with no shell, so an image without one gets to `checkImage`, which says so.
  private func awaitDaemon(_ host: HostID) async throws {
    let target = try execTarget(host)
    var last = ""
    for _ in 0..<50 {
      do {
        _ = try await runtime(
          [
            "exec", "-u", target.user ?? "root", target.container, target.daemonBinary, "list",
            "--socket", target.daemonSocket,
          ], quiet: true)
        return
      } catch {
        last = error.localizedDescription
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw HostDriverError.provisioning("the container's daemon never started: \(last)")
  }

  /// That the image has a shell for panes (the check itself needs one) and git (the clone and the
  /// daemon's VCS service run it), with what is missing named rather than left to fail later.
  private func checkImage(_ host: HostID, user: String) async throws {
    let (status, said) = try await exec(
      "command -v git >/dev/null 2>&1 || exit 3", on: host
    ).communicate(nil, timeout: 20)
    switch status {
    case 0: return
    case 3:
      throw HostDriverError.provisioning(
        "this image has no git, which Workroom needs inside the container for the checkout. Add it "
          + "to the image, or use a devcontainer.json feature such as "
          + "ghcr.io/devcontainers/features/git.")
    default:
      throw HostDriverError.provisioning(
        "this image has no shell for \(user), which Workroom needs for the workroom's terminals "
          + "(\(said.trimmingCharacters(in: .whitespacesAndNewlines)))")
    }
  }

  /// One runtime command; its first line of output, which is all most of these print on success,
  /// or with `allLines` all of it. Its environment is the few variables that say which daemon to
  /// talk to, never the app's whole one.
  private func runtime(
    _ arguments: [String], timeout: TimeInterval = 120, allLines: Bool = false,
    onOutput: (@Sendable (Data, _ stderr: Bool) -> Void)? = nil, quiet: Bool = false,
    input: URL? = nil
  ) async throws -> String {
    guard let provisioning else { throw HostDriverError.notImplemented("Provisioning") }
    // `quiet` is for a poll, which would log the same line a hundred times. The environment is never
    // logged, and `commandLine` hides any `--env` the arguments carry.
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
      let stream = try HostStream.spawn(
        provisioning.runtime, full, environment: environment, handshakeTimeout: 20,
        purpose: .exchange)
      let (status, output) =
        if let input {
          try await stream.communicate(contentsOf: input, timeout: timeout, onOutput: onOutput)
        } else {
          try await stream.communicate(nil, timeout: timeout, onOutput: onOutput)
        }
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
    let (id, reach) = try reach(host)
    guard case .ssh(let target) = reach else {
      return try ContainerExecTransport.openStream(on: try execTarget(host))
    }
    return try SSHTransport.exec(
      SSHTransport.relayCommand(binary: target.daemonBinary, socket: target.daemonSocket),
      on: target,
      in: directory.appendingPathComponent(id.uuidString), purpose: .connection)
  }

  public func exec(_ command: String, on host: HostID) async throws -> HostStream {
    let (id, reach) = try reach(host)
    guard case .ssh(let target) = reach else {
      return try ContainerExecTransport.exec(command, on: try execTarget(host), purpose: .exchange)
    }
    return try SSHTransport.exec(
      command, on: target, in: directory.appendingPathComponent(id.uuidString),
      purpose: .exchange)
  }

  public func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)], runCommand: String?
  ) throws -> String {
    let (id, reach) = try reach(host)
    let hostDirectory = directory.appendingPathComponent(id.uuidString)
    guard case .ssh(let target) = reach else {
      return ContainerExecTransport.attachCommand(
        on: try execTarget(host), in: hostDirectory, session: session,
        workingDirectory: workingDirectory, restored: restored, metadata: metadata,
        runCommand: runCommand)
    }
    return try SSHTransport.attachCommand(
      to: target, in: hostDirectory, session: session,
      workingDirectory: workingDirectory, restored: restored, metadata: metadata,
      runCommand: runCommand)
  }

  /// Whether the last attach of `session` was refused by `host` in a way that does not heal. Over
  /// ssh: a changed host key, a key it will not take, nothing to agree a cipher on (#241); a host
  /// that is booting refuses, times out, or accepts and closes before its banner, and those are
  /// worth trying again. Through the runtime: a container that is gone.
  public func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host, let reach = lock.withLock({ hosts[id] }) else {
      return false
    }
    let hostDirectory = directory.appendingPathComponent(id.uuidString)
    if case .exec = reach {
      return ContainerExecTransport.refusedLastAttach(of: session, in: hostDirectory)
    }
    return SSHTransport.refusedLastAttach(of: session, in: hostDirectory)
  }

  public func lastAttach(of session: UUID, on host: HostID) -> LastAttach {
    guard case .remote(let id) = host else { return .finished }
    return SSHTransport.lastAttach(
      of: session, in: directory.appendingPathComponent(id.uuidString))
  }
}
