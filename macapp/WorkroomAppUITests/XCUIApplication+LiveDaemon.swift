import XCTest

extension XCUIApplication {
  /// Launch through a scratch `workroomd` of its own (`-WorkroomUITestLiveDaemon`), so no daemon,
  /// session or config of the developer's is touched. A test that starts a run needs one: a run runs
  /// only in a daemon run session (#522), and a fixture launch has no daemon otherwise. The app ends
  /// the daemon, its sessions and the directory once it exits
  /// (`UITestFixture.endLiveDaemonWhenTheAppExits`). Returns the directory.
  @discardableResult
  func useScratchDaemon() -> String {
    let directory = "/tmp/wr-ui-\(UUID().uuidString.prefix(8))"
    launchArguments += ["-WorkroomUITestLiveDaemon", directory]
    return directory
  }
}
