# Bundled libghostty runtime resources

`GHOSTTY_RESOURCES_DIR` points here at launch (see Core/GhosttyApp.swift). libghostty needs:

- `terminfo/` — the `xterm-ghostty` / `ghostty` terminfo entries. libghostty sets
  `TERM=xterm-ghostty` for the shell but NOT `TERMINFO`, and macOS has no system entry for it, so
  `GhosttyApp` also exports `TERMINFO` → here (without it the shell can't resolve the terminal's
  capabilities and line editing — e.g. Backspace — breaks).
- `shell-integration/` — per-shell scripts Ghostty auto-injects; these report OSC 7 pwd
  (the cwd source for ⌘-click path resolution — see plan CMT-1) and more.

- `themes/` — **ours, not upstream's.** 116 curated theme files whose names `ThemeService.families`
  parses — 114 vendored from iTerm2-Color-Schemes plus the two hand-authored `Workroom` themes,
  forming 58 dark/light families. Do NOT regenerate this directory from a ghostty checkout; it would
  break the theme picker. Its provenance is recorded separately in `themes/SOURCE.md` +
  `themes/CHECKSUMS`, and it is deliberately NOT covered by the `CHECKSUMS` file in this directory.

## Provenance

The `libghostty-spm` package ships no terminfo or shell-integration, so both are vendored here (once,
in `b81d5c6d`, the SwiftTerm → libghostty commit). This section records what was previously unknown.
`CHECKSUMS` in this directory pins the exact bytes of everything below, and
`GhosttyResourcesTests.testBundledResourceChecksumsMatch` recomputes and compares them.

**Engine the measurements below were taken against:** whatever `macapp/project.yml` pinned on
2026-08-09 — read it, it is the single source of truth for the engine version and this file
deliberately does not duplicate it. The comparison baseline was a stock Ghostty.app install of that
same version. Re-measure after a pin bump; these findings expire with it.

### `terminfo/` — matches the engine exactly

Measured 2026-08-09: `terminfo/78/xterm-ghostty` is **byte-identical** to the same file in the stock
Ghostty.app install. `terminfo/67/ghostty` is the same compiled entry again under the `ghostty` alias
name (identical sha256), so a user's `TERM=ghostty` also resolves.

Upstream ships that alias too, but as a **symlink** (`67/ghostty -> .././78/xterm-ghostty`); ours is
a byte copy. That difference is deliberate and load-bearing for `CHECKSUMS`: a regeneration done by
copying a Ghostty.app resource tree with `cp -R` reproduces the symlink, and `GhosttyResourcesTests`
**rejects symlinks** under the tracked subtrees rather than following them (a symlinked *directory*
would otherwise hide its whole contents from the manifest). If a regeneration trips that assertion,
dereference the links (`cp -RL`) rather than relaxing the test.

Nothing to regenerate. Re-verify after an engine bump, not before.

### `shell-integration/` — a main snapshot 12–52 days ahead of the engine

Not from the v1.3.1 tag. `bash/ghostty.bash` is a byte-exact match for ghostty blob
`7eaf1397bdd9d04ae5ac5b85a0c9aa2ae392d902`, first reachable at `4b9324f4` (2026-03-20), and the zsh
script carries the trailing-`%` prompt fix from `43f3dc5f` (2026-03-25). Neither file changed again
until the `ghostty +ssh` migration on 2026-05-04/05, so the vendored set is consistent with **any
ghostty `main` commit in [`43f3dc5f` 2026-03-25 … `484d6ec6` 2026-05-04)** and cannot be narrowed
further from content alone.

Being ahead of the engine is safe **here, on this pair**, and that was measured rather than assumed:

- The injection contract is identical *between the two script sets*. Both reference exactly the same
  ten `GHOSTTY_*` variables (`GHOSTTY_BASH_ENV`, `_INJECT`, `_RCFILE`, `_UNEXPORT_HISTFILE`,
  `GHOSTTY_BIN_DIR`, `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_SAVE_PS`, `GHOSTTY_SHELL_FEATURES`,
  `GHOSTTY_SHELL_INTEGRATION_XDG_DIR`, `GHOSTTY_ZSH_ZDOTDIR`), so the drift introduced no new
  dependency. All ten are satisfied. We export `GHOSTTY_RESOURCES_DIR` ourselves
  (`GhosttyResources.exportResourcesDir`, called from both `GhosttyApp` and `main.swift`); the engine
  sets the other nine itself, `GHOSTTY_BIN_DIR` among them — see the ssh section below, which
  corrects an earlier claim in this file that we left it unset.
- The OSC 133 vocabulary is a **strict subset**. Our scripts emit
  `133;A`/`B`/`C`/`D`/`P;k=i`/`P;k=s`; the engine's own scripts emit all of those plus `133;A;k=s`,
  which ours never send. So the pinned engine already parses every sequence we emit.

What the drift buys is four upstream fixes v1.3.1 lacks: ble.sh cursor desync (`b1ad24e2`),
`PROMPT_COMMAND` ending in a newline (`1f3a3b41`), inherited-`PROMPT_COMMAND` "command not found" in
subshells (`4b9324f4`), and the trailing-`%` prompt corruption (`43f3dc5f`). **Do not "fix" this by
downgrading to the v1.3.1 scripts** — it would trade four real fixes for a version number.

## The ssh wrapper, and the `ghostty` symlink that feeds it — RESOLVED

Between our snapshot and any later ref, upstream **deleted the inline ssh wrapper** from every shell
script and replaced it with a call to `ghostty +ssh` (`484d6ec6` and follow-ups, 2026-05-04/05 —
"roughly a third of our shell integration scripts").

**Two earlier claims in this file were wrong, and are corrected here.** It said we "never set
`GHOSTTY_BIN_DIR`", and concluded that either way out "has to set `GHOSTTY_BIN_DIR`". Neither holds:

- **The engine sets it, and always has.** `src/termio/Exec.zig` does
  `env.put("GHOSTTY_BIN_DIR", dirname(executablePath()))` inside a block labelled `ghostty_path:`,
  and the literal is present in our own pinned archive among the other child-env strings (`TERMINFO`,
  `xterm-256color`, `GHOSTTY_BIN_DIR`, `MANPATH`, `TERM_PROGRAM_VERSION`). For us it resolves to
  `Workroom.app/Contents/MacOS`. The variable was never unset — the directory just had no `ghostty`
  in it, so `"$GHOSTTY_BIN_DIR/ghostty" +ssh-cache` failed on a missing file rather than an empty
  path.
- **We did not need to build a CLI.** `libghostty` carries the entire `+action` implementation set:
  `src/build/GhosttyLib.zig` roots the library at `src/main_c.zig` → `global.zig` → `cli.zig`,
  unconditionally. Verified in our archive — `nm -gU` shows `_ghostty_init` and
  `_ghostty_cli_try_action`, `nm -a` shows `cli.ghostty.Action.runMain` and
  `cli.ssh-cache.DiskCache.*`, and `strings` carries the full `+ssh-cache` help text. Dispatch is a
  **two-call sequence**: `ghostty_init` parses and *stores* the action, `ghostty_cli_try_action` runs
  it and exits. The app called only the first, which is why nothing ever ran.

**What ships now.** `Contents/MacOS/ghostty` is a **relative symlink to the app binary**, created by
the "Symlink ghostty" build phase in `project.yml` before Xcode's final code-sign, and `main.swift`
branches on `argv[0]` to run the CLI dispatch instead of starting the GUI. This is upstream's own
shape — `Ghostty.app/Contents/MacOS/ghostty` *is* the app binary there too — and it means the action
set we expose is exactly the pinned engine's, by construction: no second binary to keep in
architecture, signing or engine lockstep.

Measured, not assumed (a throwaway bundle carrying the same symlink shape): `codesign` seals it
(`Sealed Resources … files=1`), and it survives `--verify --deep --strict`, a `ditto` zip round-trip,
notarization (`status: Accepted`), `stapler staple` + `validate`, a UDZO DMG round-trip, and
`spctl -a -vvv` (`accepted / source=Notarized Developer ID`) — still a symlink, still executing with
`argv[0] == "ghostty"`. `release.sh` asserts all of this on the real artifact, including actually
running `+ssh-cache` on it, because a build completing proves packaging, not function.

**Consequence for the bump: regenerating `shell-integration/` is now safe** — but only *with or
after* the pin bump, never before it. `+ssh` does not exist at the pinned v1.3.1 (it is `main`-only,
in no tagged release) and arrives at the bump target `35e1a016`. Regenerating first would swap the
inline wrapper for a call to an action this engine does not have. TODOS.md's pin-bump entry carries
the blocking test that must accompany it.

**Side effect worth knowing:** the engine puts `Contents/MacOS` on every pane's `PATH`, so inside a
Workroom terminal `ghostty` now resolves to this helper and shadows a real Ghostty.app. A bare
`ghostty` therefore prints a message naming Workroom and exits 1, rather than launching a second
copy of the app. `GhosttyCLITests` pins that behaviour.

### Pre-bump latency baseline

The wrapper calls `+ssh-cache` once per `ssh`. Measured on the Debug build (58 KB launcher + an
81 MB debug dylib — Release links statically and is faster), 20 runs each:

| | per invocation |
|---|---|
| `ghostty +ssh-cache --host=…`, cold miss | ~21 ms |
| `ghostty +ssh-cache --host=…`, warm hit | ~21 ms |
| `infocmp -0 -x xterm-ghostty` (the fallback it replaces) | ~2.9 ms |

Read it as: on a **miss** we pay ~21 ms of pure overhead and then take the `infocmp` path anyway; on
a **hit** those same ~21 ms replace `infocmp` *plus a full ControlMaster round-trip to the remote
host* to push terminfo, which is orders of magnitude more. Hosts are cached after first connect, so
steady state is hits and the cache is a clear win. Re-measure after the bump: `+ssh` moves the whole
wrapper into the binary, so this is the only before-picture we will have.

## Why any of this is checked

`GhosttyApp.resolveResources` only checks that the directory exists. The scripts and the engine's
Zig-side injection are a *coupled contract* (ZDOTDIR/ENV/XDG_DATA_DIRS, `GHOSTTY_SHELL_FEATURES`,
ssh integration) that nothing at runtime validates. If they drift apart, OSC 7 and OSC 133 degrade
**silently** — taking ⌘-click paths, tab titles and the busy indicator with them. There is no error
and no log; the terminal just quietly stops reporting things. `CHECKSUMS` plus its test is the only
tripwire.
