# Bundled libghostty runtime resources

`GHOSTTY_RESOURCES_DIR` points here at launch (see Core/GhosttyApp.swift). libghostty needs:

- `terminfo/` — the `xterm-ghostty` / `ghostty` terminfo entries. libghostty sets
  `TERM=xterm-ghostty` for the shell but NOT `TERMINFO`, and macOS has no system entry for it, so
  `GhosttyApp` also exports `TERMINFO` → here (without it the shell can't resolve the terminal's
  capabilities and line editing — e.g. Backspace — breaks).
- `shell-integration/` — per-shell scripts Ghostty auto-injects; these report OSC 7 pwd
  (the cwd source for ⌘-click path resolution — see plan CMT-1) and more.

- `themes/` — **ours, not upstream's.** 56 curated theme files whose names `ThemeService.families`
  parses, plus the two hand-authored `Workroom` themes. Do NOT regenerate this directory from a
  ghostty checkout; it would break the theme picker.

The `libghostty-spm` package ships no terminfo or shell-integration, so those are vendored here.
**Their provenance is unrecorded** — "a recent Ghostty build", no ref, no sha — and they are a
*coupled contract* with the engine's own Zig-side injection, which `GhosttyApp.resolveResources`
cannot verify (it only checks the directory exists). If they drift, OSC 7 and OSC 133 degrade
silently, taking ⌘-click paths, tab titles and the busy indicator with them.

**TODO:** regenerate `terminfo/` + `shell-integration/` from the exact ghostty ref the pinned package
builds from (see `macapp/project.yml` for which that is), and record the sha here. Tracked in
`TODOS.md` → "Regenerate the bundled ghostty resources"; blocking for the pin bump.
