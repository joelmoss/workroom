# v3 screencast: shot list

The homepage video (`codaset/public/images/workroom-demo.mp4`, 39 s) predates remote workrooms, agent status and the creation pane. This is the 40-second replacement for v3. It began as a 30-second cut, but at that length the create, the alert and the review each got five seconds, too little to read a change and then see its result. Forty seconds gives each state change about two seconds to land, and it's the old cut's length. Going longer would mostly add beats, which the cut doesn't need. Nothing defines v3's scope yet, so the beats come from what master has shipped since v2.1.0.

The pitch: every task gets its own room, on this Mac or a machine in the cloud, and Workroom tells you when an agent needs you.

## Constraints

- The page plays it with `autoplay muted loop playsinline` and no controls. There is no narration and no sound, so every beat must read silently. Keystrokes appear as on-screen overlays, as in the old cut.
- The last frame matches the first, and both match the poster (`workroom-app.png`), so the loop and the poster-to-video handoff don't jump.
- Output is 1720 × 1080 at 30 fps, so the existing `<video>` markup still fits.
- At homepage width, small text such as the sidebar and usage bars is hard to read. The window stays big enough for splits (see Rehearsal), so push in on the moments that need small text.
- Every beat shows something changing on screen. Static panels (themes, file viewer, Help and Room menus) are left to the page's feature rows.
- Use the old cut's demo project (`acme-app` with generated workroom names).
- The project sidebar is collapsed by default (View ▸ Projects, ⌃⌘S), leaving the width to splits. It comes out, with a ⌃⌘S overlay, only for a beat that uses it, and goes away again after. ⌘B toggles the right sidebar, not this one.

## Shots

| Time | Beat | On screen |
|---|---|---|
| 0–4 s | The busy desk | Project sidebar collapsed. Two workrooms side by side: Claude working in one; the other split, with the project's Run command (`bin/dev`) in its green **Run** tab above a test run. The workroom tabs in the title bar show each room's state; the right sidebar shows the Details pane. Slow push-in until the tabs read. This frame is the poster. |
| 4–11 s | A new room, anywhere | ⌃⌘S overlay: the project sidebar slides in. Click a project row's **+**. The picker asks where; choose a remote host (exe.dev or boxd), not This Mac. The creation pane's steps tick off in the success colour (clone, included files, setup script) and land in a live shell with the cloud glyph on its tab and sidebar row. ⌃⌘S again collapses the sidebar. Speed up the waits between steps. |
| 11–16 s | Agents at work | Start Claude in the new remote pane. The footer shows usage: quota and pace. A long command elsewhere ends and its result shows on its pane. A remote pane looks and behaves like a local one. |
| 16–23 s | It tells you when you're needed | A pane out of view flips to "waiting on you". The workroom tab and the terminal tab pick up the alert (the sidebar stays collapsed; the menu bar logo is left out, owner 2026-10-22). ⇧⌘M overlay, jump straight to that pane, answer, and the agent carries on. Protect this beat if anything is cut. |
| 23–31 s | Review the work | The agent's turn ends. Open Changes, click a file: a side-by-side, syntax-highlighted diff. Then the Pull Request section: green CI checks, and the merge choice (merge, squash or rebase). |
| 31–37 s | Nothing dies | The relaunched app: both rooms and their splits are back with Claude's conversation intact. The quit and relaunch themselves aren't shown; they're implied (owner, 2026-10-22). Run commands stop at quit by design, so a ⌘R overlay brings the dev server back with one key, its Run tab going green. |
| 37–40 s | Close the loop | Settle on the 0 s frame. |

## Speed

Speed up any wait that isn't the point of its beat, in Screen Studio's editor, rather than cutting it, so the action stays continuous: the remote create's provisioning and clone, Claude thinking before it asks or edits, and the relaunch. Play the moments that are the point at real speed: the steps ticking, the alert landing, ⇧⌘M, the diff and PR appearing, ⌘R going green. Typing plays at real speed too, a character at a time.

## Themes

Each beat is shot in a different theme, so the cuts between beats show off the theme range without spending a second on a theme picker. The cut includes both light and dark, alternating where it can; beats 3 to 5 run dark back to back because beat 4's Claude console needs a dark window. The first and last beats share a dark theme so the loop closes and matches the dark homepage. Settings ▸ Appearance ▸ Theme is searchable and applies instantly; Settings ▸ Appearance ▸ Appearance (System, Light, Dark) picks the theme's light or dark variant. Tokyo Night was tried in rehearsal in both, and both read well.

| Beat | Theme family | Appearance | Variant | Why |
|---|---|---|---|---|
| 0–4 s, the busy desk | Tokyo Night | Dark | TokyoNight Night | Rehearsed; matches the dark homepage and is the poster. |
| 4–11 s, a new room | Catppuccin | Light | Catppuccin Latte | Checked: the cloud glyph is blue in the pane header and clear on the tab and sidebar row; the theme's green (CI ticks, Run dot) is bright. |
| 11–16 s, agents at work | Rosé Pine | Dark | Rose Pine | Checked: Claude's orange mascot and tab icon stand out on the purple-black. |
| 16–23 s, it tells you | GitHub | Dark | GitHub Dark | Was GitHub Light, but Claude's dark console drew black bars across the light window (owner, 2026-10-22). Checked on the take: the amber hand and tab underline read at once on the dark chrome, and Claude's edit approval sits naturally. |
| 23–31 s, review the work | Kanagawa | Dark | Kanagawa Wave | Checked on the take: added lines are a muted olive, removed lines a muted red, both clear side by side; the PR's checks and Merge button stay green. |
| 31–37 s, nothing dies | Solarized | Light | iTerm2 Solarized Light | Checked: the Run tab's dot is an olive green and reads; the `bin/dev` log is grey on cream, legible but low contrast, so push in on the tab rather than the log. |
| 37–40 s, close the loop | Tokyo Night | Dark | TokyoNight Night | Same take as the opening, so the loop meets. |

All seven are bundled families (`ThemeCatalog.swift`). Each was checked on the Dev build at the 1720×1075 take size (2026-10-22) and all read, so none was swapped. The creation pane's step ticks weren't seen live (that needs a fresh create); they use the same green as the checks.

Two things to know on the day. The demo Claude config is set to `"theme": "dark"`, so in a light window Claude's prompt lines, code and diff sit on black bars. That ruled out GitHub Light for beat 4 (owner, 2026-10-22). Since beat 6, Claude's theme is `"auto"` (`/theme` ▸ Auto (match terminal)), so it follows the app's light or dark theme with no restart. And the theme picker's search sometimes shows an empty list after a family is picked (seen with "Solarized" and "Tokyo"); pressing ↓ still applies the first match, or close and reopen the picker.

## Rehearsal (Dev build of 3605be429, 2026-10-21)

Driven by computer use on the `acme-app` demo repo at `~/dev/acme-app` (local only, no remote; `scripts/workroom_setup`, `.worktreeinclude` copying `.env`, fake `bin/test` and `bin/dev`).

- **Beat 2, local.** The row's **+** lists This Mac, Docker, Apple Container, boxd and exe.dev. The creation pane listed Fetch base branch (skipped: no remote), Create worktree, Copy local files and Run setup script, each ticking off. The first create stops on "Approve the setup script?"; it is approved now, so takes won't show it. Not checked: whether **Close automatically when done** lands straight in the shell.
- **Beat 3.** Claude Code's folder-trust prompt appears in every new workroom. The window footer's usage bars are small and labelled by account (`#1`, `ht`); the pane footer showed no usage while Claude ran. Needs a push-in or it won't read.
- **Beat 4 works as written.** While Claude waited on an edit approval: a hand on the tab and the sidebar row, the menu bar logo turned yellow, a Dock badge, and ⇧⌘M from another workroom jumped straight to the pane. After the turn, a "Terminal 1 in vivid-wheat finished · Turn finished" card appeared at the bottom of the sidebar.
- **Beat 5, diff.** Clicking a file in Changes opens the diff as a tab; the diff title bar switches it to side by side. Set Settings ▸ Appearance ▸ Diff view to Side by Side for takes.
- **Beat 6 works as written.** ⌘Q quits with no prompt. On relaunch the Claude conversation, the diff tab, the split layout and the theme were all back; the tab title went from the session title to `claude`. The Run tab does not come back (run commands stop at quit, as the docs say), and ⌘R restarts it.
- **Run command.** `acme-app`'s run command is `bin/dev` with **Run automatically when a workroom is created** on (Project Settings). ⌘R in a workroom adds a **Run** tab with a green dot, swaps the title bar's Run button for Restart and Stop, turns the sidebar row's run button and the workroom tab green, and shows a "Running · bin/dev" toast. It does not switch to the Run tab, so click it for the opening frame. Auto-run fired on a local create (`nice-tree`, before **Done**) but not on a remote one (below).
- **Claude Code's config showed on camera, now fixed.** It first ran with the owner's global instructions, hooks and status line: a `shortcut:` code comment, lint chatter, a "Transcript saving is off" warning, and a "Personal" status line. The warning came from the Dev app having been launched from inside a Claude session, which every pane inherited. Takes now use `~/.claude-demo`: signed in to the owner's account, no CLAUDE.md, hooks, plugins or status line, manual permission mode (beat 4 needs Claude to ask), onboarding and the first-run prompts dismissed, and `~/workrooms` and `~/dev/acme-app` pre-trusted. Trusting `~/workrooms` covers new workrooms inside it: Claude in the brand-new `nice-tree` showed no trust prompt and only its own `manual mode on` footer. Launch the Dev app for takes, including the beat 6 relaunch, with a clean environment pointing at it:

  ```sh
  env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_GB.UTF-8 \
    CLAUDE_CONFIG_DIR="$HOME/.claude-demo" open "macapp/DerivedData/Build/Products/Debug/Workroom Dev.app"
  ```

  Panes took the variable from the app launch above, not from the already-running helper, which still had the owner's. So a Dock relaunch probably gives new panes no `CLAUDE_CONFIG_DIR`, and Claude falls back to `~/.claude`. Not tested.
- **New Workroom from the File menu** (no sidebar needed) shows a project picker, then the same where-picker: This Mac, Docker, Apple Container, boxd, exe.dev. Beat 2 still creates from the sidebar row's **+**, because the cut should show the sidebar once (owner, 2026-10-21).
- **Screen Studio.** Area recording works. Stop with Record ▸ Stop recording, then **Finish** in the "Finish recording?" alert. Computer use can't click that alert, which belongs to macOS, so the owner clicks it. A click on the wallpaper triggers Show Desktop; F11 brings the windows back. Keys sent by computer use are captured, modifiers included: the test take's `keystrokes-0.json` has ⌘T, ⌘W, Esc, F11 and the typed `bin/test`. The project has shortcut badges off (`enableShortcuts: false`), so turn on keyboard shortcuts in the editor for each take; the rendered badge itself was not looked at. Typed text arrives about 10 ms per character, far too fast to read, so takes type a character at a time with pauses.
- **Beat 5, PR.** `acme-app` is now the private `joelmoss/acme-app`, with a two-job CI (`test`, `lint`) and PR #1 from `workroom/vivid-wheat` (Claude's rate limit, its `shortcut:` comment removed). The workroom's Pull Request section shows #1, a green **Merge** split button whose menu offers Create a merge commit, Squash and merge, and Rebase and merge, then CI passing with `lint` and `test` ticked. There are no reviewers on the private repo, so drop reviewers from the beat. Don't merge #1 during rehearsal: the take needs it open.
- **Window.** The window is 1720 × 1075 points (the 1720 × 1080 aspect) at position 741, 284. A 1376 × 860 window read better but left no room for splits (owner). At 1720 the opening frame fits: sidebar, `vivid-wheat` with Claude, `sunny-bay` split right with `bin/dev` above `bin/test`, and the right sidebar, all legible. Edge drags from computer use don't resize the window; `osascript -e 'tell application "System Events" to tell process "Workroom Dev" to set size of window 1 to {1720, 1075}'` does, run outside the command sandbox. Set Screen Studio's area to the same bounds. Push in for beats that need small text.
- **Splits.** Dragging a sidebar row from computer use doesn't start a drag, and ⌘D didn't split a terminal. File ▸ Open Workroom (split right) and the pane title bar's split buttons both work.
- **Sidebar.** The Dev app also lists the owner's `codaset` and `emoji` projects. They stay (owner, 2026-10-21).
- **Beat 2, exe.dev (workroom `slim-coral`).** From the sidebar row's **+** ▸ exe.dev, the creation pane listed ten steps and ticked them all in about 41 s: Check repository 8 s, Check exe.dev account 18 s, Create VM 3 s, Wait for boot 1 s, Set up machine 2 s, Connect 4 s, Clone repository 2 s, Check out branch and Copy local files under 1 s each, Run setup script 2 s. Speed up the first two. The setup script didn't ask for approval again. The workroom's sidebar row and workroom tab carry the cloud glyph. The shell opens on exe.dev's login banner (a long `workroom-<uuid>.exe.xyz` hostname, a web-terminal URL) and a plain bash prompt with the same long hostname. Run `clear` before the take, or cut to the cleared shell.
- **Run commands don't work on the exe.dev workroom.** Auto-run didn't fire after the remote create, the pane header has no Run button, and ⌘R does nothing. The sidebar row has no run button either, where every local row has one. This is by design for now: a remote target keeps `isMissing` true so local actions never see a remote path, and what a remote run should do is open question 4 in `remote-workrooms.md`. Filed as #522. Until it lands the remote beat can't show a run; the cut shows Run on local workrooms only (beats 1 and 6).
- **`slim-coral` is kept** for the takes (owner, 2026-10-21). Its exe.dev machine keeps running, and costing, until the workroom is deleted.

## Takes (2026-10-22)

Recorded with computer use on the Dev build; the owner clicked **Finish** on each. Projects live in `~/Screen Studio Projects/`.

| Beat | Project | Theme | Edited length | Notes |
|---|---|---|---|---|
| 1, the busy desk | `Workroom Dev 2026-10-22 16:15:18` | Tokyo Night, dark | 16 s (0–16 s), cut uses ~4 s | Fullscreen Claude thinking throughout; slow 1.2× push-in on the title bar from 1 s. Supersedes `15:17:55` (pre-fullscreen). |
| 2, a new room | `Workroom Dev 2026-10-22 15:32:34` | Catppuccin, light | ~6.7 s | Creates exe.dev workroom `dusk-flora` (kept for beat 3; costs until deleted). Steps 20×, cursor travel 10×, cut from Done to the cleared shell; one steady 1.6× zoom on the sidebar and menu. |
| 3, agents at work | `Workroom Dev 2026-10-22 16:08:32` | Rosé Pine, dark | ~5 s | Fullscreen Claude on `dusk-flora`, `claude "Add per-user rate limiting to session starts"`; ends before its permission prompt. 1.3× push-in toward the bottom left, then a tight push on the usage footer for the last 1.2 s. Supersedes `15:51:25` and `15:55:19`. |
| 4, it tells you | `Workroom Dev 2026-10-22 16:38:03` | GitHub, dark | ~7.5 s | Changes inspector open; hand on vivid-wheat's tab while in `dusk-flora`, ⇧⌘M back to Claude's edit approval. Menu bar logo dropped from the beat (owner). Supersedes `LG ULTRAWIDE 2026-10-22 16:28:35` and `16:30:28` (display recordings that caught the Nightly window behind). |
| 5, review the work | `Workroom Dev 2026-10-22 16:48:12` | Kanagawa, dark | ~8.4 s | Stacked layout (below). Diff opens side by side, scrolls to `over_limit?`, then PR #1's green CI and the Merge menu (Screen Studio's click zoom kept for the menu). Not merged. `16:44:09` is an aborted unified-diff take; delete it. |
| 6, nothing dies | `LG ULTRAWIDE 2026-10-22 16:55:55` | Solarized, light | ~6.2 s | Display recording (a window recording ends at ⌘Q), cropped to the relaunched window at 1091, 288; only the post-relaunch part is used. ⌘R in sunny-bay, the "Running · bin/dev" toast, the wait at 4×, then the Run tab with Puma booting. sunny-bay's Run/Terminal split doesn't survive quit (the Run pane closes), so Run comes back as a tab. Claude shows a "/theme · Theme set to auto" line. |
| 7, close the loop | — | — | — | Reuses beat 1. |

- **Fullscreen Claude.** `"tui": "fullscreen"` (what `/tui fullscreen` saves) is set in `~/.claude-demo/settings.json` and in `~/.claude/settings.json` on the `dusk-flora` VM. Claude's input and status line pin to the bottom of the pane, right above the usage footer, so one push-in reads both. Restart Claude after changing it. Claude still shows its own "Share Claude Code and earn £10 · /passes" notice under the banner.
- **Remote Claude on `dusk-flora`.** Claude Code was installed but never run; the VM got onboarding done, the dark theme, manual mode and `~/acme-app` pre-trusted, then the owner signed in. `gh auth login` on the VM (owner, device code) clears Claude's "gh auth login for PR status" footer hint. The fullscreen-renderer upsell appeared once on camera before fullscreen was set.
- **Beat 5 layout: stacked, not side by side.** The diff only renders side by side in a pane at least 700 pt wide (`DiffViewer.sideBySideMinWidth`); with `vivid-wheat` and `sunny-bay` side by side, vivid-wheat's pane was ~535 pt and fell back to unified. Dragging `sunny-bay`'s title-bar tab onto the bottom half of vivid-wheat stacks them, giving vivid-wheat the full width; sunny-bay's Run and test panes were then put side by side (Terminal tab dropped on the Run pane's right half). Beat 1 was recorded in the old side-by-side layout.
- **Beat 4 theme.** GitHub Light was dropped because Claude's dark console drew black bars across the light window (owner); beats 3 to 5 now run dark back to back. The menu bar logo was dropped from the beat too (owner), so beat 4 records the window only.
- **Record the window, not the display.** A display recording catches whatever sits behind the Dev window (here Workroom Nightly, with this repo and session text). Window mode captures only the Dev window. Hide Workroom Nightly first anyway: it reappears between takes and the window picker can grab it.
- **Editing Screen Studio projects by file.** Trims, speed changes and zooms were written into each project's `project.json` with Screen Studio quit; the editor otherwise loads its cached copy and saving writes it back over the edit. A slice's `timeScale` is a duration multiplier, so 5× speed is `0.2`. Click times in `mouseclicks-0.json` run up to ~1 s behind the video, so set cuts against frames, not click times. Camera speed is project-wide (`screenMovementSpring`): stiffness 11 / damping 12 / mass 3 for slow push-ins (beat 1), 27 / 18 / 3 for a quicker push that still doesn't bounce (beats 3 to 5). Each original `project.json` is backed up in the session scratchpad.
- **Other things seen.** A Claude edit was followed by a request to run `rubocop` (not installed; declined) and an LSP-plugin offer (answered "Never for this plugin"). A ⌘Q meant for Screen Studio quit Workroom Dev once; it was relaunched with the `env -i` command above, the panes reattached, and the Run tabs had stopped, so `bin/dev` needed ⌘R again.

## Dropped from the old cut

The old setup sheet, the ⌘W close, browsing commit detail, and moving a workroom to another window.

## Before recording

- The remote beat uses exe.dev (owner, 2026-10-21) and needs a real paid machine. Ask the owner before creating one.
- The usage footer shows the owner's real usage, unmasked (owner, 2026-10-21).
- Stage the opening desk (done 2026-10-22): Appearance set to Dark, not System (System turns the app light in the daytime); Diff view Side by Side; `sunny-bay` has the Run tab (`bin/dev` via ⌘R) split above a terminal that ran `bin/test`; the right sidebar shows Details; `vivid-wheat` has an uncommitted refactor of `session_manager.rb` plus a new `test/models/session_manager_test.rb`, so beat 5's diff shows removed and added lines.
- Claude is only mid-task for a minute or so. Re-prompt it in `vivid-wheat` just before rolling beat 1, with a read-only question, and decline any command it asks to run, or it stops on a permission prompt and the hand shows too early.

## When the file lands

- Replace `codaset/public/images/workroom-demo.mp4` and the poster `workroom-app.png`.
- Update the video's `aria-label` in `codaset/app/views/pages/workroom.rb` to describe the new cut.
- Swap the README's embedded user-attachments video for the same cut and update its `alt`.
