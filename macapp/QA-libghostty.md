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
- N/A OSC 99: `printf '\e]99;;Hello from 99\a'` → not supported by ghostty **yet — it's coming.**
      Verified against ghostty `main`: no OSC-99 parser today (only OSC 9 / 777 notify; "99" → invalid
      and dropped), so it doesn't reach the app. But there's an **open upstream PR,
      ghostty-org/ghostty#10467** ("parse the Kitty desktop notification protocol (OSC 99)"), not yet
      merged. So OSC 99 should work once we build the xcframework from a ghostty that includes #10467
      (or cherry-pick it into our fork). ghostty is also adding a libghostty fallback-handler for
      unknown OSC, which would be an alternate way to handle it app-side. OSC 9/777 cover the common
      cases until then; SwiftTerm parsed OSC 99 itself, so this is a temporary minor regression.
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
      and the "n /" index updates; it **wraps** at the ends.
- [ ] `⌘G` / `⇧⌘G` with **no find bar open** → passes through to the terminal (not swallowed) — e.g.
      a shell/TUI that binds ⌘G behaves normally.
- [ ] **Esc** (or the ✕ button) closes the bar and clears the highlights; focus returns to the
      terminal.
- [ ] Clear the field → highlights clear (empty needle cancels the search) without closing the bar.
- [ ] **Find from selection**: select text, then start search → the bar opens pre-filled with the
      selection (if wired to `search_selection`).
- [ ] **Per-surface isolation**: open a search in one tab, switch to another → the second tab has no
      bar; switching back restores the first tab's search state. Same across split panes (only the
      **focused** pane shows the bar).
- [ ] Find disabled when no terminal is focused (Edit ▸ Find… greyed; ⌘F a no-op).
