import Foundation
import WorkroomDomain
import WorkroomSystem

/// What a Railway host can be made with (#633), for the host option fields: the checkpoints in
/// this Mac's environment, the only ones a host here can start from (ADR 0071), and the sizes
/// the workspace's plan allows.
public struct RailwayHostOptions: Equatable, Sendable {
  /// The checkpoints' names (`SandboxCheckpoint.key`), as a create's template names them.
  public let checkpoints: [String]
  /// The plan's default and largest size, nil when the plan couldn't be read or isn't one
  /// Workroom knows.
  public let size: Size?

  public init(checkpoints: [String], size: Size?) {
    self.checkpoints = checkpoints
    self.size = size
  }

  /// A plan's sandbox size: what a create with none chosen gets, and the most it may ask. From
  /// Railway's sandbox docs' table (2026-11-13), as no API field says (research section 1).
  public struct Size: Equatable, Sendable {
    public let vcpu: Int
    public let memoryGB: Int
    public let maxVCPU: Int
    public let maxMemoryGB: Int

    public init(vcpu: Int, memoryGB: Int, maxVCPU: Int, maxMemoryGB: Int) {
      self.vcpu = vcpu
      self.memoryGB = memoryGB
      self.maxVCPU = maxVCPU
      self.maxMemoryGB = maxMemoryGB
    }

    /// `plan`'s size, nil for a plan the table doesn't have.
    public init?(plan: RailwayPlan) {
      switch plan {
      case .free: self.init(vcpu: 2, memoryGB: 2, maxVCPU: 2, maxMemoryGB: 2)
      case .hobby: self.init(vcpu: 4, memoryGB: 4, maxVCPU: 8, maxMemoryGB: 8)
      case .pro: self.init(vcpu: 8, memoryGB: 8, maxVCPU: 32, maxMemoryGB: 32)
      case .other: return nil
      }
    }
  }

  /// One of Railway's sandbox regions: its id, which a create sends, and what the fields call it.
  public struct Region: Hashable, Sendable {
    public let id: String
    public let name: String
  }

  /// Railway's four sandbox regions (its docs, 2026-11-13).
  public static let regions = [
    Region(id: "us-west2", name: "US West (California)"),
    Region(id: "us-east4-eqdc4a", name: "US East (Virginia)"),
    Region(id: "europe-west4-drams3a", name: "EU West (Amsterdam)"),
    Region(id: "asia-southeast1-eqsg3a", name: "Southeast Asia (Singapore)"),
  ]

  /// Where a sandbox goes when no region is chosen, whatever the account prefers.
  public static let defaultRegion = "us-west2"

  /// What the fields call region `id`: its name, or the id itself for one Workroom doesn't know.
  public static func regionName(_ id: String) -> String {
    regions.first { $0.id == id }?.name ?? id
  }
}

/// A create's host options as `sandboxCreate` takes them (`SandboxCreateInput` in Railway's
/// TypeScript SDK): nil leaves each to Railway.
public struct RailwaySandboxOptions: Equatable, Sendable {
  public var region: String?
  public var cpu: Double?
  public var memoryGB: Double?
  /// A checkpoint in the environment, by name, as the template the sandbox boots from.
  public var checkpoint: String?

  public init(
    region: String? = nil, cpu: Double? = nil, memoryGB: Double? = nil, checkpoint: String? = nil
  ) {
    self.region = region
    self.cpu = cpu
    self.memoryGB = memoryGB
    self.checkpoint = checkpoint
  }

  /// `options` for Railway: memory is given as `<n>GB`, as the fields save it.
  public init(_ options: ResolvedHostOptions) throws {
    self.init(region: options.region, cpu: options.cpu.map(Double.init), checkpoint: options.image)
    if let memory = options.memory {
      var text = memory.trimmingCharacters(in: .whitespaces).uppercased()
      for unit in ["GB", "G"] where text.hasSuffix(unit) {
        text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
        break
      }
      guard let gb = Double(text), gb > 0 else {
        throw HostDriverError.provisioning(
          "Railway can't make a host with \"\(memory)\" of memory: give it in GB, such as 8GB.")
      }
      memoryGB = gb
    }
  }

  /// The mutation's input: always this Mac's environment and no idle timeout (ADR 0071).
  func input(environmentID: String) -> RailwayJSON {
    var input: [String: RailwayJSON] = [
      "environmentId": .string(environmentID), "idleTimeoutMinutes": 0,
    ]
    if let region { input["region"] = .string(region) }
    var resources: [String: RailwayJSON] = [:]
    if let cpu { resources["cpu"] = .double(cpu) }
    if let memoryGB { resources["memoryGB"] = .double(memoryGB) }
    if !resources.isEmpty { input["resources"] = .object(resources) }
    if let checkpoint { input["template"] = ["name": .string(checkpoint)] }
    return .object(input)
  }
}

// MARK: The driver's host options

extension RailwayHostDriver {
  /// This Mac's checkpoints and the plan's sizes. Only the size needs the plan, so a failed plan
  /// read leaves the size unsaid; a failed checkpoint read is the read's failure.
  public func readHostOptions() async throws -> HostOptionsFacts {
    async let size = try? planSize()
    let checkpoints = try await api.sandboxCheckpoints(environmentID: configuration.environmentID)
    return .railway(RailwayHostOptions(checkpoints: checkpoints, size: await size))
  }

  private func planSize() async throws -> RailwayHostOptions.Size? {
    guard let workspace = configuration.workspaceID else { return nil }
    guard let plan = try await api.grantedWorkspaces().first(where: { $0.id == workspace })?.plan
    else { return nil }
    return RailwayHostOptions.Size(plan: plan)
  }

  /// Refuses a checkpoint this Mac's environment doesn't hold, before anything is made: one saved
  /// at a level another Mac shares, or since deleted.
  func checkHeld(checkpoint: String) async throws {
    let held = try await api.sandboxCheckpoints(environmentID: configuration.environmentID)
    guard held.contains(checkpoint) else {
      throw HostDriverError.provisioning(
        "This Mac's Railway environment has no checkpoint named \"\(checkpoint)\", so no host can "
          + "be made from it. Choose one of its checkpoints, or Railway's default image, in the "
          + "host options.")
    }
  }

  /// Removes the source's checkout at `path` from a host made from a checkpoint, and the source's
  /// `gh` token with it, then writes the Mac's current token back so the clone can fetch (ADR
  /// 0072). Only a checkout of `cloneURL` goes, as on boxd; anything else there fails the create.
  public func clearCheckout(at path: String, of cloneURL: String, on host: HostID) async throws {
    let (id, record) = try record(of: host)
    let config = try SSHTransport.writeConfiguration(
      for: target(record, identity: configuration.keys.appendingPathComponent("id_ed25519").path),
      in: hostDirectory(id))
    try await login(
      config,
      Self.clearCheckoutCommand(path: path, cloneURL: cloneURL, tokenPath: Self.gitHubTokenPath),
      stdin: Data(),
      failure: "Workroom kept \(path) on the checkpoint: it isn't this project's checkout, or"
        + " couldn't be removed, so the clone can't go there")
    try await refreshGitHubToken(on: host)
  }

  /// The host's side of `clearCheckout`: the token file and its half-written copy go first, as
  /// the checkout's check ends early when there is none.
  static func clearCheckoutCommand(path: String, cloneURL: String, tokenPath: String) -> String {
    "rm -f -- \(PosixShell.quoted(tokenPath)) \(PosixShell.quoted(tokenPath + ".new")); "
      + BoxdHostDriver.clearCheckoutScript(path: path, cloneURL: cloneURL)
  }
}

// MARK: The API calls

extension RailwayAPI {
  /// The names of the checkpoints in `environmentID`, oldest first as Railway lists them.
  public func sandboxCheckpoints(environmentID: String) async throws -> [String] {
    struct Answer: Decodable {
      struct Checkpoint: Decodable { let key: String }
      let sandboxCheckpoints: [Checkpoint]
    }
    return try await query(
      "query sandboxCheckpoints($environmentId: String!) { sandboxCheckpoints(environmentId: "
        + "$environmentId) { id key environmentId createdAt } }",
      variables: ["environmentId": .string(environmentID)], as: Answer.self
    ).sandboxCheckpoints.map(\.key)
  }
}
