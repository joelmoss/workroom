import Foundation
import HostDrivers

/// The scripts in this checkout's `macapp/Resources/<folder>`, the folder the app bundles them in:
/// a package test finds them here, as the app finds them in its bundle. That the bundle holds them
/// is the app's own tests' to prove (`HostSetupBundleTests`, `DaemonBootstrapBundleTests`).
func checkoutScripts(in folder: String) -> ScriptLocator {
  let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/\(folder)")
  return { name in
    let url = directory.appendingPathComponent("\(name).sh")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }
}

extension HostSetup {
  /// The host-setup scripts in this checkout.
  static let checkout = HostSetup(scripts: checkoutScripts(in: "host-setup"))
}
