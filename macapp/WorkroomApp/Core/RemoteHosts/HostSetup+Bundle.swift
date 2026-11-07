import Foundation
import HostDrivers

/// The host-setup scripts (HostDrivers' `HostSetup`) this app bundles: every provider driver the
/// app makes is handed these (`HostDriverRegistry`).
extension HostSetup {
  static let bundled = HostSetup(scripts: bundledScript(named:))

  /// Where the build phase put the scripts: `Contents/Resources/host-setup`.
  static func bundledScript(named name: String) -> URL? {
    Bundle.main.url(forResource: name, withExtension: "sh", subdirectory: "host-setup")
  }
}
