import Foundation

/// A provider whose hosts Workroom creates with host options (#575): boxd and exe.dev. Container
/// workrooms take their image and size from devcontainer.json (ADR 0060); SSH hosts aren't made.
public enum HostProvider: String, Codable, Hashable, Sendable, CaseIterable {
  case boxd
  case exeDev

  public var displayName: String {
    switch self {
    case .boxd: "boxd"
    case .exeDev: "exe.dev"
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
  /// exe.dev's `--image`; boxd's `--from-snapshot`.
  public var image: HostOption<String>?
  /// exe.dev's `--cpu`; boxd's `--vcpu`, whose memory follows.
  public var cpu: HostOption<Int>?
  /// exe.dev's `--memory`. boxd's size follows its CPU.
  public var memory: HostOption<String>?
  /// exe.dev's `--disk`, the root disk's size.
  public var disk: HostOption<String>?

  public init(
    image: HostOption<String>? = nil, cpu: HostOption<Int>? = nil,
    memory: HostOption<String>? = nil, disk: HostOption<String>? = nil
  ) {
    self.image = image
    self.cpu = cpu
    self.memory = memory
    self.disk = disk
  }

  public var isEmpty: Bool { self == HostOptions() }

  /// These options over `base`: each one this level sets replaces `base`'s, and the rest stay. What
  /// the Options panel's Remember for this project saves.
  public func overlaid(on base: HostOptions) -> HostOptions {
    HostOptions(
      image: image ?? base.image, cpu: cpu ?? base.cpu, memory: memory ?? base.memory,
      disk: disk ?? base.disk)
  }

  /// Every option at Provider default: what Try With Provider Defaults creates with.
  public static let providerDefaults = HostOptions(
    image: .providerDefault, cpu: .providerDefault, memory: .providerDefault,
    disk: .providerDefault)

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
    /// A boxd snapshot is the image, so size resolves to nothing: boxd refuses `--vcpu` and
    /// `--memory` with a snapshot ("forks and snapshot restores keep their source's size").
    public var sizeTakenBySnapshot: Bool

    public var options: ResolvedHostOptions {
      ResolvedHostOptions(
        image: image.value, cpu: cpu.value, memory: memory.value, disk: disk.value)
    }
  }

  /// Resolves each key on its own: `create`, then `project`, then `settings`, then the provider's
  /// own default.
  public static func resolve(
    for provider: HostProvider, create: HostOptions?, project: HostOptions?,
    settings: HostOptions?
  ) -> Resolution {
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
        sizeTakenBySnapshot: false)
    case .boxd:
      let snapshot = image.value != nil
      return Resolution(
        image: image, cpu: snapshot ? Resolved(value: nil, source: nil) : walk(\.cpu),
        memory: none, disk: none, sizeTakenBySnapshot: snapshot)
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

  public init(image: String? = nil, cpu: Int? = nil, memory: String? = nil, disk: String? = nil) {
    self.image = image
    self.cpu = cpu
    self.memory = memory
    self.disk = disk
  }

  public var isProviderDefault: Bool { self == ResolvedHostOptions() }
}
