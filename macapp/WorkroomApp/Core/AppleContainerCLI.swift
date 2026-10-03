import Foundation

/// What `ContainerHostDriver` reads from, and writes for, Apple's `container` CLI (#309): its
/// `--format json` output, which is the only format it has besides tables (no Go templates, no
/// `--filter`), and the Dockerfile a derive builds its snapshot with, since 1.5.0 has no `commit`.
/// Measured against `container` 1.5.0.
enum AppleContainerCLI {
  /// A JSON array of objects, as `list`, `inspect`, `image list` and `image inspect` print.
  static func objects(_ text: String) throws -> [[String: Any]] {
    guard let objects = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
    else {
      throw HostDriverError.provisioning("container printed something other than a JSON list")
    }
    return objects
  }

  /// A container's ID (its name, as the driver runs it with `--name`).
  static func id(of container: [String: Any]) -> String? { container["id"] as? String }

  /// `running`, `stopped`, …
  static func state(of container: [String: Any]) -> String? {
    (container["status"] as? [String: Any])?["state"] as? String
  }

  static func labels(of container: [String: Any]) -> [String: String] {
    (configuration(container)["labels"] as? [String: String]) ?? [:]
  }

  /// The image reference the container was run from.
  static func imageReference(of container: [String: Any]) -> String? {
    (configuration(container)["image"] as? [String: Any])?["reference"] as? String
  }

  /// An image's reference, as `image list` names it.
  static func name(ofImage image: [String: Any]) -> String? {
    configuration(image)["name"] as? String
  }

  /// An image's labels, from whichever of its platforms carries them.
  static func labels(ofImage image: [String: Any]) -> [String: String] {
    variants(image).reduce(into: [:]) { labels, variant in
      labels.merge(config(variant)["Labels"] as? [String: String] ?? [:]) { first, _ in first }
    }
  }

  /// How an image's process starts, for its `architecture` (`arm64`: the runtime is Apple
  /// silicon only). Read from the image rather than from a container run from it, whose
  /// environment holds what `run --env` added, such as the client key.
  struct ProcessConfig: Equatable {
    var entrypoint: [String]? = nil
    var cmd: [String]? = nil
    var env: [String] = []
    var workingDir: String? = nil
    var user: String? = nil
  }

  static func processConfig(ofImage image: [String: Any], architecture: String) -> ProcessConfig? {
    guard
      let variant = variants(image).first(where: {
        ($0["platform"] as? [String: Any])?["architecture"] as? String == architecture
      })
    else { return nil }
    let config = config(variant)
    return ProcessConfig(
      entrypoint: config["Entrypoint"] as? [String], cmd: config["Cmd"] as? [String],
      env: config["Env"] as? [String] ?? [], workingDir: config["WorkingDir"] as? String,
      user: config["User"] as? String)
  }

  /// The Dockerfile that turns an exported container disk (`rootfs.tar`, beside it) back into an
  /// image that starts as `process` did. `ADD` unpacks a local tar. Exec form throughout, so
  /// nothing passes through a shell; a value with a newline is refused, since no Dockerfile line
  /// can hold one.
  static func dockerfile(_ process: ProcessConfig) throws -> String {
    func json(_ words: [String]) throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .withoutEscapingSlashes
      return String(decoding: try encoder.encode(words), as: UTF8.self)
    }
    let values =
      process.env + (process.entrypoint ?? []) + (process.cmd ?? [])
      + [process.workingDir, process.user].compactMap { $0 }
    guard !values.contains(where: { $0.contains(where: \.isNewline) }) else {
      throw HostDriverError.invalidConfiguration("the host image's config has a newline in it")
    }
    // A builder expands `$` in ENV, WORKDIR and USER; the image holds the values already expanded.
    // Quotes only matter inside ENV's quoted value.
    func literal(_ text: some StringProtocol, quoted: Bool = false) -> String {
      let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "$", with: "\\$")
      return quoted ? escaped.replacingOccurrences(of: "\"", with: "\\\"") : escaped
    }
    var lines = ["FROM scratch", "ADD rootfs.tar /"]
    for variable in process.env {
      guard let equals = variable.firstIndex(of: "=") else { continue }
      lines.append(
        "ENV \(variable[..<equals])=\"\(literal(variable[variable.index(after: equals)...], quoted: true))\""
      )
    }
    if let directory = process.workingDir, !directory.isEmpty {
      lines.append("WORKDIR \(literal(directory))")
    }
    if let user = process.user, !user.isEmpty { lines.append("USER \(literal(user))") }
    if let entrypoint = process.entrypoint { lines.append("ENTRYPOINT \(try json(entrypoint))") }
    if let cmd = process.cmd { lines.append("CMD \(try json(cmd))") }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func configuration(_ object: [String: Any]) -> [String: Any] {
    object["configuration"] as? [String: Any] ?? [:]
  }

  private static func variants(_ image: [String: Any]) -> [[String: Any]] {
    image["variants"] as? [[String: Any]] ?? []
  }

  private static func config(_ variant: [String: Any]) -> [String: Any] {
    ((variant["config"] as? [String: Any])?["config"] as? [String: Any]) ?? [:]
  }
}
