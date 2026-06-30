import Foundation

/// Reaps a process's whole descendant tree, so a cancelled or timed-out child doesn't leave
/// orphaned grandchildren running. `StatusCommandRunner` only SIGKILLed the direct child, but its
/// own comments note that helpers spawned by `git`/`gh` can outlive the parent (holding pipe write
/// ends open); the inline agent (issue #49, X2) wants the same guarantee for `claude`/`codex`.
///
/// Child lookup is via `pgrep -P` rather than libproc: `proc_listchildpids`'s return value is
/// ambiguous (bytes vs count across sources) and mis-reading it could target the wrong pid for a
/// SIGKILL — a far worse failure than missing a child. `pgrep` returns only real children.
enum ProcessTree {
  /// Breadth-first collection of every descendant pid under `pid`. Pure over an injected child
  /// lookup so the traversal (dedup + cycle-safety) is unit-tested without real processes.
  static func descendants(of pid: pid_t, children: (pid_t) -> [pid_t]) -> [pid_t] {
    var collected: [pid_t] = []
    var seen: Set<pid_t> = [pid]
    var queue = children(pid)
    while !queue.isEmpty {
      let next = queue.removeFirst()
      guard next > 1, !seen.contains(next) else { continue }
      seen.insert(next)
      collected.append(next)
      queue.append(contentsOf: children(next))
    }
    return collected
  }

  /// Direct children of `pid` via `/usr/bin/pgrep -P`. Empty for a childless process (the no-tools
  /// `claude -p` inline call, and most `git`/`gh` probes) and on any error.
  static func childPids(of pid: pid_t) -> [pid_t] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-P", String(pid)]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return [] }
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    proc.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
      .split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
      .compactMap { pid_t($0) }
      .filter { $0 > 1 }
  }

  /// SIGKILL the process and all its descendants, deepest first so a parent can't observe a child's
  /// death and respawn before it is itself killed.
  static func killTree(_ pid: pid_t) {
    guard pid > 1 else { return }
    for child in descendants(of: pid, children: childPids).reversed() {
      kill(child, SIGKILL)
    }
    kill(pid, SIGKILL)
  }
}
