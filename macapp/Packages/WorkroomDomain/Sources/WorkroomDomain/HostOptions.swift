import Foundation

/// What a provider's host image is (#575), and so what the app calls it and whether it can list
/// the account's own.
public enum HostImageKind: Sendable {
  /// A snapshot of one of the account's machines, which the fields list and check by name.
  case snapshot
  /// A container image, named with its registry.
  case containerImage
  /// A Railway checkpoint in this Mac's environment, which the fields list by name.
  case checkpoint

  /// The host option field's label.
  public var fieldLabel: String {
    switch self {
    case .snapshot: "Snapshot"
    case .containerImage: "Custom image"
    case .checkpoint: "Checkpoint"
    }
  }

  /// The label for what a workroom's host was made from, in its Details pane.
  public var madeFromLabel: String {
    switch self {
    case .snapshot: "Made From Snapshot"
    case .containerImage: "Custom Image"
    case .checkpoint: "Made From Checkpoint"
    }
  }
}

/// One host option at one level, when the level sets it: Provider default (explicitly none) or a
/// value. A level that doesn't set it holds nil, and the option is inherited from the next.
public enum HostOption<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
  case providerDefault
  case value(Value)
}

/// What one level (this create, a project, or Settings) chooses for a provider's hosts (#575,
/// ADR 0065). The field and case names are a stored-data contract in `Defaults`: keep them.
public struct HostOptions: Codable, Hashable, Sendable {
  /// exe.dev's `--image`; boxd's `--from-snapshot`; Railway's checkpoint, by name.
  public var image: HostOption<String>?
  /// exe.dev's `--cpu`; boxd's `--vcpu`, whose memory follows; Railway's vCPUs.
  public var cpu: HostOption<Int>?
  /// exe.dev's `--memory`; Railway's memory, both as `<n>GB`. boxd's size follows its CPU.
  public var memory: HostOption<String>?
  /// exe.dev's `--disk`, the root disk's size.
  public var disk: HostOption<String>?
  /// Railway's region (#633), by Railway's id (`us-east4-eqdc4a`).
  public var region: HostOption<String>?

  public init(
    image: HostOption<String>? = nil, cpu: HostOption<Int>? = nil,
    memory: HostOption<String>? = nil, disk: HostOption<String>? = nil,
    region: HostOption<String>? = nil
  ) {
    self.image = image
    self.cpu = cpu
    self.memory = memory
    self.disk = disk
    self.region = region
  }

  public var isEmpty: Bool { self == HostOptions() }

  /// These options over `base`: each one this level sets replaces `base`'s, and the rest stay. What
  /// the Options panel's Remember for this project saves.
  public func overlaid(on base: HostOptions) -> HostOptions {
    HostOptions(
      image: image ?? base.image, cpu: cpu ?? base.cpu, memory: memory ?? base.memory,
      disk: disk ?? base.disk, region: region ?? base.region)
  }

  /// Every option at Provider default: what Try With Provider Defaults creates with.
  public static let providerDefaults = HostOptions(
    image: .providerDefault, cpu: .providerDefault, memory: .providerDefault,
    disk: .providerDefault, region: .providerDefault)

  /// The level an option was resolved from.
  public enum Level: String, Hashable, Sendable {
    case create, project, settings
  }

  /// One option's resolved value, nil for the provider's default, and the level that decided it:
  /// nil when none did.
  public struct Resolved<Value: Hashable & Sendable>: Hashable, Sendable {
    public var value: Value?
    public var source: Level?

    public init(value: Value?, source: Level?) {
      self.value = value
      self.source = source
    }
  }

  /// Every option for a create of `provider`'s host, each with where it came from. The one place
  /// options are resolved: the create, project placeholders and the Options panel all read it.
  public struct Resolution: Hashable, Sendable {
    public var image: Resolved<String>
    public var cpu: Resolved<Int>
    public var memory: Resolved<String>
    public var disk: Resolved<String>
    public var region: Resolved<String>
    /// A boxd snapshot is the image, so the create gets no size: boxd refuses `--vcpu` and
    /// `--memory` with a snapshot ("forks and snapshot restores keep their source's size"). `cpu`
    /// still holds the size below, which a level that overrides the snapshot inherits.
    public var sizeTakenBySnapshot: Bool

    /// What the create sends.
    public var options: ResolvedHostOptions {
      ResolvedHostOptions(
        image: image.value, cpu: sizeTakenBySnapshot ? nil : cpu.value, memory: memory.value,
        disk: disk.value, region: region.value)
    }
  }

  /// Resolves each key on its own: `create`, then `project`, then `settings`, then the provider's
  /// own default. Nil for a kind that takes no host options (`HostKind.takesHostOptions`).
  public static func resolve(
    for provider: HostKind, create: HostOptions?, project: HostOptions?,
    settings: HostOptions?
  ) -> Resolution? {
    let levels: [(Level, HostOptions?)] = [
      (.create, create), (.project, project), (.settings, settings),
    ]
    func walk<V>(_ key: KeyPath<HostOptions, HostOption<V>?>) -> Resolved<V> {
      for (level, options) in levels {
        switch options?[keyPath: key] {
        case .value(let value): return Resolved(value: value, source: level)
        case .providerDefault: return Resolved(value: nil, source: level)
        case nil: continue
        }
      }
      return Resolved(value: nil, source: nil)
    }
    let none = Resolved<String>(value: nil, source: nil)
    let image = walk(\.image)
    switch provider {
    case .exeDev:
      return Resolution(
        image: image, cpu: walk(\.cpu), memory: walk(\.memory), disk: walk(\.disk),
        region: none, sizeTakenBySnapshot: false)
    case .boxd:
      return Resolution(
        image: image, cpu: walk(\.cpu), memory: none, disk: none, region: none,
        sizeTakenBySnapshot: image.value != nil)
    case .railway:
      // Railway sizes a checkpoint restore as it does a fresh sandbox (`SandboxResourcesInput`).
      return Resolution(
        image: image, cpu: walk(\.cpu), memory: walk(\.memory), disk: none,
        region: walk(\.region), sizeTakenBySnapshot: false)
    case .container, .ssh:
      return nil
    }
  }
}

/// The host options a host was created with, after resolution: nil is the provider's default.
/// Recorded on its `HostDescriptor` for the Details pane.
public struct ResolvedHostOptions: Codable, Hashable, Sendable {
  public var image: String?
  public var cpu: Int?
  public var memory: String?
  public var disk: String?
  public var region: String?

  public init(
    image: String? = nil, cpu: Int? = nil, memory: String? = nil, disk: String? = nil,
    region: String? = nil
  ) {
    self.image = image
    self.cpu = cpu
    self.memory = memory
    self.disk = disk
    self.region = region
  }

  public var isProviderDefault: Bool { self == ResolvedHostOptions() }
}
