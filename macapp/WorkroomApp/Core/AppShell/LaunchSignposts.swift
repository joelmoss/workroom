import os

/// Wall-clock stages for Instruments' Points of Interest. Async intervals include suspension;
/// overlapping windows, reads and watches each get their own signpost identity. No paths or
/// terminal commands are recorded.
enum LaunchSignposts {
  private static let poster = OSSignposter(
    subsystem: "com.developwithstyle.workroom", category: "PointsOfInterest")

  static func begin(_ name: StaticString) -> OSSignpostIntervalState {
    poster.beginInterval(name, id: poster.makeSignpostID())
  }

  static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
    poster.endInterval(name, state)
  }

  @MainActor private static var launch: OSSignpostIntervalState?

  @MainActor static func beginLaunch() {
    guard launch == nil else { return }
    launch = begin("Launch to window update")
  }

  /// AppKit completed an update with a visible app window; this is not a compositor-paint timestamp.
  @MainActor static func didDisplayWindow() {
    guard let launch else { return }
    end("Launch to window update", launch)
    self.launch = nil
  }
}
