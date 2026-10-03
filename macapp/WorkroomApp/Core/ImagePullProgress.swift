import Foundation

/// How far a container runtime's image pull has got (#309), read from what its CLI prints without
/// a terminal, as the app runs it. Measured: Docker (29) prints each layer's state on a line of its
/// own, `<layer>: Pulling fs layer`, `… Download complete`, `… Pull complete`, `… Already exists`,
/// and no byte counts, so its progress is the layers done of those seen. Apple's `container` (1.5.0)
/// prints `[<step>/<steps>] <what> <percent>% …`, so its progress is its step's share plus its
/// percent of that.
struct ImagePullProgress: Sendable {
  private var layers: Set<String> = []
  private var done: Set<String> = []
  private var stepped: Double?
  private var pending = ""

  /// The fraction done, 0 to 1, or nil before anything says how far.
  var fraction: Double? {
    if let stepped { return stepped }
    guard !layers.isEmpty else { return nil }
    return Double(done.count) / Double(layers.count)
  }

  /// Takes a piece of output, which may end mid-line.
  mutating func read(_ text: String) {
    pending += text
    // `\r` too: a progress bar redraws its line that way.
    var lines = pending.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }
    pending = String(lines.removeLast())
    for line in lines { take(String(line)) }
  }

  private mutating func take(_ line: String) {
    if let step = Self.appleStep(line) {
      stepped = step
      return
    }
    guard let colon = line.firstIndex(of: ":") else { return }
    let layer = String(line[..<colon])
    // A layer ID is 12 hex digits; a "Digest:" or "<tag>: Pulling from" line is not one.
    guard layer.count == 12, layer.allSatisfy(\.isHexDigit) else { return }
    let state = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    layers.insert(layer)
    if state == "Pull complete" || state == "Already exists" { done.insert(layer) }
  }

  /// `[2/3] Unpacking image … 40% …` → (1 + 0.4) / 3.
  private static func appleStep(_ line: String) -> Double? {
    guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
    let parts = line[line.index(after: line.startIndex)..<close].split(separator: "/")
    guard parts.count == 2, let step = Double(parts[0]), let steps = Double(parts[1]), steps > 0,
      step >= 1, step <= steps
    else { return nil }
    let percent = line[close...].split(separator: " ").first { $0.hasSuffix("%") }
      .flatMap { Double($0.dropLast()) }
    return min(1, ((step - 1) + (percent ?? 0) / 100) / steps)
  }
}
