#!/usr/bin/env python3
"""Vendor iTerm2-Color-Schemes' ghostty themes into macapp/Resources/ghostty/themes (#736).

The upstream checkout is untrusted data: this script only reads its files as text, never runs
anything from it. Run with `python3 -I` so nothing next to the checkout can be imported.

  # 1. Fetch upstream into a new, empty directory, at the commit to vendor:
  git clone --filter=blob:none --no-checkout https://github.com/mbadolato/iTerm2-Color-Schemes.git <dir>
  git -C <dir> sparse-checkout set --no-cone /ghostty && git -C <dir> checkout <commit>

  # 2. Stage every candidate that passes the curation rules below into the bundled directory:
  python3 -I macapp/Scripts/vendor-ghostty-themes.py stage <dir>/ghostty

  # 3. Sweep the staged set with the contrast floors (the two classes that assert over every
  #    bundled theme), and record what fails:
  make app-test APP_TEST_FLAGS="-only-testing:WorkroomAppTests/SwitcherThemeSweepTests \
    -only-testing:WorkroomAppTests/UpdateAvailableButtonTests"
  #    (with the output saved: make ... > sweep.log 2>&1)
  python3 -I macapp/Scripts/vendor-ghostty-themes.py floor-failures sweep.log
  #    Add the names it prints to FLOOR_FAILURES below (or CAP_OVERFLOW, for a name only the
  #    fallback or near-miss count lists), then repeat 2 and 3 until it prints none.

  # 4. Write `ThemeCatalog.bundledThemes` (BundledThemes.generated.swift in the DesignSystem
  #    package), with each side worked out from the background, and rewrite CHECKSUMS:
  python3 -I macapp/Scripts/vendor-ghostty-themes.py catalog
  python3 -I macapp/Scripts/vendor-ghostty-themes.py checksums

Then pin the commit in SOURCE.md, and add new families to `ThemeCatalog.families` by hand.
"""

import hashlib
import json
import os
import re
import shutil
import sys

THEMES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "ghostty", "themes")
THEMES = os.path.normpath(THEMES)

# Files in the bundled directory that aren't themes.
NOT_THEMES = {"CHECKSUMS", "LICENSE", "SOURCE.md"}

# Themes whose bundled bytes are kept as they are rather than taken from upstream. See SOURCE.md.
LOCAL = {
    "Workroom",  # ours
    "Workroom Light",  # ours
    "Catppuccin Latte",  # matches no upstream commit's bytes; kept so the family doesn't change
    "Catppuccin Mocha",  # likewise
    "Zenbones Light",  # removed upstream as identical to "Zenbones"; kept so stored settings resolve
}

# Named for another terminal product, or that product's own default look: its brand identity, in
# the category Workroom is in.
BRANDS = {
    "Builtin Dark",  # iTerm2's built-in presets
    "Builtin Light",
    "Builtin Pastel Dark",
    "Builtin Tango Dark",
    "Builtin Tango Light",
    "Ghostty Default Style Dark",
    "Hyper",
    "iTerm2 Dark Background",
    "iTerm2 Default",
    "iTerm2 Light Background",
    "iTerm2 Pastel Dark Background",
    "iTerm2 Smoooooth",
    "iTerm2 Tango Dark",
    "iTerm2 Tango Light",
    "Kitty Default",
    "Kitty Low Contrast",
    "Terminal Basic",  # Terminal.app
    "Terminal Basic Dark",
    "Termius Dark",
    "Termius Light",
    "Wez",  # WezTerm
}

# Duplicates kept under a different name than the one the alphabetical pass keeps, as
# {duplicate to leave out: the theme it duplicates}. Every other duplicate is found by `stage`.
PREFERRED_DUPLICATES = {}

# Themes that failed a per-theme contrast floor in `SwitcherThemeSweepTests` or
# `UpdateAvailableButtonTests` at the pinned commit.
FLOOR_FAILURES = {
    "base16-icy",
    "C64",
    "Crayon Pony Fish",
    "Darkermatrix",
    "Darkmatrix",
    "Fairyfloss",
    "Grass",
    "HaX0R R3D",
    "Hot Dog Stand",
    "Matrix",
    "Ozz's Blizzard",
    "Poimandres White",
    "Pumpkin Spice",  # UpdateAvailableButtonTests: the dimmed pill doesn't recede
    "Royal",
    "Scabos Sand",
    "Shaman",
}

# Themes that clear every per-theme floor but would need the rail's opaque fallback or land in its
# 4.0-4.5 near-miss band, whose counts the sweep caps (at 4 and 6) however big the set grows.
CAP_OVERFLOW = {
    "Alien Blood",  # opaque fallback
    "Batman",  # opaque fallback
    "Cyberpunk Scarlet Protocol",  # opaque fallback
    "Elemental",  # opaque fallback
    "Everforest Light Soft",  # opaque fallback
    "Framer",  # opaque fallback
    "Isocon Dark",  # near miss
    "Isocon Light",  # near miss
    "Lavandula",  # near miss
    "Scarlet Protocol",  # opaque fallback
    "Solarized Dark Patched",  # opaque fallback
    "Treehouse",  # opaque fallback
    "Urple",  # opaque fallback
    "Violet Dark",  # opaque fallback
    "X Oslo",  # near miss
}

# The themes already in the sweep's opaque-fallback and near-miss counts when its caps were set,
# before #736. They clear every per-theme floor, so they stay.
CAP_EXCEPTIONS = {
    "Everforest Light Med",
    "iTerm2 Solarized Dark",
    "iTerm2 Solarized Light",
    "TokyoNight Day",
}

HEX = re.compile(r"^#?[0-9a-fA-F]{6}$")


def parse(path):
    """The theme's background, foreground and 16 palette colours, or None if any is missing."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError):
        return None
    keys, palette = {}, {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key, value = key.strip(), value.strip()
        if key == "palette":
            index, sep, color = value.partition("=")
            if sep and index.strip().isdigit() and HEX.match(color.strip()):
                palette[int(index)] = color.strip().lstrip("#").lower()
        elif HEX.match(value):
            keys[key] = value.lstrip("#").lower()
    if "background" not in keys or "foreground" not in keys or sorted(palette) != list(range(16)):
        return None
    return (keys["background"], keys["foreground"]) + tuple(palette[i] for i in range(16))


def brightness(hex6):
    """`ThemeTokens.perceivedBrightness`: Rec. 709 weights over the sRGB components."""
    r, g, b = (int(hex6[i : i + 2], 16) / 255 for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


# How far apart two palettes can be and still be one palette: every one of the 18 colours within this
# much on each 0-255 channel, which no one can tell apart in a terminal.
DUPLICATE_TOLERANCE = 3


def duplicate_of(signature, seen):
    """The name of a kept theme whose palette is the same as this one's, or None."""
    channels = [int(h[i : i + 2], 16) for h in signature for i in (0, 2, 4)]
    for other, name in seen.items():
        theirs = [int(h[i : i + 2], 16) for h in other for i in (0, 2, 4)]
        if max(abs(a - b) for a, b in zip(channels, theirs)) <= DUPLICATE_TOLERANCE:
            return name
    return None


def side(signature):
    return "light" if brightness(signature[0]) > 0.5 else "dark"


def safe_name(name):
    """A name `ThemeCatalog.sanitizedThemeName` leaves alone, and that ghostty reads as one theme:
    its `Theme.parseCLI` reads any value holding a comma, `=` or colon as a light/dark pair."""
    return not any(c in name for c in '"\n\r/\\,=:') and not name.startswith(".")


def bundled_names():
    return sorted(n for n in os.listdir(THEMES) if n not in NOT_THEMES)


def stage(upstream):
    upstream = os.path.abspath(upstream)
    names = sorted((n for n in os.listdir(upstream) if os.path.isfile(os.path.join(upstream, n))),
                   key=str.casefold)
    before = bundled_names()
    # The kept set's palettes, existing themes first so a duplicate keeps the name already shipped.
    seen = {}
    for name in before:
        if name in LOCAL or name in names:
            sig = parse(os.path.join(THEMES, name) if name in LOCAL else os.path.join(upstream, name))
            if sig:
                seen.setdefault(sig, name)
    report = {"brand": [], "duplicate": {}, "floors": [], "caps": [], "unsafe": [],
              "unparseable": []}
    kept = []
    for name in names:
        if name in LOCAL:
            continue
        sig = parse(os.path.join(upstream, name))
        if name in BRANDS:
            report["brand"].append(name)
        elif not safe_name(name) or any(name.casefold() == k.casefold() and name != k for k in kept):
            report["unsafe"].append(name)
        elif sig is None:
            report["unparseable"].append(name)
        elif name in PREFERRED_DUPLICATES:
            report["duplicate"][name] = PREFERRED_DUPLICATES[name]
        elif name not in before and (twin := duplicate_of(sig, seen)):
            report["duplicate"][name] = twin
        elif name in FLOOR_FAILURES:
            report["floors"].append(name)
        elif name in CAP_OVERFLOW:
            report["caps"].append(name)
        else:
            seen.setdefault(sig, name)
            kept.append(name)
    for name in before:
        if name not in LOCAL:
            os.remove(os.path.join(THEMES, name))
    for name in kept:
        shutil.copyfile(os.path.join(upstream, name), os.path.join(THEMES, name))
    after = bundled_names()
    sides = [side(parse(os.path.join(THEMES, n))) for n in after]
    report["counts"] = {
        "before": len(before), "after": len(after), "light": sides.count("light"),
        "dark": sides.count("dark"), "brand": len(report["brand"]),
        "duplicate": len(report["duplicate"]), "floors": len(report["floors"]),
        "caps": len(report["caps"]),
        "unsafe": len(report["unsafe"]), "unparseable": len(report["unparseable"]),
        "dropped": sorted(set(before) - set(after)),
    }
    json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
    print()


def floor_failures(log):
    """Every staged theme a failing test names, read from the run's console
    output (`make app-test ... > log`): the result bundle's summary keeps only each test's first
    failure. Per-theme assertions read `... - <name>: ...`, and the two count caps list theme names
    as a Swift array."""
    marker = "error: -[WorkroomAppTests."
    with open(log, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    # A serial run prints every failure; the summary's `FAIL` lines (all a parallel run leaves)
    # hold only each test's first.
    failures = [line.split("] : ", 1)[-1] for line in lines if marker in line]
    failures += [line.split("(): ", 1)[-1] for line in lines if line.startswith("  FAIL ")]
    names = set(bundled_names())
    failed = set()
    for text in failures:
        # The longest matching name, so "Nord Light: …" isn't also read as "Nord".
        prefixed = [n for n in names if f" - {n}: " in text]
        if prefixed:
            failed.add(max(prefixed, key=len))
        for listed in re.findall(r'\[("(?:[^"\\]|\\.)*"(?:, "(?:[^"\\]|\\.)*")*)\]', text):
            for quoted in re.findall(r'"((?:[^"\\]|\\.)*)"', listed):
                name = re.sub(r"\\(.)", r"\1", quoted)  # Swift escapes ' in an array's description
                if name in names and name not in CAP_EXCEPTIONS:
                    failed.add(name)
    for name in sorted(failed - LOCAL, key=str.casefold):
        print(name)
    if failed & LOCAL:
        print("local themes failed, fix by hand:", sorted(failed & LOCAL), file=sys.stderr)


GENERATED = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Packages", "DesignSystem", "Sources",
    "DesignSystem", "BundledThemes.generated.swift"))

GENERATED_HEAD = """\
// Generated by `python3 -I macapp/Scripts/vendor-ghostty-themes.py catalog` from the files in
// `Resources/ghostty/themes`. Don't edit it by hand: change the files, then run the script again.

extension ThemeCatalog {
  /// Every theme the app bundles, each listed once with its side fixed. Each name is a file in
  /// `Resources/ghostty/themes`, and each side comes from that file's background.
  /// `ThemeServiceTests` pins the list to the files as exact set equality and checks every side
  /// against the file's background, so a theme file added, removed or changed without running the
  /// script again fails the tests.
  ///
  /// Not derived from `families`: a derived list would make "every family's themes are bundled on
  /// their sides" true by construction, and themes that belong to no family must be able to appear
  /// here.
  public static let bundledThemes: [BundledTheme] = [
"""


def catalog():
    """Write `ThemeCatalog.bundledThemes`, with each side worked out from the background."""
    lines = [GENERATED_HEAD]
    for name in sorted(bundled_names(), key=str.casefold):
        sig = parse(os.path.join(THEMES, name))
        if sig is None:
            sys.exit(f"{name}: doesn't parse, so it has no side")
        literal = name.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'    BundledTheme(name: "{literal}", side: .{side(sig)}),\n')
    lines.append("  ]\n}\n")
    with open(GENERATED, "w", encoding="utf-8") as f:
        f.writelines(lines)


def checksums():
    lines = []
    for name in sorted(bundled_names(), key=str.casefold):
        with open(os.path.join(THEMES, name), "rb") as f:
            lines.append(f"{hashlib.sha256(f.read()).hexdigest()}  {name}\n")
    with open(os.path.join(THEMES, "CHECKSUMS"), "w", encoding="utf-8") as f:
        f.writelines(lines)


def main(argv):
    commands = {"stage": stage, "floor-failures": floor_failures, "catalog": catalog,
                "checksums": checksums}
    if len(argv) < 2 or argv[1] not in commands:
        sys.exit(__doc__)
    commands[argv[1]](*argv[2:])


if __name__ == "__main__":
    main(sys.argv)
