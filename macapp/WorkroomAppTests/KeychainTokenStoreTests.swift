import Foundation
import Security
import Synchronization
import XCTest

@testable import Workroom

/// The Keychain store the Railway refresh token is kept in (ADR 0073, #627), over a stand-in for
/// the `SecItem` calls: no test touches the real Keychain, which a throwaway HOME doesn't isolate.
final class KeychainTokenStoreTests: XCTestCase {
  /// The Keychain's items by service and account, answering as `SecItem` does.
  private final class FakeKeychain: KeychainCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var queries: [[String: Any]] = []
    /// A status every call answers instead, as a locked or refusing Keychain would.
    var failure: OSStatus?

    private func key(_ query: [String: Any]) -> String {
      "\(query[kSecAttrService as String] ?? "")/\(query[kSecAttrAccount as String] ?? "")"
    }
    var stored: [String: Data] { lock.withLock { items } }

    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
      lock.withLock {
        queries.append(query)
        if let failure { return (failure, nil) }
        guard let data = items[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
      }
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
      lock.withLock {
        queries.append(attributes)
        if let failure { return failure }
        if items[key(attributes)] != nil { return errSecDuplicateItem }
        items[key(attributes)] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
      }
    }
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
      lock.withLock {
        queries.append(query)
        if let failure { return failure }
        guard items[key(query)] != nil else { return errSecItemNotFound }
        items[key(query)] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
      }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
      lock.withLock {
        queries.append(query)
        if let failure { return failure }
        return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
      }
    }
  }

  /// Value: protects=the refresh token round-trips, and a second write replaces the first (Railway
  /// rotates it); fails_when=a write after the first fails as a duplicate, or reads back stale;
  /// seam=KeychainTokenStore
  func testATokenIsWrittenReplacedAndRead() throws {
    let keychain = FakeKeychain()
    let store = KeychainTokenStore(service: "svc", accessGroup: nil, keychain: keychain)

    XCTAssertNil(try store.read())
    try store.write("rt-1")
    try store.write("rt-2")

    XCTAssertEqual(try store.read(), "rt-2")
    XCTAssertEqual(keychain.stored.count, 1)
    try store.delete()
    XCTAssertNil(try store.read())
    XCTAssertNoThrow(try store.delete(), "deleting nothing is fine")
  }

  /// Value: protects=a Keychain that can't answer (locked, refused) throws rather than reading as
  /// no sign-in, which would show the user signed out; seam=KeychainTokenStore
  func testAKeychainThatCantAnswerThrowsRatherThanReadingAsSignedOut() {
    let keychain = FakeKeychain()
    keychain.failure = errSecInteractionNotAllowed
    let store = KeychainTokenStore(service: "svc", accessGroup: nil, keychain: keychain)

    XCTAssertThrowsError(try store.read())
    XCTAssertThrowsError(try store.write("rt"))
  }

  /// Value: protects=with an access group, the item goes in that group of the data protection
  /// keychain; without one, no group is named; seam=KeychainTokenStore
  func testAnAccessGroupIsNamedOnEveryQueryOnlyWhenGiven() throws {
    let shared = FakeKeychain()
    try KeychainTokenStore(service: "svc", accessGroup: "TEAM.group", keychain: shared).write("rt")
    for query in shared.queries {
      XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "TEAM.group")
      XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }

    let own = FakeKeychain()
    try KeychainTokenStore(service: "svc", accessGroup: nil, keychain: own).write("rt")
    for query in own.queries {
      XCTAssertNil(query[kSecAttrAccessGroup as String])
      XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }
  }

  /// Value: protects=a Dev build keeps its own sign-in (its own service), and Release and Nightly
  /// don't share one through the file keychain before the access group exists; seam=RailwayAccount
  func testEachBuildKeepsItsOwnKeychainService() {
    XCTAssertEqual(
      RailwayAccount.keychainService(bundleID: "com.developwithstyle.workroom.dev.wr-x"),
      "com.developwithstyle.workroom.dev.wr-x.railway")
    XCTAssertNotEqual(
      RailwayAccount.keychainService(bundleID: "com.developwithstyle.workroom"),
      RailwayAccount.keychainService(bundleID: "com.developwithstyle.workroom.dev"))
  }
}
