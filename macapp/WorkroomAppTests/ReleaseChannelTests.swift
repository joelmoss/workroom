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

  /// The app classifies no tags, but its raw values must be the channel names the CLI and
  /// `channel-helper.sh` classify tags into (and `appcast.sh` writes): every channel in their
  /// shared fixture, `internal/channel/testdata/channel_cases.tsv`, and no other.
  func testRawValuesAreTheChannelsTheClassifiersProduce() throws {
    var channels = Set<String>()
    for fields in try SharedFixture.rows(
      "internal/channel/testdata/channel_cases.tsv", columns: 2)
    where fields[1] != "EXCLUDED" {
      channels.insert(fields[1])
    }
    XCTAssertEqual(Set(ReleaseChannel.allCases.map(\.rawValue)), channels)
  }

  /// The main app's Settings picker offers stable/pre only — nightly is a separate side-by-side
  /// product, never a runtime switch.
  func testPickerCasesExcludeNightly() {
    XCTAssertEqual(ReleaseChannel.pickerCases, [.stable, .pre])
    XCTAssertFalse(ReleaseChannel.pickerCases.contains(.nightly))
  }
}
