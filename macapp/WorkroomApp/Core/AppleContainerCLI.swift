import Foundation

/// What `ContainerHostDriver` reads from, and writes for, Apple's `container` CLI (#309): its
/// `--format json` output, which is the only format it has besides tables (no Go templates, no
/// `--filter`). Measured against `container` 1.5.0.
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
