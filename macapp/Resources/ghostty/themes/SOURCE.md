# Ghostty bundled theme collection

These theme files are vendored from the iTerm2-Color-Schemes project
(https://github.com/mbadolato/iTerm2-Color-Schemes), the collection Ghostty itself bundles
(https://github.com/ghostty-org/ghostty), distributed under the MIT License (see LICENSE file in this
directory).

**Vendored from** `mbadolato/iTerm2-Color-Schemes@452b0ba35405b07833008c2d01441f6cb41136d1`
(2026-11-20), `ghostty/` subdirectory (#736; the first 116 came from `0173c3cc` on 2026-08-04, and
every one of those still upstream was re-taken from this commit). `CHECKSUMS` in this directory pins
the exact bytes, and `ThemeServiceTests.testBundledThemeChecksumsMatch` recomputes and compares them —
so a future refresh is a real diff against upstream rather than a guess. Structural tests alone cannot
catch byte drift: an upstream colour tweak stays palette-complete and still clears every contrast
floor.

## Which themes are here

`ThemeCatalog.bundledThemes` in `Packages/DesignSystem/Sources/DesignSystem/ThemeCatalog.swift` is
the **single source of truth**: every theme in this directory, listed once with its side (light or
dark) fixed. `ThemeCatalog.families` is the curated presets that pair one light theme with one dark
theme; most themes belong to no family.

There is deliberately no list mirrored here. `ThemeServiceTests` pins the catalog to the files as
exact set equality, which means **adding a theme file without listing it fails the test suite** — as
does listing a name with no file — and checks every fixed side against the file's background.

## Inclusion criteria

Every upstream theme ships, in whichever appearance it comes in, unless one of these leaves it out:

1. **The contrast floors.** It must clear every floor in `SwitcherThemeSweepTests` (rail text,
   indicators, all 12 monogram tiles, the unread badge, the status colours, the PR number pill), which
   sweeps every file in this directory. A new theme must also keep the rail's Liquid Glass and its name
   text at the 4.5:1 target: the sweep caps how many themes fall back to an opaque fill or land in the
   4.0–4.5 band, and those caps hold only the four themes that were there before #736. The update
   pill's dimmed state (`UpdateAvailableButtonTests`) is swept over every theme too, and counts as a
   floor. The script keeps the two apart: `FLOOR_FAILURES` failed a per-theme floor, and
   `CAP_OVERFLOW` cleared every one but would push the sweep past its caps.
2. **No duplicate palettes.** A theme whose background, foreground and 16 palette colours are each
   within 3 of another's on every 0–255 channel is the same palette. The name already shipped is kept,
   then the first in alphabetical order.
3. **No other terminal product's brand.** A theme named for another terminal product, or labelled as
   that product's built-in look, is its brand identity in the category Workroom is in, so it stays
   out. (This is why no `Muxy` theme is here — and it is the same reason the `Workroom` pair below
   is ours to ship.) Stock themes with generic names stay in (`Pro`, `Homebrew` and `Man Page` began
   as Terminal.app profiles), as do Apple's palettes (`Apple System Colors`, `Apple Classic`). Themes
   named for editors, tools and services people use alongside a terminal stay in, as `GitHub`,
   `Xcode`, `Cursor` and `Claude` always have.

There is no longer a rule that a theme must come with a designed partner in the other appearance
(#733): the light and dark themes are chosen apart, and families are presets on top.

A theme name must also survive `theme = "<name>"` in the generated ghostty config unchanged: no
quote, newline, slash or backslash, and no comma, `=` or colon, which ghostty's `Theme.parseCLI`
reads as a light/dark pair. That leaves out `Analog Heartbeat: Phosphor`, `Neon Raincheck: After
Hours` and `Paper Crane: Midnight Ink`. `ThemeCatalogTests` checks every bundled name.

## How the import was done

`macapp/Scripts/vendor-ghostty-themes.py` holds the exclusion lists and runs each step; its header
is the procedure. In short:

1. Sparse-clone upstream's `ghostty/` at the commit into a new, empty directory. The checkout is
   untrusted data: the script reads its files as text and runs nothing from it.
2. `python3 -I macapp/Scripts/vendor-ghostty-themes.py stage <checkout>/ghostty` copies every
   candidate that passes the rules above into this directory (and the themes kept locally, below,
   stay as they are), and prints what it left out and why.
3. `make app-test APP_TEST_FLAGS="-only-testing:WorkroomAppTests/SwitcherThemeSweepTests
   -only-testing:WorkroomAppTests/UpdateAvailableButtonTests" > sweep.log 2>&1` (serial, so the log
   holds every failure), then `... floor-failures sweep.log` names every theme a floor failed. Those
   go in the script's `FLOOR_FAILURES` (or `CAP_OVERFLOW`, when only a cap's list names it), and
   steps 2 and 3 repeat until the sweep is green.
4. `... catalog` prints the `bundledThemes` entries with each side worked out from the background,
   and `... checksums` rewrites `CHECKSUMS`.
5. New families are added to `ThemeCatalog.families` by hand (below).

At this commit: 913 upstream themes. 854 ship (207 light, 647 dark), up from 116: 851 upstream
names, plus `Workroom`, `Workroom Light` and `Zenbones Light`. Left out: 16 that fail a per-theme
floor and 15 more held out by the sweep's caps (both listed in the script), 21 for brands and 7 as
duplicates (both below), and the 3 names above.

### Left out as another terminal product's brand

- Terminal.app: `Terminal Basic`, `Terminal Basic Dark`
- iTerm2, and its own presets, which it labels Builtin: `Builtin Dark`, `Builtin Light`, `Builtin
  Pastel Dark`, `Builtin Tango Dark`, `Builtin Tango Light`, `iTerm2 Dark Background`, `iTerm2
  Default`, `iTerm2 Light Background`, `iTerm2 Pastel Dark Background`, `iTerm2 Smoooooth`, `iTerm2
  Tango Dark`, `iTerm2 Tango Light` (the `iTerm2 Solarized` pair is Solarized, not iTerm2's look)
- Ghostty: `Ghostty Default Style Dark`
- Hyper: `Hyper`
- kitty: `Kitty Default`, `Kitty Low Contrast`
- Termius: `Termius Dark`, `Termius Light`
- WezTerm: `Wez`

### Left out as duplicate palettes

| Left out | Same palette as |
| --- | --- |
| `Dark+` | `Dark Modern` |
| `Merino Dark` | `GitHub Dark Default` |
| `SeedFlip Voltage` | `SeedFlip Ember` |
| `Solarized Osaka Night` | `TokyoNight Night` |
| `Thermal Receipt` | `Redacted` |
| `TokyoNight` | `TokyoNight Night` |
| `Zenbones` | `Zenbones Light` |

### Kept locally, not from the pinned commit

- `Workroom` and `Workroom Light` are authored within this repository (see below).
- `Catppuccin Latte` and `Catppuccin Mocha` match neither this commit's bytes nor `0173c3cc`'s. They
  are kept as they shipped, so the Catppuccin family looks the same after the import.
- `Zenbones Light` was removed upstream as identical to `Zenbones`. It is kept under its name, so
  the Zenbones family and anyone's stored setting still resolve, and `Zenbones` is left out as its
  duplicate.

## Families

A family pairs an upstream light theme and dark theme that were designed together: the same name
with Light/Dark (or Day/Night and the like), both bundled, checked by hand for a shared palette
structure and the correct sides. `ThemeCatalogTests` pins the sides, unique names, and the order:
`Workroom` first, then A→Z.

#736 added 48: Adwaita, AlxPro, Analyzed, Bauhaus, Callie, Code 2026, datum, Everforest Hard, GitHub
Colorblind, Grok, Gruvbox Hard, Havn, iglass, Karasu, Karma Dimmed, Karma High Contrast, Lit Cell, 16
Lumina pairs (Aurora, Canopy, Cherenkov, Dusk, Ember, Espresso, Harbor, Lagoon, Nebula, Olive, Oxblood,
Parchment, Polaire, Quartz, Rayleigh, Vitrail), Modus Deuteranopia, Modus Tinted, Modus Tritanopia,
One Double, OpenCode, Pierre, Serendipity, Tailwind, Vercel, Warm Burnout, Wild Charm, Zacess, Zacess
Deep Contrast, Zacess High Contrast and Zacess Warm.

Not made families: `Sumi Ink` and `Sumi Linen` (three Sumi variants with different palettes, not a
pair), `Pro` and `Pro Light` (Terminal.app's Pro profile and a separate light theme), `Dark 2026` and
`Light 2026` (palettes too far apart to read as one design), and pairs that lost a member to the
floors (`Isocon`, `Poimandres White`, `Violet Dark`) or to the duplicate rule (`Merino Dark`).

## Provenance note

The `Workroom` / `Workroom Light` family is authored within this repository and is not sourced from
upstream. Both files are listed in `CHECKSUMS` alongside the vendored ones so the manifest covers the
whole directory, but they are ours and will never appear in an upstream diff.
