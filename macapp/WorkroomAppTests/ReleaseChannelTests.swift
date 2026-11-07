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
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // WorkroomAppTests
      .deletingLastPathComponent()  // macapp
      .deletingLastPathComponent()  // repository root
      .appendingPathComponent("internal/channel/testdata/channel_cases.tsv")
    var channels = Set<String>()
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    where !line.hasPrefix("#") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count == 2 else { return XCTFail("malformed fixture line: \(line)") }
      if fields[1] != "EXCLUDED" { channels.insert(String(fields[1])) }
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
