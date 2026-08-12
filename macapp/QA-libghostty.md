# QA Checklist — libghostty migration

Manual QA for the SwiftTerm → libghostty migration (commits `b81d5c6d` migration +
the code-review fixes on top). Run against a Debug build: `make app-run`.

🔧 = regression-tests a specific code-review fix. If something fails, the 🔧 items are
the likeliest suspects.

## A. Launch & engine
- [ ] `make app-run` → app launches, sidebar shows projects.
- [ ] Select a **project root** → a live shell spawns in the root dir (`pwd` confirms).
- [ ] Select a **workroom** → a live shell spawns in the *workroom's* dir, not the root.
- [ ] 🔧 *(optional, fail-soft A2)* Rename `Workroom.app/Contents/Resources/ghostty` aside →
      relaunch → clear "engine unavailable" placeholder, **not a crash**. Restore it after.

## B. Core terminal fidelity
- [ ] Type and run commands; output renders correctly.
- [ ] Run a full-screen TUI (`vim` or `htop`) → draws correctly; **resize the window** →
      reflows cleanly.
- [ ] Scroll back through history (trackpad + ⌘-scroll), then scroll to bottom.
- [ ] `echo $TERM` → `xterm-ghostty` (confirms bundled terminfo resolved).

## C. IME / keyboard (the cost center)
- [ ] **Dead keys**: `⌥e` then `e` → `é`.
- [ ] **CJK IME**: switch to a Pinyin/Japanese IME, type → candidate window appears *at the
      cursor*, selection inserts correctly.
- [ ] **Emoji picker** (`⌃⌘Space`) → inserts.
- [ ] **option-as-alt**: `⌥b` / `⌥f` move by word in a shell with readline.
- [ ] 🔧 During active marked (pre-edit) text, hold ⌘ → cursor still updates
      (flagsChanged-during-IME fix).
- [ ] 🔧 **TUI selection prompt in a fresh/just-mounted pane**: start `claude` (or another TUI with
      an ↑/↓ selection prompt) in a newly-opened tab or split pane, trigger the prompt → arrow keys
      and letter keys (e.g. `N`) work immediately without needing to click the pane first
      (createSurface focus-sync — surface created after the pane took first responder).

## D. Shortcuts
- [ ] `⌘T` → new terminal tab in the selected target.
- [ ] `⌘W` → closes the current tab (shell terminated).
- [ ] `⌘1`…`⌘9` → focus the Nth tab.
- [ ] `⌘O` → Add Project sheet.
- [ ] 🔧 **`⌘N`** → reaches the *terminal* (not swallowed by the app); in a shell/TUI that
      binds ⌘N it behaves normally. (⌘N was removed from the app-shortcut allowlist.)
- [ ] `⌘C` / `⌘V` pass through to the terminal (copy/paste work).

## E. Links / ⌘-click
- [ ] **⌘-hover a real file path** (after `ls` in a dir) → hand cursor **+ underline**.
- [ ] **⌘-click a relative path** → opens in the configured editor at the right file (cwd
      resolved via `GHOSTTY_ACTION_PWD` — `cd` into a subdir first to prove it tracks).
- [ ] **⌘-click an absolute path** → opens (always works, even without shell integration).
- [ ] **⌘-click a URL**
      (`printf '\e]8;;https://example.com\e\\link\e]8;;\e\\\n'`) → opens in browser.
- [ ] 🔧 **⌘-click on a non-file word** → does **not** get swallowed; normal text selection
      still happens.

## F. Selection / copy-on-select
- [ ] Copy-on-select **on**: drag-select → text is on the clipboard (paste elsewhere); no ⌘C.
- [ ] Copy-on-select **off** (toggle in settings): drag-select does **not** auto-copy; ⌘C works.
- [ ] 🔧 **⌘-click a real file**, then immediately drag-select something else → the
      post-file-click mouseUp doesn't suppress the next selection's copy
      (`suppressNextMouseUp` only fires for the file click itself).
- [ ] 🔧 **Right-click** → context menu appears, and afterward the terminal still responds to
      the next click/drag (balancing RELEASE after the menu).

## G. Bell 🔧 (critical regression — was silent)
- [ ] `printf '\a'` (or `tput bel`) → **system beep sounds**.
- [ ] Confirm the bell does **not** create a notification entry in the panel (content-free
      signal, intentionally not logged).

## H. Notifications
- [x] `printf '\e]9;Build finished\a'` in an **unfocused** tab → tab/sidebar **badge**;
      panel shows the entry with title. ✅ verified end-to-end.
- [x] OSC 777: `printf '\e]777;notify;Title;Body text\a'` → entry with title **and** body. ✅ verified.
- N/A OSC 99: `printf '\e]99;;Hello from 99\a'` → not supported by ghostty yet. Verified against
      ghostty `main`: no OSC-99 parser (only OSC 9 / 777 notify; "99" → invalid and dropped), so it
      never reaches the app. **Do not expect the open PR to fix this on its own** — #10467 adds only
      a *parser*, and files the command in the branch that logs "unimplemented OSC callback" and
      discards it; the stream dispatch, apprt action and `ghostty_action_*` tag an embedder would
      need do not exist as PRs. Nor would building our own xcframework from a ref including #10467
      change that. Re-check when **ghostty 1.4.0** ships (issue #5634 is milestoned there); see the
      OSC 99 entry in `TODOS.md`. OSC 9/777 cover the common cases meanwhile; SwiftTerm parsed OSC 99
      itself, so this remains a minor regression.
- [ ] Fire an OSC 9 in the **focused/active** tab → **no** notification (focus suppression).
- [ ] **Background the app** (⌘-Tab away), fire an OSC 9 → **system banner** appears.
- [ ] **Click the system banner** → app comes forward and jumps to the **exact tab/target**.
- [ ] Empty-title: `printf '\e]9;\a'` → entry shows "Notification" fallback (not blank).

## I. Theming 🔧
- [ ] Under the **"System"** theme setting, toggle **System Settings → Appearance → Dark**
      while the app is open → **all terminals re-theme**, including **hidden/background tabs**
      (switch to them after and confirm). *(System-mode observer fix.)*
- [ ] Force the app to a fixed Light/Dark theme → terminals match; flipping the OS appearance
      does **not** thrash them (reloadConfig coalesces to a no-op).
- [ ] The rounded-corner container fill matches the terminal background.

## J. Surface budget (perf)
- [ ] Open **50–100 tabs** across projects/workrooms.
- [ ] In Activity Monitor / Instruments: CPU, GPU, and memory stay reasonable.
- [ ] 🔧 Confirm **occluded (background) tabs idle** — no per-frame GPU work for tabs you're
      not looking at; switching away from an animating TUI (`htop`) drops its render cost.

## K. Lifecycle 🔧
- [ ] **Close a tab** → its shell is terminated (no leftover shell process in Activity
      Monitor), no leak.
- [ ] **Delete a workroom** → its tabs are reaped and its badges/history clear.
- [ ] **Detach/remount**: switch away from a tab and back repeatedly → no flicker/blank Metal
      layer (occlusion re-attach is clean).
- [ ] **Quit** (`⌘Q`) → confirm dialog; on Quit, surfaces are reaped then the runtime shuts
      down cleanly (no crash on exit — `applicationWillTerminate` teardown).

## L. Clipboard / OSC 52
- [ ] 🔧 A program writing the clipboard via OSC 52 with `text/plain` → succeeds; non-text
      mime is ignored (no garbage on the pasteboard).
- [ ] OSC 52 **read** works (permissive default — deferred-policy item; just confirm it
      doesn't crash/hang).

## M. Scrollback find (⌘F)
- [ ] `⌘F` (or Edit ▸ Find…) → a find bar appears top-right over the focused terminal; the field
      is focused and ready to type.
- [ ] Type a term present in the scrollback → matches highlight in the viewport and the bar shows
      "n / total"; an absent term shows **No results**.
- [ ] **Next / Previous**: `⌘G` / `⇧⌘G` (and the bar's ▲/▼ buttons, and ↩/⇧↩) step through matches
      and the "n /" index updates; it **wraps** at the ends (next past the last → first, previous
      before the first → last), with no visible flicker through the in-between matches. The wrap is
      synthesized host-side (the engine doesn't wrap), so verify it on a needle with **many** matches.
- [ ] `⌘G` / `⇧⌘G` with **no find bar open** → no-op (the menu command is app-owned, so the key is
      consumed rather than reaching the terminal). Find Next / Previous still shown in Edit ▸ Find.
- [ ] **Esc** (or the ✕ button) closes the bar and clears the highlights; focus returns to the
      terminal.
- [ ] Clear the field → highlights clear (empty needle cancels the search) without closing the bar.
- [ ] **Find from selection**: select text, then start search → the bar opens pre-filled with the
      selection (if wired to `search_selection`).
- [ ] **Per-surface isolation**: open a search in one tab, switch to another → the second tab has no
      bar; switching back restores the first tab's search state. Same across split panes (only the
      **focused** pane shows the bar).
- [ ] Find disabled when no terminal is focused (Edit ▸ Find… greyed; ⌘F a no-op).

## N. Engine bump smoke (run on EVERY libghostty pin change)

**Run this section against the *current* engine first and record the result.** Half of these items
have no correct absolute answer — only "same as before the bump" — so a baseline taken after the
bump is worthless. See TODOS.md → "Bump the libghostty pin".

**Scope note:** the risk in a bump is the **patch swap**
(`0002-host-managed-io.patch` → `-modern`, which rewrites PTY hosting), not the C enum. A mid-enum
`ghostty_action_tag_e` insert renumbers tags, but header and static archive ship together and
`GhosttyRuntimeAdapter.handleAction` dispatches on symbolic labels — don't spend the retest budget
there.

### IO layer (the patch swap)
- [ ] **Surface churn**: open/close ~20 panes in one workroom (⌘T then ⌘W, repeatedly) → no crash,
      no beachball. Record RSS before and after (Activity Monitor or `vmmap`), note the delta — not
      just "roughly its starting point," so a slow leak across future bumps is comparable, not
      eyeballed.
- [ ] **Split churn**: ⌘D / ⌘⇧D and close, repeatedly, including closing the *focused* pane of a
      split → the survivor stays mounted and full-size (never blank).
- [ ] **Workroom switch**: cycle between three workrooms ~10× → each returns to its own live panes;
      no surface renders another workroom's content.
- [ ] **Workroom delete** with live panes in it → panes tear down, app stays up.
- [ ] **Orphan check** (the one that catches a bad IO patch): a bare shell-name grep
      (`ps -ax | grep zsh`) always matches unrelated shells on the machine — false positive/negative
      both ways. Spawn the pane's shell with a unique marker instead (e.g.
      `MARKER=qa-orphan-$$ zsh -c 'export MARKER; exec zsh'`, or a distinctive argv0), quit the app,
      then `ps -eo pid,command -ax | grep -- "$MARKER"` → no match. Record RSS before/after alongside
      the process check. Repeat after a **force-quit** (`kill -9` the app PID, not ⌘Q, so a stuck
      System-Events dialog can't eat the keystroke).
- [ ] **Run tab**: start a run command, stop it, start it again → no "A server is already running",
      no orphan on the port (`lsof -i :<port>`), and the exit code reported matches reality.
- [ ] **Quit with a live TUI**: `vim` open in one pane, `htop` in another, ⌘Q → clean exit, no
      `EXC_BAD_ACCESS` (see `WorkroomApp.swift:665-678`).
- [ ] **Scrollback-click race** (new 2026-08-12, targets a `mouseButtonCallback`/scrollback-pruning
      use-after-free fixed upstream between our pin and the bump target): select/click a link or text
      while scrollback is actively producing output (e.g. `yes` piped to a pane) → no crash, no
      corrupted selection. Record RSS before/after.
- [ ] **`free_text` leak spot-check** (new 2026-08-12, targets a `ghostty_surface_free_text` fix —
      the function was silently not freeing memory before this pin): loop
      `readFullSurface`/`readSelectionText` (`GhosttySurfaceView.swift:792-857`) a few hundred times
      via the inline-agent or accessibility read path. RSS alone can't distinguish a real leak from
      normal allocator retention at this volume — use Xcode's Instruments (Leaks template) or a
      scripted `leaks <pid>` run around the loop, not just Activity Monitor.

### Behaviour keyed to engine internals (assert *no change*, not correctness)
- [ ] **⌘F wrap + ordering** — `TerminalSearch.navigationPlan` inverts the engine's direction and
      synthesizes wrap host-side. On a needle with many matches: Find Next must walk **down** the
      screen and the counter must count **up**. If either reversed, the engine's ordering moved and
      `navigationPlan` is now wrong, not merely redundant. Re-run §M in full.
- [ ] **Backspace** erases (we forward a literal `0x7f` as text because the pinned engine's keycode
      encoding is broken — `GhosttySurfaceView.swift:1171`). If it now double-deletes, the engine
      was fixed and the workaround must go.
- [ ] **⌃Tab** reaches a TUI in a single-pane workroom (the pinned engine sends no bytes for it, so
      "nothing happens" is the expected baseline, not a regression).
- [ ] **Scrollbar overlay** — `0010-fix-scroll-remainder-zeroing.patch` is new in the target
      package. Scroll a long buffer to the middle, to the top, to the bottom → the overlay tracks
      without jumping or sticking.

### Resource contract (silent-failure class)
- [ ] `echo $TERM` → `xterm-ghostty`, and `infocmp xterm-ghostty >/dev/null` succeeds.
- [ ] **OSC 7 still lands**: `cd` somewhere, then ⌘-click a *relative* path in the output → resolves
      against the new cwd. (Nothing logs when this breaks — it just stops working.)
- [ ] **OSC 133 still lands**: run a long command → the tab title tracks it and the busy indicator
      animates, then clears on completion.
- [ ] If `shell-integration/` was regenerated, `make app-test` covers the bytes
      (`GhosttyResourcesTests`) but **not** the contract — both boxes above are the contract.
- [ ] **ssh integration.** We now ship the CLI the wrapper needs: `Contents/MacOS/ghostty` is a
      relative symlink to the app binary (see `ghostty/SOURCE.md`). The parts that are automated —
      the symlink's shape, `+ssh-cache` dispatch, and `GHOSTTY_BIN_DIR` resolving in a live pane —
      are covered by `GhosttyCLITests` and `GhosttyCLIUITests`; **what is left here is the part that
      needs a real remote host.**

      `GHOSTTY_SHELL_FEATURES` is an *injected* env var, not a config key: enable the feature with
      `shell-integration-features = ssh-env,ssh-terminfo` in `~/.config/ghostty/config`, then open a
      new pane and confirm `echo $GHOSTTY_SHELL_FEATURES` actually lists them.
      Then `type ssh` → must report a shell *function*, not `/usr/bin/ssh` (that's what proves the
      wrapper loaded at all). `ssh <a host you control> env | grep -E 'COLORTERM|TERM_PROGRAM'` →
      the variables arrive. **Do not** assert merely on the absence of "command not found": a failing
      call is redirected to `/dev/null`, so silence is exactly what a broken wrapper looks like.
- [ ] **ssh cache memoisation** (the thing the symlink actually bought). With `ssh-terminfo` on,
      `ssh <host>` twice. The first connect installs terminfo; the second should skip it, and
      `~/.local/state/ghostty/ssh_cache` should hold a `host|timestamp|xterm-ghostty` line. Before
      the symlink shipped, that file was never written at all.
- [ ] **Shell matrix.** The wrapper is defined in five shells with three different guard styles
      (bash/zsh call the binary bare; fish guards with `test -x`; elvish wraps in `?(…)`; nushell
      uses `^$ghostty … | complete`). Only **bash and zsh** are installed on the current dev machine
      — `nu` on PATH is `@antfu/ni`, not nushell — so **fish, elvish and nushell are UNTESTED**, not
      passing. Nushell is the one to prioritise if it ever gets installed: its `complete` catches
      exit codes, and it is unverified whether it also catches a spawn failure, which is what the
      missing binary used to produce.

### Build shapes CI doesn't cover
- [ ] **Universal Release build links**: `VCS_APPLE_FLAGS=--universal make app-vcs`, then
      `xcodebuild -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build`, then
      `lipo -info` the binary → both slices. CI only builds Debug/native.
- [ ] **Bake gate**: N clean nightlies before this enters a `pre` tag.
