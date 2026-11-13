import AppKit
import Foundation
import HostDrivers
import Security

/// The app's Railway sign-in (ADR 0073, #627): the session that keeps the refresh token and is the
/// one owner that refreshes it, the GraphQL API client over it, and Login with Railway in the
/// browser. Workroom never reads or writes the user's `~/.railway`: its own `railway` CLI keeps
/// working as they left it.
final class RailwayAccount: Sendable {
  let session: RailwaySession
  let api: RailwayAPI
  private let signIn: RailwaySignIn
  private let open: @Sendable (URL) async -> Void

  init(
    transport: any RailwayHTTPTransport, store: any RailwayTokenStore,
    lock: any RailwayRefreshLock, clientID: String,
    open: @escaping @Sendable (URL) async -> Void
  ) {
    let client = RailwayOAuthClient(clientID: clientID, transport: transport)
    session = RailwaySession(client: client, store: store, lock: lock)
    api = RailwayAPI(transport: transport, tokens: session)
    signIn = RailwaySignIn(client: client)
    self.open = open
  }

  /// Signs in with the browser and keeps the sign-in. Cancelling the task stops it.
  func signInWithBrowser() async throws {
    let tokens = try await signIn.run(open: open)
    try await session.signIn(with: tokens)
  }

  /// The app's account: Railway itself, the refresh token in this build's Keychain item. In any
  /// test process, Railway stubbed (`RailwayStub`: the UI test fixture's scenario, else signed
  /// out), so no test reaches Railway, opens a browser, or touches the developer's Keychain.
  static let shared: RailwayAccount = {
    #if DEBUG
      if AppEnvironment.current.isTestProcess {
        return UITestFixture.railwayAccount
          ?? RailwayStub(workspaces: []).account(store: RailwayStub.MemoryStore())
      }
    #endif
    return RailwayAccount(
      transport: URLSessionRailwayTransport(),
      store: KeychainTokenStore(service: keychainService(bundleID: bundleID)),
      lock: FileRefreshLock(path: refreshLockPath), clientID: clientID,
      open: { url in _ = await MainActor.run { NSWorkspace.shared.open(url) } })
  }()

  /// This Mac's Railway folder (ADR 0071, #629): its ssh key for the relay, the relay's pinned host
  /// key and the placement (`RailwayPlacement`). One for Release and Nightly, which share the
  /// project, environment, key and hosts though each signs in itself (ADR 0073); a Dev build's
  /// own. A test process gets a folder of its own, so no test reads or writes the developer's.
  static let directory: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Workroom", isDirectory: true)
    #if DEBUG
      if AppEnvironment.current.isTestProcess {
        return FileManager.default.temporaryDirectory.appendingPathComponent(
          "workroom-railway-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
          isDirectory: true)
      }
    #endif
    let folder =
      RemoteWorkrooms.sharedHostBuilds.contains(bundleID)
      ? base : base.appendingPathComponent(bundleID, isDirectory: true)
    return folder.appendingPathComponent("railway", isDirectory: true)
  }()

  /// Where this Mac keeps its Railway hosts: the workspace, project and environment.
  static let placement = RailwayPlacementStore(
    file: directory.appendingPathComponent("placement.json"))

  /// Codaset's Native OAuth app (`RailwayOAuthClientID` in the Info properties). Public by design.
  static var clientID: String {
    Bundle.main.object(forInfoDictionaryKey: "RailwayOAuthClientID") as? String ?? ""
  }

  /// The workspace holding this Mac's `Workroom` project (ADR 0071), which the setup sheet checks
  /// the sign-in reaches. Nil until a project is recorded.
  static var neededWorkspaceID: String? {
    #if DEBUG
      if let fixture = UITestFixture.railwayNeededWorkspace { return fixture }
    #endif
    return placement.read().workspaceID
  }

  private static var bundleID: String {
    Bundle.main.bundleIdentifier ?? "com.developwithstyle.workroom"
  }

  /// The Keychain service of a build's sign-in: its bundle id's, so each build, Release and
  /// Nightly included, keeps its own (ADR 0073).
  static func keychainService(bundleID: String) -> String { "\(bundleID).railway" }

  /// The lock this build refreshes its sign-in under. Each build's sign-in is its own
  /// authorization at Railway, so only this build's processes share it.
  private static var refreshLockPath: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Workroom", isDirectory: true)
      .appendingPathComponent(bundleID, isDirectory: true)
      .appendingPathComponent("railway-refresh.lock")
  }
}

// MARK: The Keychain

/// The `SecItem` calls the Keychain store makes, so its tests never touch the real Keychain.
protocol KeychainCalling: Sendable {
  func copy(_ query: [String: Any]) -> (OSStatus, Data?)
  func add(_ attributes: [String: Any]) -> OSStatus
  func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
  func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychain: KeychainCalling {
  func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result as? Data)
  }
  func add(_ attributes: [String: Any]) -> OSStatus {
    SecItemAdd(attributes as CFDictionary, nil)
  }
  func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }
  func delete(_ query: [String: Any]) -> OSStatus {
    SecItemDelete(query as CFDictionary)
  }
}

/// A Keychain call that failed.
struct KeychainError: Error, LocalizedError, Equatable {
  let status: OSStatus
  var errorDescription: String? {
    let said = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
    return "The Keychain refused: \(said)"
  }
}

/// The refresh token as a generic password in this build's Keychain item, this device only (ADR
/// 0073: each build keeps its own sign-in). A read that can't answer (a locked Keychain) throws
/// rather than reading as no sign-in.
final class KeychainTokenStore: RailwayTokenStore {
  private let service: String
  private let account: String
  private let keychain: any KeychainCalling

  init(
    service: String, account: String = "refresh-token",
    keychain: any KeychainCalling = SystemKeychain()
  ) {
    self.service = service
    self.account = account
    self.keychain = keychain
  }

  private var base: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  func read() throws -> String? {
    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status, data) = keychain.copy(query)
    switch status {
    case errSecSuccess: return data.map { String(decoding: $0, as: UTF8.self) }
    case errSecItemNotFound: return nil
    default: throw KeychainError(status: status)
    }
  }

  func write(_ token: String) throws {
    let data = Data(token.utf8)
    let status = keychain.update(base, [kSecValueData as String: data])
    switch status {
    case errSecSuccess: return
    case errSecItemNotFound:
      var attributes = base
      attributes[kSecValueData as String] = data
      attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      attributes[kSecAttrLabel as String] = "Workroom: Railway sign-in"
      let added = keychain.add(attributes)
      guard added == errSecSuccess else { throw KeychainError(status: added) }
    default: throw KeychainError(status: status)
    }
  }

  func delete() throws {
    let status = keychain.delete(base)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }
}
