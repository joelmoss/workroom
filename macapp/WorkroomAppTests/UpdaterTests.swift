import XCTest

@testable import Workroom

/// The toolbar pill is driven by `Updater.availableVersionString`. Sparkle's scheduled checks are off
/// in Debug (and tests run Debug), so constructing `Updater` fires no network check — we can assert
/// the pill state transitions directly without a live Sparkle session.
@MainActor
final class UpdaterTests: XCTestCase {
  func testStartsWithNoAvailableUpdate() {
    XCTAssertNil(Updater().availableVersionString)
  }

  func testSetAndClearAvailableDrivesPillState() {
    let updater = Updater()
    updater.setAvailable("2.0.0")
    XCTAssertEqual(updater.availableVersionString, "2.0.0")
    updater.clearAvailable()
    XCTAssertNil(updater.availableVersionString)
  }

  func testSetAndClearDownloadingDrivesPillState() {
    let updater = Updater()
    updater.setDownloading(true)
    XCTAssertTrue(updater.isDownloading)
    updater.setDownloading(false)
    XCTAssertFalse(updater.isDownloading)
  }

  /// Build-identity channels (issue #91): the pinned nightly build always tracks `nightly`
  /// regardless of the stored preference; the main app uses the picked channel's floor set.
  func testAllowedChannelsByBuildIdentity() {
    XCTAssertEqual(Updater.allowedChannels(isNightlyBuild: true, picked: .stable), ["nightly"])
    XCTAssertEqual(Updater.allowedChannels(isNightlyBuild: true, picked: .pre), ["nightly"])
    XCTAssertEqual(Updater.allowedChannels(isNightlyBuild: false, picked: .stable), [])
    XCTAssertEqual(Updater.allowedChannels(isNightlyBuild: false, picked: .pre), ["pre"])
  }

  /// Migration (issue #91): an upgrading beta user with no channel set yet is opted into `.pre` so
  /// they keep getting betas; fresh/stable installs and users who already chose a channel are left
  /// on the `.stable` default.
  func testChannelMigrationDefaultsBetaUsersToPre() {
    // Unset + running a prerelease → migrate to pre.
    XCTAssertTrue(
      Updater.shouldDefaultToPre(channelKeyIsSet: false, currentVersion: "2.0.0-beta.21"))
    XCTAssertTrue(Updater.shouldDefaultToPre(channelKeyIsSet: false, currentVersion: "1.4.0-rc.1"))
    // Unset + stable build → stay stable.
    XCTAssertFalse(Updater.shouldDefaultToPre(channelKeyIsSet: false, currentVersion: "1.3.0"))
    // Already chosen a channel → never re-migrate, even on a prerelease build.
    XCTAssertFalse(
      Updater.shouldDefaultToPre(channelKeyIsSet: true, currentVersion: "2.0.0-beta.21"))
    // Missing / unparseable version → don't migrate.
    XCTAssertFalse(Updater.shouldDefaultToPre(channelKeyIsSet: false, currentVersion: nil))
    XCTAssertFalse(Updater.shouldDefaultToPre(channelKeyIsSet: false, currentVersion: ""))
  }
}
