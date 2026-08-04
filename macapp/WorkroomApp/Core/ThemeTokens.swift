import AppKit
import SwiftUI

/// A snapshot of every derived UI colour for the active theme, computed once per theme change from
/// the resolved palette (see `ThemeService.applyActiveTheme`). One bg + fg + palette drives the
/// whole chrome: foreground alpha variants give muted/dim text and the faint surface/border/hover
/// fills, the accent comes from `palette[4]` (each theme's signature colour — see issue #36 review).
///
/// SwiftUI views read these via `@Environment(ThemeService.self).tokens.*`, which tracks the
/// dependency so they repaint on a theme change. AppKit / non-SwiftUI sites (terminal focus border,
/// dim scrim) read `ThemeService.shared.tokens` and refresh on `.themeDidChange`.
///
/// Derivation mirrors muxy's `MuxyTheme.Snapshot`. When no theme resolves (first launch before a
/// theme is applied, or a deleted file), the fallbacks are the macOS system colours, so the chrome
/// degrades to the pre-theming native look rather than crashing.
struct ThemeTokens {
  // Bases.
  let nsBg: NSColor
  let nsFg: NSColor
  let bg: Color
  let fg: Color
  // The chrome panel surrounding the terminals (tab bar, pane gutters, title bar): the theme
  // background nudged slightly toward the foreground, so the panel reads as a distinct surface from
  // the terminals themselves (subtly lighter in dark themes, darker in light) without breaking the
  // overall blend.
  let panel: Color
  let nsPanel: NSColor
  let fgMuted: Color  // fg @ 0.65 — secondary text
  let fgDim: Color  // fg @ 0.40 — tertiary text / placeholders
  let surface: Color  // fg @ 0.08 — raised row / panel fill
  let border: Color  // fg @ 0.12 — hairline dividers
  let hover: Color  // fg @ 0.06 — hover wash
  let tabActive: Color  // fg @ 0.16 — selected tab fill: distinctly stronger than hover/surface
  // Opaque changed-file row fills (issue #93). Baked solid (panel blended toward fg / accent) rather
  // than a translucent wash, so a row's highlight and the hover toolbar painted over it are the exact
  // same colour — a wash double-composites over the toolbar's own backing and never matches.
  let rowHover: Color  // panel + 6% fg, opaque
  let rowSelection: Color  // panel + 22% accent, opaque

  // Accent (palette[4]).
  let accent: Color
  let nsAccent: NSColor
  let accentSoft: Color  // accent @ 0.10 — selection wash
  let accentForeground: Color  // black/white for legibility on the accent
  let warning: Color  // palette[3] (yellow)
  // palette[1] (red) — run-command failure (icon + toast); a distinct token from `warning`.
  let failure: Color
  // A VCS conflict needs its OWN token: `warning` is already the modified/renamed colour and
  // `diffRemoveFg` is deletion's, so reusing either makes "needs resolving" read as "changed" or
  // "removed" (the state the Changes panel used to conflate). Orange — the hue
  // `DiffViewer`/`ChangesetDetailView` already use for conflicts — has no ANSI slot, so it's mixed
  // from the palette's red + yellow to stay theme-derived like every other token.
  let conflict: Color

  // Diff / VCS semantics (palette green/red/cyan).
  let diffAddFg: Color
  let diffRemoveFg: Color
  // NSColor forms of the two diff foregrounds. Present so a contrast check never has to round-trip a
  // SwiftUI `Color` back through `NSColor(_:)`: that yields a lazily-resolved, SwiftUI-backed NSColor
  // whose `usingColorSpace` returns nil outside a view update, and re-wrapping THAT in a `Color`
  // crashes in `Color._apply` during layout. Always start from the source NSColor.
  let nsDiffAddFg: NSColor
  let nsDiffRemoveFg: NSColor
  let diffHunkFg: Color
  let diffAddBg: Color
  let diffRemoveBg: Color
  let diffHunkBg: Color
  // Intra-line (character-level) change emphasis: a deeper tint drawn behind just the characters
  // that changed within a replaced line, over the flat `diffAddBg`/`diffRemoveBg` line tint.
  let diffAddEmphasisBg: Color
  let diffRemoveEmphasisBg: Color

  // Syntax highlighting (tree-sitter diff highlighting, phase 1). A small sub-palette derived from
  // the ANSI `palette` — the same source as `diffAddFg`/etc., so highlight colours match the
  // terminal's. `syntaxColor(forCapture:onAddedBackground:)` resolves a tree-sitter capture name to
  // a colour; `nsAddBackgroundOpaque` is the opaque colour an added line composites to (theme bg +
  // the green add tint), used by the contrast guard so token colours stay legible on the tint.
  let syntaxByCategory: [SyntaxCategory: NSColor]
  let nsAddBackgroundOpaque: NSColor

  /// The coarse grouping a tree-sitter highlight capture maps to. We colour by category (≈12) rather
  /// than per-capture (hundreds, grammar-specific) — `category(for:)` collapses any capture name.
  enum SyntaxCategory: String, CaseIterable, Sendable {
    case keyword, function, type, namespace, constant, number, string, comment, variable, property,
      tag, attribute, punctuation, escape
  }

  // Focused-pane border + unfocused-pane scrim (issue #23 follow-up).
  let focused: Color
  let terminalDim: Color

  // Workroom-split group fills (issue #110): the raised card behind a split member. The focused member
  // is tinted by the accent so focus reads as a colour, not just a border; the rest take a faint neutral
  // lift. Dedicated tokens (not the `hover`/`accentSoft` washes) so the group treatment can be tuned
  // without dragging hover/selection along with it.
  let splitGroupFill: Color  // fg @ 0.06 — unfocused member's raised fill
  let splitGroupFocusedFill: Color  // accent @ 0.10 — focused member's accent-tinted fill

  let colorScheme: ColorScheme

  /// Resolve a parsed theme (or fall back to system colours) into the full token set.
  init(
    preview: ThemePreview?,
    fallbackBackground: NSColor = .textBackgroundColor,
    fallbackForeground: NSColor = .textColor
  ) {
    let palette = preview?.palette ?? []
    func p(_ index: Int) -> NSColor? { palette.indices.contains(index) ? palette[index] : nil }

    let bgColor = preview?.background ?? fallbackBackground
    let fgColor = preview?.foreground ?? fallbackForeground
    let accentColor = p(4) ?? .controlAccentColor

    nsBg = bgColor
    nsFg = fgColor
    bg = Color(nsColor: bgColor)
    fg = Color(nsColor: fgColor)
    let panelColor =
      bgColor.usingColorSpace(.sRGB)?
      .blended(withFraction: 0.055, of: fgColor.usingColorSpace(.sRGB) ?? fgColor) ?? bgColor
    nsPanel = panelColor
    panel = Color(nsColor: panelColor)
    fgMuted = Color(nsColor: fgColor.withAlphaComponent(0.65))
    fgDim = Color(nsColor: fgColor.withAlphaComponent(0.40))
    surface = Color(nsColor: fgColor.withAlphaComponent(0.08))
    border = Color(nsColor: fgColor.withAlphaComponent(0.12))
    hover = Color(nsColor: fgColor.withAlphaComponent(0.06))
    tabActive = Color(nsColor: fgColor.withAlphaComponent(0.16))
    let fgSRGB = fgColor.usingColorSpace(.sRGB) ?? fgColor
    let accentSRGB = accentColor.usingColorSpace(.sRGB) ?? accentColor
    rowHover = Color(nsColor: panelColor.blended(withFraction: 0.06, of: fgSRGB) ?? panelColor)
    rowSelection = Color(
      nsColor: panelColor.blended(withFraction: 0.22, of: accentSRGB) ?? panelColor)

    accent = Color(nsColor: accentColor)
    nsAccent = accentColor
    accentSoft = Color(nsColor: accentColor.withAlphaComponent(0.10))
    accentForeground = Color(nsColor: Self.contrastingForeground(for: accentColor))
    warning = Color(nsColor: p(3) ?? .systemYellow)
    // ANSI colour 1 is red — the run-failure signal (chip + workroom dot + toast all share it). Same
    // palette slot as `diffRemoveFg`'s red, but a distinct semantic token so the two can't drift.
    failure = Color(nsColor: p(1) ?? .systemRed)
    // Orange = the palette's red blended halfway toward its yellow (no ANSI orange exists); falls
    // back to the system orange when a theme defines no palette.
    let conflictColor: NSColor = {
      guard let red = p(1)?.usingColorSpace(.sRGB), let yellow = p(3)?.usingColorSpace(.sRGB)
      else { return .systemOrange }
      return red.blended(withFraction: 0.5, of: yellow) ?? .systemOrange
    }()
    conflict = Color(nsColor: conflictColor)

    let addColor = p(2) ?? .systemGreen
    let removeColor = p(1) ?? .systemRed
    let hunkColor = p(6) ?? accentColor
    diffAddFg = Color(nsColor: addColor)
    diffRemoveFg = Color(nsColor: removeColor)
    nsDiffAddFg = addColor
    nsDiffRemoveFg = removeColor
    diffHunkFg = Color(nsColor: hunkColor)
    diffAddBg = Color(nsColor: addColor.withAlphaComponent(0.16))
    diffRemoveBg = Color(nsColor: removeColor.withAlphaComponent(0.16))
    diffHunkBg = Color(nsColor: hunkColor.withAlphaComponent(0.10))
    diffAddEmphasisBg = Color(nsColor: addColor.withAlphaComponent(0.40))
    diffRemoveEmphasisBg = Color(nsColor: removeColor.withAlphaComponent(0.40))

    // The opaque colour an added line's row composites to (theme bg + the 16% green tint) — the
    // background the contrast guard checks token colours against.
    nsAddBackgroundOpaque =
      bgColor.usingColorSpace(.sRGB)?
      .blended(withFraction: 0.16, of: addColor.usingColorSpace(.sRGB) ?? addColor) ?? bgColor

    // Capture → colour, derived from the ANSI palette so highlight colours track the terminal's
    // signature hues (and recompute on theme change with everything else). Falls back to system
    // colours when a theme defines no palette.
    let comment = fgColor.withAlphaComponent(0.45)
    syntaxByCategory = [
      .keyword: p(5) ?? .systemPurple,  // magenta
      .function: p(4) ?? .systemBlue,
      .type: p(3) ?? .systemYellow,
      .namespace: p(3) ?? .systemYellow,
      .constant: p(6) ?? .systemTeal,  // cyan
      .number: p(6) ?? .systemTeal,
      .string: p(2) ?? .systemGreen,
      .comment: comment,
      .variable: fgColor,
      .property: p(4) ?? .systemBlue,
      .tag: p(1) ?? .systemRed,
      .attribute: p(3) ?? .systemYellow,
      .punctuation: fgColor.withAlphaComponent(0.65),
      .escape: p(6) ?? .systemTeal,
    ]

    // The unfocused-pane scrim is the terminal's own background, so it's invisible *over* the
    // background and only washes the pane's text toward it (issue #23 follow-up). The focus border is
    // the SAME hairline as an unfocused pane (`border`, fg @ 0.12), just a little darker — so the
    // focused pane reads as "the focused one" without a heavy extra ring around it.
    terminalDim = Color(nsColor: bgColor)
    focused = Color(nsColor: fgColor.withAlphaComponent(0.3))
    splitGroupFill = Color(nsColor: fgColor.withAlphaComponent(0.06))
    splitGroupFocusedFill = Color(nsColor: accentColor.withAlphaComponent(0.10))

    // `perceivedBrightness`, not `luminance`: this is "does the background look light", which is the
    // encoded value. WCAG luminance is not perceptual — mid-grey linearizes to 0.216, so a threshold of
    // 0.5 against it would classify visibly light backgrounds as dark.
    colorScheme = Self.perceivedBrightness(of: bgColor) > 0.5 ? .light : .dark
  }

  /// WCAG relative luminance, 0…1 — sRGB components **linearized** first, then weighted (Rec. 709).
  ///
  /// The linearization is the whole point, and this function did not do it until it was measured against
  /// the bundled themes. Weighting the gamma-encoded components directly inflates every dark colour
  /// (`#2E3440` reads 0.20 instead of 0.033), which collapses the ratio between a dark background and
  /// light text: the rail's 13pt name measured under 4.5:1 for **43 of 56** bundled themes by that
  /// formula and for **4** by this one, and the switcher's "this theme can't be read, drop the material"
  /// fallback was firing for 38 themes that are perfectly legible. Every floor in the app is stated in
  /// WCAG terms, so the metric has to actually be WCAG.
  ///
  /// For "is this colour light or dark to look at" use `perceivedBrightness` instead — that question is
  /// about the encoded value, not about contrast.
  static func luminance(of color: NSColor) -> CGFloat {
    guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
    func linear(_ component: CGFloat) -> CGFloat {
      component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent)
      + 0.0722 * linear(srgb.blueComponent)
  }

  /// The gamma-encoded, non-linearized weighting — a proxy for *apparent* brightness, not contrast.
  ///
  /// Kept as its own function because light/dark classification genuinely wants this: a theme background
  /// is "light" when it looks light, and WCAG luminance is deliberately not perceptual (mid-grey
  /// `#808080` is 0.216 linearized, which would read as a dark background). This is exactly the formula
  /// `luminance` used to be, so `colorScheme` behaves as it always has.
  static func perceivedBrightness(of color: NSColor) -> CGFloat {
    guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
    return 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
  }

  /// Black or white on a fill — whichever actually measures better against it.
  ///
  /// Chosen by measurement rather than by a brightness threshold, which is what this used to do
  /// (`luminance > 0.6 ? .black : .white`) and which fails in a whole band: a tile at 0.54 apparent
  /// brightness took white at 1.77:1 where black gives 11.8:1 — a real, illegible monogram, found on a
  /// dark-theme fixture. Comparing both ratios has no threshold to get wrong.
  static func contrastingForeground(for color: NSColor) -> NSColor {
    contrastRatio(.black, color) >= contrastRatio(.white, color) ? .black : .white
  }

  // MARK: Syntax highlighting

  /// The colour for a tree-sitter highlight capture, or `nil` (⇒ render in the default foreground).
  /// `onAddedBackground` applies the contrast guard against the green add tint so token colours
  /// don't wash out on added lines; context lines (≈ theme background) use the base colour.
  func syntaxColor(forCapture capture: String, onAddedBackground: Bool = false) -> Color? {
    guard let category = Self.category(for: capture), let base = syntaxByCategory[category] else {
      return nil
    }
    guard onAddedBackground else { return Color(nsColor: base) }
    return Color(nsColor: Self.legible(base, on: nsAddBackgroundOpaque, towards: nsFg))
  }

  /// Collapse any tree-sitter capture name (e.g. `function.method.builtin`, `string.special.path`)
  /// to a colour category by its leading dotted component. Unknown captures return `nil` (default
  /// foreground). This is the whole capture→colour vocabulary — grammar-specific leaf captures fold
  /// into their family.
  static func category(for capture: String) -> SyntaxCategory? {
    let head = capture.split(separator: ".").first.map(String.init) ?? capture
    switch head {
    case "keyword", "conditional", "repeat", "include", "exception", "define", "storageclass",
      "modifier", "operator":
      // `operator` reads as a keyword-ish accent rather than dim punctuation.
      return head == "operator" ? .punctuation : .keyword
    case "function", "method", "constructor", "call":
      return .function
    case "type", "class", "interface", "enum", "struct":
      return .type
    case "namespace", "module", "package":
      return .namespace
    case "constant", "boolean", "const":
      return .constant
    case "number", "float", "integer":
      return .number
    case "string", "char", "character":
      return .string
    case "comment":
      return .comment
    case "variable", "parameter", "identifier":
      return .variable
    case "property", "field", "member":
      return .property
    case "tag":
      return .tag
    case "attribute", "annotation", "decorator":
      return .attribute
    case "punctuation", "delimiter", "bracket":
      return .punctuation
    case "escape", "regex", "embedded":
      return .escape
    default:
      return nil
    }
  }

  /// Nudge `color` toward `fg` until it has at least a 3:1 WCAG contrast ratio against `bg`, so a
  /// token colour close to the add-tint hue (e.g. a green string on the green add background) stays
  /// readable. Capped iterations; returns the best achieved if the target is unreachable.
  static func legible(_ color: NSColor, on bg: NSColor, towards fg: NSColor, target: CGFloat = 3.0)
    -> NSColor
  {
    guard let srgb = color.usingColorSpace(.sRGB), let fgSrgb = fg.usingColorSpace(.sRGB) else {
      return color
    }
    var current = srgb
    var fraction: CGFloat = 0
    while contrastRatio(current, bg) < target, fraction < 1.0 {
      fraction += 0.2
      current = srgb.blended(withFraction: fraction, of: fgSrgb) ?? srgb
    }
    return current
  }

  /// WCAG relative-luminance contrast ratio between two colours (1…21).
  static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let la = luminance(of: a)
    let lb = luminance(of: b)
    let hi = max(la, lb)
    let lo = min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
  }
}
