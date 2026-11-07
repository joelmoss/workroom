import Foundation
import HostDrivers

/// The scripts the build phase put in `Contents/Resources/<folder>`: the bundle's side of the
/// `ScriptLocator` that package tests answer from the checkout (`checkoutScripts(in:)`).
func bundledScripts(in folder: String) -> ScriptLocator {
  { name in Bundle.main.url(forResource: name, withExtension: "sh", subdirectory: folder) }
}

/// The host-setup scripts (HostDrivers' `HostSetup`) this app bundles: every provider driver the
/// app makes is handed these (`HostDriverRegistry`).
extension HostSetup {
  static let bundled = HostSetup(scripts: bundledScripts(in: "host-setup"))
}
