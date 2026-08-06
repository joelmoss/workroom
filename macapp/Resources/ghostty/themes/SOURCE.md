# Ghostty bundled theme collection

These theme files are sourced from Ghostty's bundled theme collection (https://github.com/ghostty-org/ghostty), which itself vendors the iTerm2-Color-Schemes project (https://github.com/mbadolato/iTerm2-Color-Schemes), distributed under the MIT License (see LICENSE file in this directory).

**Vendored from** `mbadolato/iTerm2-Color-Schemes@0173c3cc154aab5d43b03241286d32372a87dec6`
(2026-08-04), `ghostty/` subdirectory. `CHECKSUMS` in this directory pins the exact bytes, and
`ThemeServiceTests.testBundledThemeChecksumsMatch` recomputes and compares them — so a future refresh
is a real diff against upstream rather than a guess. Structural tests alone cannot catch byte drift:
an upstream colour tweak stays palette-complete and still clears every contrast floor.

## Which themes are here

`ThemeService.families` in `WorkroomApp/Core/ThemeService.swift` is the **single source of truth** —
it declares every curated family and the dark/light file each variant maps to, in the picker's
display order.

There is deliberately no list mirrored here. An unenforced prose copy of that array drifts, and every
file in this directory belongs to exactly one family, so a list would carry no information the array
doesn't. `ThemeServiceTests` pins that correspondence as exact set equality, which means **adding a
theme file without registering it fails the test suite** — as does registering a name with no file.

## Inclusion criteria

A theme family ships only if all of these hold:

1. A designed **dark and light** variant both exist (issue #36 — the picker's guarantee is that any
   choice works in both appearances).
2. It clears every contrast floor in `SwitcherThemeSweepTests` (rail text, indicators, all 12
   monogram tiles, the unread badge).
3. Its palette is **distinct** — not merely a lighter or darker shade of a family already here.
4. It serves a real user: a tool or editor people actually use, a widely-known scheme, or an
   accessibility need.
5. It is not another product's brand identity. (This is why no `Muxy` theme is here — and it is the
   same reason the `Workroom` pair below is ours to ship.)

## Provenance note

The `Workroom` / `Workroom Light` family is authored within this repository and is not sourced from
upstream. Both files are listed in `CHECKSUMS` alongside the vendored ones so the manifest covers the
whole directory, but they are ours and will never appear in an upstream diff.
