import Combine
import Defaults
import Foundation
import HostDrivers

/// Chooses an existing server and verifies it before the CLI reserves a workroom.
@MainActor
final class SSHHostSetup: ObservableObject, RemoteSetup {
  @Published var destination = "" {
    didSet {
      guard destination != oldValue else { return }
      cancel()
      driver = nil
      hostKey = nil
      problem = nil
      parent = Defaults[.sshHostParents][destination] ?? "~/workrooms"
    }
  }
  @Published var parent = "~/workrooms"
  @Published private(set) var checking = false
  @Published private(set) var problem: String?
  @Published private(set) var hostKey: SSHHostDriver.HostKey?
  @Published private(set) var driver: SSHHostDriver?
  private var candidate: SSHHostDriver?
  private var task: Task<Void, Never>?
  private var generation = UUID()

  var recentHosts: [String] { Defaults[.sshHostParents].keys.sorted() }
  var isReady: Bool {
    guard !checking, hostKey == nil, let driver else { return false }
    return (try? driver.resolveParent(parent)) != nil
  }

  func check() {
    cancel()
    driver = nil
    hostKey = nil
    problem = nil
    let id = UUID()
    generation = id
    let destination = destination
    checking = true
    task = Task {
      defer { if generation == id { checking = false } }
      do {
        let candidate = SSHHostDriver(
          configuration: .init(
            destination: destination, home: "",
            stateDirectoryName: RemoteHosts.sshStateDirectoryName),
          directory: RemoteHosts.hosts)
        self.candidate = candidate
        do {
          _ = try await candidate.checkHost()
          guard generation == id, !Task.isCancelled else { return }
          driver = candidate
        } catch SSHHostDriver.Failure.unknownHostKey {
          let key = try await candidate.captureHostKey()
          guard generation == id, !Task.isCancelled else { return }
          hostKey = key
        }
      } catch {
        guard generation == id, !Task.isCancelled else { return }
        problem = error.localizedDescription
      }
    }
  }

  func trust() {
    guard let candidate, let hostKey else { return }
    do {
      try candidate.trustHostKey(hostKey)
      check()
    } catch { problem = error.localizedDescription }
  }

  func remember() {
    guard isReady else { return }
    Defaults[.sshHostParents][destination] = parent
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    checking = false
  }
}
