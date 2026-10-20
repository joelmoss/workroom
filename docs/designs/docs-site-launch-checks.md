# Docs site: checks against the app

The pages under `docs-site/` were drafted from the code and the README, never from the running app (D5). On 2026-10-20 every page's claims were checked against the code: about 390 matched it, 39 were wrong and were fixed, and the items below are what only the running app (or a real provider) can settle. Work through them, then delete this file.

## Contradictions found while drafting (resolved 2026-10-20)

- **The six README contradictions** (pull request creation, the ⌘§ Quick Terminal hotkey, install variables before `curl`, exit code 2, the 10-second lock, Delete Anyway as shipped) went with the README trim (D14). The README now links to the docs, which had the code's version of each.
- **CONTRIBUTING** put the release channel under Settings ▸ General. Fixed to Settings ▸ About, where `AboutSettingsPane` has the picker, in CONTRIBUTING.md (twice) and `macapp/AGENTS.md`.
- **`DeleteProjectSheet.swift`'s "base machine" warning is not stale.** It shows only when `project.host` is set, and a project can still record a base an older build made until `BaseRetirement` takes it down (a base it can't take down keeps its record). `RemoteWorkroomDeletionTests` pins the wording. No change.
- **Voice mode recovery:** `app/coding-agents.md` was the odd one out. `macapp/README.md` and the #368 release-note plan agree: terminals, new ones included, run under the previous version's helper while it lives, so the fix is to close every terminal, quit, wait about 30 seconds and relaunch, then check System Settings ▸ Privacy & Security ▸ Microphone. Both pages now say that, in that order.
- **Architecture:** the shipped app is universal. Every executable in v2.1.0's `.dmg` (Workroom, ghostty, workroom-session, wr-agent) and the bundled CLI is `x86_64 arm64` (`lipo -archs`), and `release.sh` refuses a release that isn't. The README and CONTRIBUTING.md no longer say Apple Silicon only; they say macOS 15 or later, like `get-started/install.md`. Whether to say Intel Macs are supported is the owner's call, since no one has checked the app on one.

## Waiting on the owner

- **"Diagnose with" does nothing.** `terminalAgentBackend` is read only by `SettingsView.swift` (its picker and caption). Diagnosis always runs `claude` (`CodingAgentRunner.swift`, `claudeInline`, the only diagnosis call), and so does Investigate (`CodingAgentPrompt.swift`, `investigateCommandLine`). So the setting, its caption ("Codex is used only for Investigate"), and the "No agent CLI found — install Claude Code or Codex" message are all wrong today. Either wire the setting up in the app, or change the docs and the app's copy to say only Claude Code is used. `app/coding-agents.md` and `app/settings.md` still describe the setting as working, until that's decided.
- **The Stop button's tooltip** (`TargetDetailToolbar.swift`) says "again to force-quit", but there is no second-press force-quit: Stop sends Ctrl-C and the supervisor kills the command after about 6 seconds (`RunCommandController.swift`, "No second-press hard-kill"). The docs now say what really happens; the tooltip needs the same fix in the app.
- **Intel Macs:** say they're supported, or keep saying nothing (see Architecture above).

## Needs the running app

Each is a claim the code supports but can't prove on its own. Look, and fix the page if it differs.

### Menus and placement

- The app menu's **Settings…** item (system-provided by the SwiftUI `Settings` scene) and the Window menu's order: **New Window** and the **Move … into new window** items should be at the top.
- The project row: the gear appears left of the **+** on hover, without the row changing height. The sidebar's **+** for adding a project is at the bottom right.
- The workroom tab bar runs across the top of the window, and a workroom becomes a tab only once it has a terminal.
- **Close automatically when done** sits at the bottom left of the creation pane.
- The **Update** button and its scrolling note at the trailing end of the title bar (needs a Release or Nightly build that is behind; Debug builds don't check).
- The red **Command failed (exit N)** in the pane footer, and its position after the branch.
- How the sync button's text shortens at narrow inspector widths ("origin" and "with rebase" drop), and the width where a diff falls back to unified.

### Behaviour

- After a create finishes, the workroom's terminal appears (on Nightly it mounts after **Done** or auto-close).
- After a failed teardown, "nothing is removed": the row comes back, but the workroom's terminals were already closed before the teardown ran. Check what's left and reword if needed.
- The quick switcher: tap flips, holding shows the rail after about 250 ms, Tab and the arrows step, Esc cancels, release or click commits.
- A tab names itself after the running command (run `sleep 30`) or the folder.
- A plain command like `sleep 30` does not animate the tab (the docs now say only a program that reports it is working does). If it does animate, revert that sentence.
- Dragging tabs to reorder them; dragging a sidebar workroom onto a pane edge shows a band and lands on that side; dragging a pane title bar or tab past the window edge makes it a window at the drop point; a popped-out pane reopens in the same place after a relaunch; <kbd>⌃⌘</kbd>-arrows pass through to a TUI at a split's edge.
- The Quick Terminal window's size (800 × 500 in code; the page says "small").
- The yellow warning triangle on a project (its colour comes from the theme).
- The Dock badge, and a real macOS banner and clicking it.
- `/bin/bash` (3.2) never shows a command result, and loses the inline agent, tab-title reset and folder tracking (only `docs/program-status.md` says so).

### Outside Workroom

- The Claude Code (2.1.295) and Codex (0.163) minimum versions, and the timings ("about 6 seconds after", "1 to 3 seconds in"), which come only from `docs/program-status.md`.
- macOS's own wording of the "would like to access data from other apps" prompt, and the Full Disk Access and Microphone paths in System Settings.
- The microphone recovery steps (close every terminal, quit, wait about 30 seconds, relaunch) on a real update.

### Remote workrooms

- boxd and exe.dev setup sheets: the sheet covers the window while the pane row reads **Waiting for you**; ticks update live as you sign in; **Stop** stops a boxd sign-in; exe.dev's **Choose a Plan** and **Connect GitHub** website flows and **Check Again** picking them up.
- `ssh exe.dev share port` and whether a shared port is private by default.
- Containers: a container stops when the Mac sleeps and comes back when you open the workroom; image download progress on **Pull host image**; the failure messages when Docker or Apple's container system is stopped; Docker Desktop, OrbStack and Colima all work.
- Port forwarding: the same local port number comes back after a relaunch; a browser reaches a real dev server.
- Reconnecting: <kbd>⌃C</kbd> on a restored pane while the network is off; programs on a boxd or exe.dev host end when the host restarts; panes don't blink on wake when the host answers, and the retry notice looks as the page shows.
