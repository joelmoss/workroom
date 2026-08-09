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
  dependency. **One of the ten is unset in our app, and always has been:** we export only
  `GHOSTTY_RESOURCES_DIR` (`GhosttyApp.swift:159`), never `GHOSTTY_BIN_DIR`. See the ssh note below —
  that is a pre-existing gap the drift neither caused nor worsened, not a clean bill of health.
- The OSC 133 vocabulary is a **strict subset**. Our scripts emit
  `133;A`/`B`/`C`/`D`/`P;k=i`/`P;k=s`; the engine's own scripts emit all of those plus `133;A;k=s`,
  which ours never send. So the pinned engine already parses every sequence we emit.

What the drift buys is four upstream fixes v1.3.1 lacks: ble.sh cursor desync (`b1ad24e2`),
`PROMPT_COMMAND` ending in a newline (`1f3a3b41`), inherited-`PROMPT_COMMAND` "command not found" in
subshells (`4b9324f4`), and the trailing-`%` prompt corruption (`43f3dc5f`). **Do not "fix" this by
downgrading to the v1.3.1 scripts** — it would trade four real fixes for a version number.

## The trap for the next engine bump

Between our snapshot and any later ref, upstream **deleted the inline ssh wrapper** from every shell
script and replaced it with a call to `ghostty +ssh` (`484d6ec6` and follow-ups, 2026-05-04/05 —
"roughly a third of our shell integration scripts").

We ship **no `ghostty` executable** and never set `GHOSTTY_BIN_DIR`. So regenerating this directory
from the bump target would hand users scripts that shell out to a binary that does not exist in the
bundle. It fails soft — the `ssh-env` / `ssh-terminfo` features are opt-in, so only a user who
enabled them in `~/.config/ghostty/config` is affected — but it fails silently, which is this
directory's whole failure mode.

**The gap is already live, in a milder form.** Our current pre-migration scripts also reach for that
binary: all five call `"$GHOSTTY_BIN_DIR/ghostty" +ssh-cache` (bash `:145`, zsh `:344`, and the fish
/ elvish / nushell equivalents). With the variable unset that expands to `/ghostty +ssh-cache`,
redirected to `/dev/null`, and bash/zsh fall through to the `infocmp` branch — so `ssh-terminfo`
users silently lose only the install-cache memoisation today, not the feature. After the migration
the same unset variable takes out the whole ssh wrapper instead.

That also means **"keep the pre-migration wrapper" is not a real escape hatch on its own** — the
wrapper we would be preserving has the same dependency. Either option below has to set
`GHOSTTY_BIN_DIR` (or accept the cache loss knowingly).

Decide it deliberately at bump time: ship a `ghostty` CLI + `GHOSTTY_BIN_DIR`, or keep our
pre-migration ssh wrapper as a local patch. See TODOS.md → "Bump the libghostty pin".

## Why any of this is checked

`GhosttyApp.resolveResources` only checks that the directory exists. The scripts and the engine's
Zig-side injection are a *coupled contract* (ZDOTDIR/ENV/XDG_DATA_DIRS, `GHOSTTY_SHELL_FEATURES`,
ssh integration) that nothing at runtime validates. If they drift apart, OSC 7 and OSC 133 degrade
**silently** — taking ⌘-click paths, tab titles and the busy indicator with them. There is no error
and no log; the terminal just quietly stops reporting things. `CHECKSUMS` plus its test is the only
tripwire.
