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
    func ratio(_ color: NSColor) -> CGFloat { ThemeTokens.contrastRatio(color, tokens.nsPanel) }
    // Search brightness first, then give saturation ground — hue is identity and never moves.
    //
    // Two things this gets right that a single fixed walk did not, both measured rather than reasoned:
    //
    // 1. **Both directions.** The preferred one comes from `colorScheme`, which is derived from the
    //    theme's *background*, while the tile is measured against its *panel*. On a theme where those sit
    //    on opposite sides of mid-grey, a one-way walk moved the tile TOWARD the panel and nothing ever
    //    cleared 3:1.
    // 2. **Saturation is a fallback axis.** A mid-tone card caps how much contrast a saturated colour can
    //    reach at all: against this app's grey card (luminance 0.186) the *best* a 0.62-saturated hue can
    //    do is 2.71:1 at full brightness, because a saturated colour can't get light enough. Desaturating
    //    buys the luminance that brightness alone cannot — a pale blue clears the floor where a vivid one
    //    can't — and it stays visibly a hue, which a walk toward the foreground (`legible`) would not.
    let ladder: [CGFloat] = dark ? [0.55, 0.46, 0.38, 0.34] : [0.62, 0.52, 0.42, 0.34]
    var best: NSColor?
    for saturation in ladder {
      func tile(_ brightness: CGFloat) -> NSColor {
        NSColor(hue: hueAngle, saturation: saturation, brightness: brightness, alpha: 1)
      }
      let start: CGFloat = dark ? 0.72 : 0.62
      let lighter = Array(stride(from: start, through: 0.98, by: 0.03)).map(tile)
      let darker = Array(stride(from: start, through: 0.10, by: -0.03)).map(tile)
      let ordered = dark ? lighter + darker : darker + lighter
      if let clears = ordered.first(where: { ratio($0) >= Self.tileContrastFloor }) {
        return clears
      }
      if let rung = ordered.max(by: { ratio($0) < ratio($1) }),
        ratio(rung) > ratio(best ?? rung) || best == nil
      {
        best = rung
      }
    }
    // Nothing in the ladder clears the floor against this card — take the best available rather than
    // whatever the last walk happened to stop on. `SwitcherRailLayout.Palette.needsOpaqueFill` is the
    // wider guard for a theme this hostile.
    return best ?? NSColor(hue: hueAngle, saturation: ladder[0], brightness: 0.62, alpha: 1)
  }

  /// The tile's contrast floor against the card. 3:1 — the tile is a large solid shape, not text.
  static let tileContrastFloor: CGFloat = 3.0

  /// The monogram's ink: whichever of black/white actually measures better on this tile.
  ///
  /// This existed as its own implementation because `ThemeTokens.contrastingForeground` used to switch on
  /// a brightness threshold (`> 0.6`), which left a tile at 0.54 taking WHITE at 1.77:1 where black gives
  /// 11.8:1 — an illegible monogram, measured on a dark-theme fixture. That helper now measures both
  /// candidates, exactly as this did, so this is a name for the rail's use of it rather than a second
  /// rule. Kept as the call site the rail reads, and as the record of why the threshold went.
  static func ink(on tile: NSColor) -> NSColor {
    ThemeTokens.contrastingForeground(for: tile)
  }

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
