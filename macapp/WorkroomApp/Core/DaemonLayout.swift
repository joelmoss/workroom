import DaemonConnection
import Foundation

/// `Service::Layout` (`0x06`) on a workroomd connection: each remote workroom's pane layout, kept on
/// its host so any Mac that opens the workroom rebuilds the same tabs and splits (#255,
/// `docs/designs/oq8-cross-machine-reattach.md`). Everything here is the wire contract of
/// `vcs/crates/workroomd/src/layout.rs`; `DaemonLayoutTests` drives the real daemon.
///
/// The daemon keeps a layout as opaque bytes behind a revision. A `put` names the revision it read,
/// and one that has moved is refused with `DaemonLayoutError.stale`, carrying the current revision.
struct DaemonLayoutService: Sendable {
  let connection: DaemonVCSConnection

  /// Whether this daemon keeps layouts at all: one started with no screens directory, as on this
  /// Mac, does not.
  func isAvailable() async throws -> Bool {
    try DaemonLayoutReply<DaemonLayoutCapabilities>.decode(
      await connection.layoutRequest(DaemonLayoutRequest(method: "capabilities"))
    ).available
  }

  /// The workroom's revision and layout: revision 0 and nil for one never written.
  func get(_ key: String) async throws -> DaemonLayout {
    try DaemonLayoutReply<DaemonLayout>.decode(
      await connection.layoutRequest(DaemonLayoutRequest(method: "get", key: key)))
  }

  /// Stores `blob` if `expected` is the workroom's current revision, and returns the new one.
  func put(_ key: String, expected: UInt64, blob: String) async throws -> UInt64 {
    try DaemonLayoutReply<DaemonLayoutWritten>.decode(
      await connection.layoutRequest(
        DaemonLayoutRequest(method: "put", key: key, expected: expected, blob: blob))
    ).revision
  }
}

struct DaemonLayoutRequest: Encodable, Sendable {
  let version = 1
  let method: String
  var key: String? = nil
  var expected: UInt64? = nil
  var blob: String? = nil
}

/// A workroom's layout as the host keeps it.
struct DaemonLayout: Decodable, Sendable, Equatable {
  let revision: UInt64
  /// The app's own `TargetSession` JSON, or nil when nothing was ever written.
  let blob: String?
}

struct DaemonLayoutWritten: Decodable, Sendable { let revision: UInt64 }

struct DaemonLayoutCapabilities: Decodable, Sendable {
  let version: Int
  let available: Bool
}

/// What a layout request can fail with: `layout.rs`'s `LayoutError`.
enum DaemonLayoutError: Error, Equatable, Sendable {
  /// The workroom's revision moved since this Mac read it.
  case stale(revision: UInt64)
  /// Over the blob or key cap.
  case tooLarge(String)
  /// The daemon keeps no layouts, or the request was malformed.
  case unsupported(String)
  /// The host's disk refused.
  case failed(String)
}

/// The reply envelope: `{"version": 1, "result": …}` or `{"version": 1, "error": {kind: …}}`.
struct DaemonLayoutReply<T: Decodable>: Decodable {
  let result: T
  private enum CodingKeys: CodingKey { case version, result, error }
  private struct Stale: Decodable { let revision: UInt64 }
  private enum ErrorKeys: String, CodingKey { case stale, tooLarge, unsupported, failed }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .version) == 1 else {
      throw HostConnectionError.serviceUnavailable("Unsupported layout response version.")
    }
    if values.contains(.error) {
      let error = try values.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
      if let stale = try error.decodeIfPresent(Stale.self, forKey: .stale) {
        throw DaemonLayoutError.stale(revision: stale.revision)
      }
      if let why = try error.decodeIfPresent(String.self, forKey: .tooLarge) {
        throw DaemonLayoutError.tooLarge(why)
      }
      if let why = try error.decodeIfPresent(String.self, forKey: .unsupported) {
        throw DaemonLayoutError.unsupported(why)
      }
      if let why = try error.decodeIfPresent(String.self, forKey: .failed) {
        throw DaemonLayoutError.failed(why)
      }
      throw HostConnectionError.serviceUnavailable("Malformed layout failure.")
    }
    result = try values.decode(T.self, forKey: .result)
  }

  static func decode(_ data: Data) throws -> T {
    try JSONDecoder().decode(Self.self, from: data).result
  }
}
