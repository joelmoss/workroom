import Foundation

/// Seam over the macOS Trash so the from-disk project delete (issue #108) can move
/// directories to the Bin — `FileManager.trashItem` gives Finder "Put Back" and needs no
/// automation/TCC prompt — while staying unit-testable. Tests inject a fake recorder so the
/// `deleteProject(scope: .fromDisk)` orchestration can be asserted without touching the real
/// user Trash. Mirrors the `CommandExecutor` mock seam used for the VCS layer.
protocol Trashing {
  /// Move the item at `url` to the Trash. Throws on failure (locked file, permission denied,
  /// cross-volume issue, …) so the caller can report exactly which dirs were left behind.
  func trash(_ url: URL) throws
}

/// Production `Trashing`: the native, Put-Back-capable, prompt-free macOS Trash.
struct SystemTrasher: Trashing {
  func trash(_ url: URL) throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
  }
}
