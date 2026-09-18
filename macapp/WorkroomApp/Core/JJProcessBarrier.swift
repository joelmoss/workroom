import Darwin
import Foundation

/// Shared with wr-agent's SnapshotLock. A disconnected agent can still be snapshotting; the
/// process-local task gate cannot see its completion. The kernel releases this barrier only when
/// the owner finishes or exits, so native writers cannot overtake an accepted agent snapshot.
final class JJProcessBarrier: @unchecked Sendable {
  private let descriptor: Int32
  private init(_ descriptor: Int32) { self.descriptor = descriptor }
  deinit { Darwin.close(descriptor) }

  static func acquire(_ repository: RepositoryLocation) throws -> JJProcessBarrier? {
    guard repository.host == .local else { return nil }
    let directory = repository.path + "/.jj"
    // The gate is also used by injected providers/tests, and may coordinate a Git operation.
    guard FileManager.default.fileExists(atPath: directory) else { return nil }
    let fd = open(directory + "/workroom-vcs.lock", O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw VCSError.io("Cannot open JJ operation barrier.") }
    let started = Date()
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EAGAIN else {
        Darwin.close(fd)
        throw VCSError.io("Cannot acquire JJ operation barrier.")
      }
      guard Date().timeIntervalSince(started) < 30 else {
        Darwin.close(fd)
        throw VCSError.lockContention
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return JJProcessBarrier(fd)
  }

  func release() { _ = flock(descriptor, LOCK_UN) }
}
