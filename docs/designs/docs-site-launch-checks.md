# Docs site: checks against the app

The pages under `docs-site/` were drafted from the code and the README, never from the running app (D5). On 2026-10-20 every page's claims were checked against the code: about 390 matched it, 39 were wrong and were fixed, and the items below are what only the running app (or a real provider) can settle. Work through them, then delete this file.

## Contradictions found while drafting (resolved 2026-10-20)

- **The six README contradictions** (pull request creation, the ⌘§ Quick Terminal hotkey, install variables before `curl`, exit code 2, the 10-second lock, Delete Anyway as shipped) went with the README trim (D14). The README now links to the docs, which had the code's version of each.
- **CONTRIBUTING** put the release channel under Settings ▸ General. Fixed to Settings ▸ About, where `AboutSettingsPane` has the picker, in CONTRIBUTING.md (twice) and `macapp/AGENTS.md`.
- **`DeleteProjectSheet.swift`'s "base machine" warning is not stale.** It shows only when `project.host` is set, and a project can still record a base an older build made until `BaseRetirement` takes it down (a base it can't take down keeps its record). `RemoteWorkroomDeletionTests` pins the wording. No change.
- **Voice mode recovery:** `app/coding-agents.md` was the odd one out. `macapp/README.md` and the #368 release-note plan agree: terminals, new ones included, run under the previous version's helper while it lives, so the fix is to close every terminal, quit, wait about 30 seconds and relaunch, then check System Settings ▸ Privacy & Security ▸ Microphone. Both pages now say that, in that order.
- **Architecture:** the shipped app is universal. Every executable in v2.1.0's `.dmg` (Workroom, ghostty, workroom-session, wr-agent) and the bundled CLI is `x86_64 arm64` (`lipo -archs`), and `release.sh` refuses a release that isn't. The README and CONTRIBUTING.md no longer say Apple Silicon only; they say macOS 15 or later, like `get-started/install.md`, and name no architecture (owner, 2026-10-20).

## App fixes found by the check (done 2026-10-20)

- **"Diagnose with" did nothing.** The setting was never read: diagnosis and Investigate both always ran `claude`. The owner chose to keep the automatic diagnosis Claude-only (decision X1: `codex exec` still has no tools-off mode in 0.163) and have the setting pick the agent **Investigate** opens. It is now **Investigate with**; Auto is Claude, else Codex, and with Claude Code missing the banner still offers Investigate with Codex. The caption and the not-found message say so, and `app/coding-agents.md` and `app/settings.md` match.
- **The Stop button's tooltip** promised a second-press force-quit that doesn't exist. It now reads "Stop the run command (⇧⌘R)".
- **Checked in the running app (Dev build of 8b4e71bec).** The red **Command failed (exit 1)** sits after the branch in the pane footer. The **Investigate with** picker and its caption read as `app/settings.md` says. With Claude installed, Diagnose gives a fix and **Investigate** opens `codex` when Codex is the pick. With `claude` off the PATH, the footer reads "Claude Code CLI not found — it runs the diagnosis". **Investigate** then opens `codex` under Auto, and there is no button under Claude. With neither CLI, it reads "No agent CLI found — install Claude Code or Codex" and offers nothing. That matches `app/coding-agents.md`.

## Needs the running app

Each is a claim the code supports but can't prove on its own. Look, and fix the page if it differs.

### Checked in the running app (Dev build, 2026-10-20)

- **Menus:** **Settings…** is in the app menu; **New Window**, **Move pane into new window** and **Move workroom into new window** top the Window menu.
- **Project row:** the gear appears left of the **+** on hover and the rows don't move. The sidebar's **+** is at the bottom right.
- **Tab bar:** workroom tabs run across the top. A workroom being created gets a tab straight away, before it has a terminal; the docs only say open workrooms appear there, so nothing to change.
- **Creation pane:** **Close automatically when done** is at the bottom left once the create finishes, and **Done** opens the terminal. Only the steps the project has are listed: emoji, with no `.worktreeinclude` or setup script, showed two rows, so `app/workrooms.md` now says the last two are conditional.
- **Sync button:** **Publish branch** on an unpublished branch, the last fetch time with nothing to do. The docs make no claim about the text shortening.
- **Diff fallback:** with **Side by Side** set in Settings, a narrow pane shows unified and widening it brings side by side back. A diff switched from its own title bar stays side by side at any width (by design, `DiffViewer.showSideBySide`), so `app/inspector.md` now says the fallback applies to the Settings default only.
- **Tab names:** `sleep 30` names the tab and gives it no moving underline. When the command ends the tab goes back to **Terminal 1**, not the folder (by design, `handleCommandFinished`), so `app/terminals-and-tabs.md` now says so.
- **Quick switcher:** a tap of <kbd>⌥Tab</kbd> flips to the last-used workroom and back.
- **Quick Terminal:** **File ▸ Quick Terminal** opens a small window, in proportion to 800 × 500, with a shell in `~`; <kbd>⌘W</kbd> closes it.
- **`/bin/bash` 3.2:** a failed command shows no **Command failed** and no diagnosis, and the tab title stays `/bin/bash`.

### Menus and placement

- The **Update** button and its scrolling note at the trailing end of the title bar (needs a Release or Nightly build that is behind; Debug builds don't check).

### Behaviour

- After a failed teardown, "nothing is removed": the row comes back, but the workroom's terminals were already closed before the teardown ran. Check what's left and reword if needed.
- The quick switcher while held: the rail after about 250 ms, Tab and the arrows step, Esc cancels, release or click commits. (Synthetic input can't hold <kbd>⌥</kbd> while pressing Tab.)
- The <kbd>⌥§</kbd> Quick Terminal hotkey. A synthetic <kbd>⌥§</kbd> did nothing, but Workroom Nightly was running too and the key may not exist on the layout used; try it by hand.
- Dragging tabs to reorder them (a synthetic drag showed the reorder gap but the tab went back on drop; try it by hand before calling it a bug); dragging a sidebar workroom onto a pane edge shows a band and lands on that side; dragging a pane title bar or tab past the window edge makes it a window at the drop point; a popped-out pane reopens in the same place after a relaunch; <kbd>⌃⌘</kbd>-arrows pass through to a TUI at a split's edge.
- The yellow warning triangle on a project (its colour comes from the theme).
- The Dock badge, and a real macOS banner and clicking it.

### Outside Workroom

Checked 2026-10-20:

- **Minimum versions.** Claude Code's changelog adds "Program Status Protocol (OSC 7501) support" under 2.1.295; Codex's rust-v0.163.0 release notes have "Report terminal program status with OSC 7501" (#52725).
- **"About 6 seconds".** Claude Code 2.1.304 run in a pty that answers the probe: it reported `state=blocked:kind=permission` and posted its own notification (OSC 777) 6.01 s later. Answering at 3 s, it posted nothing. Its idle "waiting for your input" notification is a separate one, at 60 s (`messageIdleNotifThresholdMs`).
- **"1 to 3 seconds in".** Workroom's own timing: an unprobed request is promoted once it has waited `GRACE` (1 s), checked on the agent's 2 s tick (`screens::INTERVAL`).
- **macOS wording and paths.** macOS 27.0.1's TCC strings have “%@” would like to access data from other apps, as `help/troubleshooting.md` quotes, and System Settings has Privacy & Security ▸ Full Disk Access and ▸ Microphone. TCC also has a newer prompt, "Allow “%@” to access your “%@” data?", and a "Data Access Blocked" notice pointing to Files & Folders. Which one a terminal program triggers on macOS 27 was not seen; if it is the newer one, the troubleshooting heading needs it.

Still open:

- The microphone recovery steps (close every terminal, quit, wait about 30 seconds, relaunch) on a real update.

### Remote workrooms

- boxd and exe.dev setup sheets: the sheet covers the window while the pane row reads **Waiting for you**; ticks update live as you sign in; **Stop** stops a boxd sign-in; exe.dev's **Choose a Plan** and **Connect GitHub** website flows and **Check Again** picking them up.
- `ssh exe.dev share port` and whether a shared port is private by default.
- Containers: a container stops when the Mac sleeps and comes back when you open the workroom; image download progress on **Pull host image**; the failure messages when Docker or Apple's container system is stopped; Docker Desktop, OrbStack and Colima all work.
- Port forwarding: the same local port number comes back after a relaunch; a browser reaches a real dev server.
- Reconnecting: <kbd>⌃C</kbd> on a restored pane while the network is off; programs on a boxd or exe.dev host end when the host restarts; panes don't blink on wake when the host answers, and the retry notice looks as the page shows.
