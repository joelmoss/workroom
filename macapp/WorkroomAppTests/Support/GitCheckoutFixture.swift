import Foundation

/// Makes `path` a folder `isGitRepo` accepts, without running git: a `.git` directory holding a
/// `HEAD`, `objects/` and `refs/`. An empty or HEAD-only `.git` does not count — git rejects both and
/// discovers an ANCESTOR repository — so a fixture that stands for a repository needs all three.
func makeGitCheckout(atPath path: String) throws {
  for dir in ["/.git/objects", "/.git/refs"] {
    try FileManager.default.createDirectory(atPath: path + dir, withIntermediateDirectories: true)
  }
  try Data("ref: refs/heads/main\n".utf8).write(to: URL(fileURLWithPath: path + "/.git/HEAD"))
}
