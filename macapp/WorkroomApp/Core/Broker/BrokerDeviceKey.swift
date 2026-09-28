import CryptoKit
import Foundation
import Security

/// This Mac's signing key for the Workroom credential broker (#251, design doc OQ20).
///
/// Every Mac-to-broker request is signed with it (`BrokerProof`); it is never a bearer token. On a
/// Mac with a Secure Enclave the key lives there and cannot be exported: what is stored is a blob
/// that names it, useless on any other Mac. The deployment target includes Intel Macs without one,
/// and those get a software P-256 key. Either is kept in the Keychain (`BrokerCredentials`), not a
/// file: a blob in a file lets any process running as this user load it and sign as this Mac,
/// while a Keychain item is tied to Workroom's code signature (the #251 review, D1).
enum BrokerDeviceKey: @unchecked Sendable {
  case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
  case software(P256.Signing.PrivateKey)

  /// A new key: in the Secure Enclave when there is one.
  static func generate() throws -> BrokerDeviceKey {
    if SecureEnclave.isAvailable {
      return .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey())
    }
    return .software(P256.Signing.PrivateKey())
  }

  var publicKey: P256.Signing.PublicKey {
    switch self {
    case .secureEnclave(let key): return key.publicKey
    case .software(let key): return key.publicKey
    }
  }

  /// An ES256 signature over `data`: r || s, 64 bytes, which is JWS's encoding.
  func signature(for data: Data) throws -> Data {
    switch self {
    case .secureEnclave(let key): return try key.signature(for: data).rawRepresentation
    case .software(let key): return try key.signature(for: data).rawRepresentation
    }
  }
}

/// Who this Mac is signed in to the broker as.
struct BrokerAccount: Codable, Equatable, Sendable {
  let deviceID: String
  let login: String
  let email: String
}

/// Where the device key and the account are kept: `Application Support/Workroom/<bundle id>/broker`,
/// scoped by bundle id like `SessionStore`, so Workroom Dev and Nightly each sign in separately.
struct BrokerCredentials: Sendable {
  /// The key's home (the Keychain). A seam, so tests never touch the login Keychain (locked on CI).
  struct SecretStore: Sendable {
    var read: @Sendable () -> Data?
    var write: @Sendable (Data) throws -> Void
    var delete: @Sendable () -> Void
  }

  let directory: URL
  let secrets: SecretStore

  private static let accountFile = "account.json"
  /// The first byte of the stored secret says which kind of key the rest is.
  private static let enclaveTag: UInt8 = 1
  private static let softwareTag: UInt8 = 2

  static func standard(bundleID: String? = Bundle.main.bundleIdentifier) -> BrokerCredentials {
    let bundle = bundleID ?? "com.developwithstyle.workroom"
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[
        0
      ]
      .appendingPathComponent("Workroom", isDirectory: true)
      .appendingPathComponent(bundle, isDirectory: true)
      .appendingPathComponent("broker", isDirectory: true)
    return BrokerCredentials(directory: directory, secrets: .keychain(service: "\(bundle).broker"))
  }

  /// The stored account and its key, or nil when this Mac is not signed in (or either half is
  /// missing, which is the same thing).
  func load() -> (account: BrokerAccount, key: BrokerDeviceKey)? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.accountFile)),
      let account = try? JSONDecoder().decode(BrokerAccount.self, from: data)
    else { return nil }
    guard let secret = secrets.read(), let tag = secret.first else { return nil }
    let body = Data(secret.dropFirst())
    switch tag {
    case Self.enclaveTag:
      return (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body))
        .map { (account, .secureEnclave($0)) }
    case Self.softwareTag:
      return (try? P256.Signing.PrivateKey(rawRepresentation: body)).map {
        (account, .software($0))
      }
    default:
      return nil
    }
  }

  /// Replaces the key, then the account. A key that cannot be stored throws before the account
  /// changes, so a failed save leaves nothing half-written.
  func save(account: BrokerAccount, key: BrokerDeviceKey) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    switch key {
    case .secureEnclave(let key):
      try secrets.write(Data([Self.enclaveTag]) + key.dataRepresentation)
    case .software(let key): try secrets.write(Data([Self.softwareTag]) + key.rawRepresentation)
    }
    try write(try JSONEncoder().encode(account), to: Self.accountFile)
  }

  /// Forgets the account and the key. The broker still knows the device until it is removed at
  /// codaset.dev; without the key nothing can use it.
  func clear() {
    // `device-key.enclave`: where builds before the #251 review kept the enclave blob.
    for name in [Self.accountFile, "device-key.enclave"] {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
    secrets.delete()
  }

  private func write(_ data: Data, to name: String) throws {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

extension BrokerCredentials.SecretStore {
  /// A generic password in the login keychain, readable after first unlock, whose access list is
  /// Workroom's code signature: another app asks before it can read it. The login keychain does
  /// not enforce "this device only" (only the data-protection keychain does, and that needs a
  /// keychain-access-groups entitlement ad hoc Dev builds lack), so a keychain migrated to another
  /// Mac carries a software key with it; an enclave blob is useless there.
  static func keychain(service: String) -> Self {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "device-key",
    ]
    return Self(
      read: {
        var result: AnyObject?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess else {
          return nil
        }
        return result as? Data
      },
      write: { data in
        // Update in place when the item exists, so a failed write never deletes the key it was
        // replacing.
        var status = SecItemUpdate(
          query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
          var item = query
          item[kSecValueData as String] = data
          item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
          status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
          throw BrokerError.keyStorage("Keychain error \(status)")
        }
      },
      delete: { SecItemDelete(query as CFDictionary) })
  }
}
