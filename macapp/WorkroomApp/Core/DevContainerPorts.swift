import Foundation
import WorkroomVCS

/// The ports a repository's dev container declares, which a container workroom forwards to this Mac
/// (`PortForwardingModel.forwardDeclared`).
///
/// Read from the Development Containers spec's `devcontainer.json` (containers.dev), the file VS
/// Code, Codespaces, DevPod and others already read, so a repository that has one needs nothing
/// new. Only the port fields are honoured, and only these of them:
///
/// - `forwardPorts`: each number is forwarded. A `"host:port"` string names a port on another
///   host (a Compose service), which the daemon can't reach, so it is skipped.
/// - `portsAttributes`, keyed by a single port: `label`, shown on the row, and `requireLocalPort`,
///   which refuses the forward rather than move it to another port when this Mac holds the number.
///
/// Everything else in the file is ignored, the container's own definition (`image`, `build`,
/// `features`) included: a container workroom runs Workroom's own image (#308). So are `appPort`,
/// which the spec itself steers away from, and port ranges and patterns in `portsAttributes`.
enum DevContainerPorts {
  struct Port: Equatable, Sendable {
    let port: UInt16
    var label: String? = nil
    var requireLocalPort = false
  }

  /// Where the spec looks for the file, in its order. Its third place, one folder per
  /// configuration under `.devcontainer/`, needs a choice of configuration and is not read.
  static let paths = [".devcontainer/devcontainer.json", ".devcontainer.json"]

  /// Far past any real file, which is a page of JSON.
  static let maxBytes = 256 * 1024

  /// The most ports one file has forwarded (`PortForwardingModel.forwardDeclared`). A real dev
  /// container declares a handful; each forward holds a listening descriptor for the launch.
  static let maxForwards = 32

  /// The first of `paths` that `files` has, and its bytes, or nil when it has none.
  static func read(_ files: FileProviding) async throws -> (path: String, data: Data)? {
    for path in paths {
      do {
        return (
          path, try await files.read(path: path, symlinks: .followWithinRoot, maxBytes: maxBytes)
        )
      } catch FileServiceError.notFound {
        continue
      }
    }
    return nil
  }

  /// The ports `data` declares, in its order, each once. The file is JSON with comments and trailing
  /// commas allowed, as the spec has it.
  static func parse(_ data: Data) throws -> [Port] {
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = true
    let file = try decoder.decode(File.self, from: data)
    var seen: Set<UInt16> = []
    return (file.forwardPorts ?? []).compactMap { entry in
      guard case .port(let port) = entry, seen.insert(port).inserted else { return nil }
      let attributes = file.portsAttributes?[String(port)]
      return Port(
        port: port, label: attributes?.label,
        requireLocalPort: attributes?.requireLocalPort ?? false)
    }
  }

  private struct File: Decodable {
    var forwardPorts: [Entry]?
    var portsAttributes: [String: Attributes]?
  }

  private struct Attributes: Decodable {
    var label: String?
    var requireLocalPort: Bool?
  }

  private enum Entry: Decodable {
    case port(UInt16)
    case other

    init(from decoder: Decoder) throws {
      let value = try decoder.singleValueContainer()
      if let port = try? value.decode(UInt16.self), port > 0 {
        self = .port(port)
      } else {
        self = .other
      }
    }
  }
}
