import XCTest

@testable import Workroom

/// The floor model, expressed as Sparkle allowed-channel sets. Sparkle always includes the default
/// (untagged = stable) channel, so `.stable` is empty and pre/nightly list only the extra channels
/// they opt into. Mirror of the Go `internal/channel` FloorSet contract.
final class ReleaseChannelTests: XCTestCase {
  func testAllowedSparkleChannelsFloor() {
    XCTAssertEqual(ReleaseChannel.stable.allowedSparkleChannels, [])
    XCTAssertEqual(ReleaseChannel.pre.allowedSparkleChannels, ["pre"])
    XCTAssertEqual(ReleaseChannel.nightly.allowedSparkleChannels, ["pre", "nightly"])
  }

  /// The raw values are BOTH a stored-data contract and the `<sparkle:channel>` names the appcast
  /// emits — pin them so a rename can't silently break either.
  func testRawValuesAreStable() {
    XCTAssertEqual(ReleaseChannel.stable.rawValue, "stable")
    XCTAssertEqual(ReleaseChannel.pre.rawValue, "pre")
    XCTAssertEqual(ReleaseChannel.nightly.rawValue, "nightly")
    XCTAssertEqual(ReleaseChannel.allCases, [.stable, .pre, .nightly])
  }

  /// The main app's Settings picker offers stable/pre only — nightly is a separate side-by-side
  /// product, never a runtime switch.
  func testPickerCasesExcludeNightly() {
    XCTAssertEqual(ReleaseChannel.pickerCases, [.stable, .pre])
    XCTAssertFalse(ReleaseChannel.pickerCases.contains(.nightly))
  }
}
