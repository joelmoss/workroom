import AppKit

/// A workroom's identity mark for the ⌥Tab rail (issue #132): a colour and a monogram, both derived,
/// neither stored.
///
/// The point is **recognition before reading**. ⌘Tab works because app icons are stable and distinctive;
/// a screenshot of a terminal is neither — it changes every time and looks like every other terminal.
/// So a workroom gets a mark it keeps for the life of the workroom, and you learn "the teal AR one" the
/// same way you learn an app icon.
struct SwitcherMark: Equatable {
  /// One or two characters. Derived from the **displayed** name, so it matches what you read on the card.
  let monogram: String
  /// Which of `hueCount` hues. Derived from the **stable** name, so a relabel (issue #41) changes the
  /// letters without moving the colour — the thing you actually recognise stays put.
  let hue: Int

  /// Number of distinct hues. **12, not 6.** With six buckets and four open workrooms a collision is
  /// more likely than not — measured live: two of four tiles came out the same colour. Twelve keeps
  /// neighbouring hues clearly apart (30° of the wheel) while making a clash uncommon.
  static let hueCount = 12

  init(displayName: String, stableKey: String) {
    monogram = Self.monogram(for: displayName)
    hue = Self.hue(for: stableKey)
  }

  /// Direct construction, for `disambiguate` reassigning a hue without re-deriving the monogram.
  init(monogram: String, hue: Int) {
    self.monogram = monogram
    self.hue = hue
  }

  /// Two characters that actually *distinguish* the name.
  ///
  /// Tuned for what Workroom generates: `namegen` produces adjective-noun pairs like
  /// `partitioned-crescent`, where initials ("PC") carry far more than the first two letters ("PA").
  ///
  /// But plain initials repeat the mistake D12 fixed for titles. `uitest-room`, `uitest-room-2` and
  /// `uitest-room-3` all reduce to "UR" — four identical tiles, which is worse than no tile at all. So a
  /// **trailing number is always kept**, because when a name ends in one that digit is the whole
  /// difference: "uitest-room-2" → "R2".
  static func monogram(for name: String) -> String {
    let separators = CharacterSet(charactersIn: "-_. /")
    let words = name.components(separatedBy: separators).filter { !$0.isEmpty }
    guard let first = words.first else { return "?" }

    // A trailing number is the distinguishing part — pair it with the initial of the word before it.
    if words.count >= 2, let last = words.last, last.allSatisfy(\.isNumber) {
      let stem = words.count >= 3 ? words[words.count - 2] : first
      return (String(stem.prefix(1)) + String(last.suffix(1))).uppercased()
    }
    if words.count >= 2, let second = words.dropFirst().first(where: { $0.first != nil }) {
      return (String(first.prefix(1)) + String(second.prefix(1))).uppercased()
    }
    return String(first.prefix(2)).uppercased()
  }

  /// The tile colour for a hue bucket.
  ///
  /// Deliberately **not** `ThemeTokens.legible`, which walks a colour toward the foreground until it
  /// clears a contrast floor. That is right for text and wrong here: on a light theme it walked every
  /// insufficiently-contrasty hue to near-black, so every tile collapsed into identical charcoal and the
  /// mark stopped marking anything — observed live before this existed.
  ///
  /// So hue is treated as identity and never adjusted; only saturation and brightness move, until the
  /// tile clears its floor against this theme's panel.
  static func tileColor(hue index: Int, tokens: ThemeTokens) -> NSColor {
    // Anchored on the theme's accent hue and spaced evenly around the wheel from there, so the marks
    // belong to the theme without being limited to the six ANSI slots — and a greyscale accent still
    // yields twelve usable angles.
    let accent = tokens.nsAccent.usingColorSpace(.sRGB)
    let anchor = (accent?.saturationComponent ?? 0) > 0.15 ? (accent?.hueComponent ?? 0) : 0
    let hueAngle = (anchor + CGFloat(index % hueCount) / CGFloat(hueCount)).truncatingRemainder(
      dividingBy: 1)
    let dark = tokens.colorScheme == .dark
    let saturation: CGFloat = dark ? 0.55 : 0.62
    // Step brightness until the tile clears its floor against the card, rather than trusting one
    // constant: a mid-brightness colour of ANY hue sits near 2:1 against a near-white panel, which is
    // exactly what measured wrong. Hue and saturation are held fixed, so the tile darkens (or lightens
    // on a dark theme) without drifting toward grey.
    var brightness: CGFloat = dark ? 0.72 : 0.62
    let step: CGFloat = dark ? 0.03 : -0.03
    var candidate = NSColor(hue: hueAngle, saturation: saturation, brightness: brightness, alpha: 1)
    var steps = 0
    while ThemeTokens.contrastRatio(candidate, tokens.nsPanel) < Self.tileContrastFloor,
      brightness > 0.12, brightness < 0.98, steps < 40
    {
      brightness += step
      steps += 1
      candidate = NSColor(hue: hueAngle, saturation: saturation, brightness: brightness, alpha: 1)
    }
    return candidate
  }

  /// The tile's contrast floor against the card. 3:1 — the tile is a large solid shape, not text.
  static let tileContrastFloor: CGFloat = 3.0

  /// Rotate hues so that **no two marks on one rail share a colour**.
  ///
  /// A stable per-name hue is right in isolation and not sufficient in practice: with 12 buckets and 4
  /// open workrooms a clash happens ~43% of the time, and it happened in both live checks. Since the
  /// rail's job is telling *these* items apart, uniqueness is enforced over the visible set — a colliding
  /// mark steps to the next free hue. Deterministic for a given ordered list, and a no-op once there are
  /// more items than hues.
  ///
  /// Earlier items keep their natural hue, so the most-recent workrooms — the ones you switch between
  /// most and have therefore learned — are the ones that never move.
  static func disambiguate(_ hues: [Int]) -> [Int] {
    var taken: Set<Int> = []
    return hues.map { hue in
      var candidate = hue
      var steps = 0
      while taken.contains(candidate), steps < hueCount {
        candidate = (candidate + 1) % hueCount
        steps += 1
      }
      taken.insert(candidate)
      return candidate
    }
  }

  /// A stable hue bucket for a name.
  ///
  /// **Not `hashValue`.** Swift seeds string hashing per process, so `hashValue` would give a workroom a
  /// different colour on every launch — which destroys the entire premise of a mark you learn. This is
  /// FNV-1a over the UTF-8 bytes: same input, same output, forever, on every machine.
  static func hue(for stableKey: String) -> Int {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in stableKey.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return Int(hash % UInt64(hueCount))
  }
}

/// What a ⌃Tab pane card draws in its well — a small graphic made of the pane's own data, so the *shape*
/// says what kind of thing this is before any text is read.
///
/// A screenshot would in principle have distinguished these best (a diff really does look unlike a
/// terminal), but not at any size that fits a switcher rail. These are drawn, so they stay legible at
/// 52pt and cost nothing to produce.
enum PaneMiniature: Equatable {
  /// A prompt chevron, with a filled pip while a command is running.
  case terminal(running: Bool)
  /// Stacked add/remove bars whose composition follows the change kind. Per-file line counts are NOT
  /// available (`ChangedFile` carries no insertions/deletions), so this encodes *kind*, not magnitude —
  /// an added file reads all-add, a deletion all-remove, a modification split.
  case diff(ChangedFile.Change)
  /// Abstract text lines — a page of prose or code, with no attempt to render the real content.
  case file
  /// A chain of commit dots.
  case changeset

  init(content: TabContent, isRunning: Bool) {
    switch content {
    case .terminal: self = .terminal(running: isRunning)
    case .diff(let descriptor): self = .diff(descriptor.change)
    case .file: self = .file
    case .changeset: self = .changeset
    }
  }

  /// The words under the name, naming the kind so the shape is never the *only* signal — a shape alone
  /// is not accessible, and an unfamiliar shape is not yet learned.
  ///
  /// A terminal is the exception: its title is already its shell/command, so "Terminal" under
  /// "Terminal 3" says the same thing twice. It reports its state instead, which is the thing you
  /// actually want mid-switch.
  var label: String {
    switch self {
    case .terminal(let running): running ? "Running" : "Idle"
    case .diff(let change): change.rawValue.capitalized
    case .file: "File"
    case .changeset: "Commit"
    }
  }
}
