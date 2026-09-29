# Engine parity patches for libghostty-vt

The app's terminal engine is `libghostty-spm`, which builds Ghostty with its own patch stack. The
remote agent's shadow terminal is `libghostty-vt`, built from stock Ghostty by
`../build-ghostty-vt.sh`. Where a package patch changes what the **terminal** does — its state, its
modes, what it reports — the shadow must do the same, or a pane and its remote shadow disagree about
the screen they are both tracking.

This directory holds those patches, vendored **unchanged** from `Lakr233/libghostty-spm` (MIT) at the
release `macapp/project.yml` pins, and applied by `build-ghostty-vt.sh` to a scratch worktree of the
pinned Ghostty sha. It never touches a checkout you pointed it at.

| file | package patch | why the shadow needs it |
|---|---|---|
| `0014-preserve-sync-on-resize.sh` | `Patches/ghostty/0014-preserve-sync-on-resize.sh` | Stock `Terminal.resize` ends DEC 2026 synchronized output. The app keeps it, so a resize mid-repaint doesn't flash an empty grid. Without this the shadow drops the mode on a resize the app keeps, and the two diverge on the next replay. |
| `support/anchored_edit.py` | `Script/support/anchored_edit.py` | The helper 0014 imports. |

Package patches that are **not** here, on purpose:

- `0002` host-managed IO, `0011` replay response suppression: surface and termio plumbing. The
  shadow has no surface.
- `0010` scroll remainder: a `Surface.zig` input path.
- `0015` hold-frame-for-prompt-redraw: renderer-only behavior. It adds `Screen.prompt_redraw`, a flag
  the renderer reads; it changes no cell, mode, or reported byte, so nothing in a snapshot, formatter
  output or continuation differs. Revisit if that stops being true.
- `0003`–`0009`, `0012`, `0013`, `0016`, `0017`: build and platform (iOS, Catalyst, visionOS, Metal).

## Bumping

When `macapp/project.yml`'s package version moves, diff the package's `Patches/ghostty/` between the
two tags. Any new or changed patch that touches `src/terminal/` (other than a renderer-only flag, as
with 0015) belongs here; re-copy the ones already here. Edit nothing locally — a local edit is a
divergence from the app by definition. The patches are anchored: if upstream moved the text they
edit, the build stops with a `[-]` line naming the file rather than patching the wrong place.

Vendored from `libghostty-spm` `1.6.20260928` (`5a025555f0a85ee51da7eb306c35f660d116e879`).
