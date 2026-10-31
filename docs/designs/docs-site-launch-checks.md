# Docs site: checks against the app

The pages under `docs-site/` were drafted from the code and the README, never from the running app (D5). On 2026-10-20 every page's claims were checked against the code: about 390 matched it, 39 were wrong and were fixed, and the items below are what only the running app (or a real provider) can settle. Work through them, then delete this file.

## Contradictions found while drafting (resolved 2026-10-20)

- **The six README contradictions** (pull request creation, the ⌘§ Quick Terminal hotkey, install variables before `curl`, exit code 2, the 10-second lock, Delete Anyway as shipped) went with the README trim (D14). The README now links to the docs, which had the code's version of each.
- **CONTRIBUTING** put the release channel under Settings ▸ General. Fixed to Settings ▸ About, where `AboutSettingsPane` has the picker, in CONTRIBUTING.md (twice) and `macapp/AGENTS.md`.
- **`DeleteProjectSheet.swift`'s "base machine" warning is not stale.** It shows only when `project.host` is set, and a project can still record a base an older build made until `BaseRetirement` takes it down (a base it can't take down keeps its record). `RemoteWorkroomDeletionTests` pins the wording. No change.
- **Voice mode recovery:** `app/coding-agents.md` was the odd one out. `macapp/README.md` and the #368 release-note plan agree: terminals, new ones included, run under the previous version's helper while it lives, so the fix is to close every terminal, quit, wait about 30 seconds and relaunch, then check System Settings ▸ Privacy & Security ▸ Microphone. Both pages now say that, in that order.
- **Architecture:** the shipped app is universal. Every executable in v2.1.0's `.dmg` (Workroom, ghostty, workroom-session, wr-agent) and the bundled CLI is `x86_64 arm64` (`lipo -archs`), and `release.sh` refuses a release that isn't. The README and CONTRIBUTING.md no longer say Apple Silicon only; they say macOS 15 or later, like `get-started/install.md`, and name no architecture (owner, 2026-10-20). ADR 0061 (2026-10-30) later made the app Apple silicon only, so they say so again.

## App fixes found by the check (done 2026-10-20)

- **"Diagnose with" did nothing.** The setting was never read: diagnosis and Investigate both always ran `claude`. The owner chose to keep the automatic diagnosis Claude-only (decision X1: `codex exec` still has no tools-off mode in 0.163) and have the setting pick the agent **Investigate** opens. It is now **Investigate with**; Auto is Claude, else Codex, and with Claude Code missing the banner still offers Investigate with Codex. The caption and the not-found message say so, and `app/coding-agents.md` and `app/settings.md` match.
- **The Stop button's tooltip** promised a second-press force-quit that doesn't exist. It now reads "Stop the run command (⇧⌘R)".
- **Checked in the running app (Dev build of 8b4e71bec).** The red **Command failed (exit 1)** sits after the branch in the pane footer. The **Investigate with** picker and its caption read as `app/settings.md` says. With Claude installed, Diagnose gives a fix and **Investigate** opens `codex` when Codex is the pick. With `claude` off the PATH, the footer reads "Claude Code CLI not found — it runs the diagnosis". **Investigate** then opens `codex` under Auto, and there is no button under Claude. With neither CLI, it reads "No agent CLI found — install Claude Code or Codex" and offers nothing. That matches `app/coding-agents.md`.

## Needs the running app

Each is a claim the code supports but can't prove on its own. Look, and fix the page if it differs.

### Checked in the running app (Dev build, 2026-10-20)

- **Menus:** **Settings…** is in the app menu; The Window menu has **New Window** and **Move pane into new window**; **Move Workroom into New Window** is now in the Room menu.
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

- **Update button (2026-10-20).** No installed build was behind (Nightly 1920 and stable 2.1.0 are both their feeds' latest), so the Dev app was relaunched with `-WorkroomUITestUpdateAvailable 1`, which fakes a 9.9.9 update. The accent **Update** pill sits at the trailing end of the title bar, left of the theme buttons; the note beside it scrolls "Safe to update: workroom terminals keep running. Run commands and the Quick Terminal stop.", as `app/updates-and-channels.md` quotes; its tooltip reads "Update to 9.9.9 — click to install". Still by hand, on the next Nightly that is behind: clicking it opens Sparkle's prompt, and the pill reads **Updating…** while it downloads.

### Behaviour

Checked 2026-10-20:

- **Failed teardown.** `deleteWorkroom` stops the run command and reaps the terminals (ending their sessions) before the script runs, so a failed teardown brings the row back with its folder and branch (or its host) but no terminals. `app/workrooms.md` and `remote/overview.md` now say so instead of "nothing is removed". The workroom's label is also dropped by the optimistic removal and not restored; left as is, since the user is deleting it.
- **⌃⌘-arrows at a split's edge** never reached the program: libghostty's macOS defaults bind ⌃⌘-arrows to `resize_split`, which Workroom ignores (measured with a raw key reader in kitty mode: only the modifier events arrived). Owner chose wrap-around: at the edge, focus moves to the farthest overlapping pane the other way (`PaneTreeLayout.adjacentPane`, with tests, red-proofed). `app/splits-and-windows.md` says so. Seen in the rebuilt Dev app: in a two-pane split, ⌃⌘→ from the right pane focuses the left one, ⌃⌘← from the left focuses the right, and ⌃⌘↑ leaves focus where it is.
- **Popped-out pane:** moved, quit and relaunched; it reopened at the same place.
- **Waiting alert:** a 7501 `blocked` report in a background workroom showed "Terminal 9 in emoji needs you" in the app, and the menu bar item counted 1.
- **Warning triangle:** drawn in the theme's `warning` token (its yellow, else bright yellow, else system yellow), so "yellow" stands.

Still open, by hand:

- The quick switcher while held: the rail after about 250 ms, Tab and the arrows step, Esc cancels, release or click commits. (Synthetic input can't hold <kbd>⌥</kbd> while pressing Tab.)
- The <kbd>⌥§</kbd> Quick Terminal hotkey. A synthetic <kbd>⌥§</kbd> did nothing, but Workroom Nightly was running too and the key may not exist on the layout used.
- Dragging tabs to reorder them (a synthetic drag showed the reorder gap but the tab went back on drop); dragging a sidebar workroom onto a pane edge shows a band and lands on that side; dragging a pane title bar or tab past the window edge makes it a window at the drop point.
- The Dock badge (drawn into the tile's view, so `lsappinfo` can't read it), and a real macOS banner and clicking it. The Dock and Notification Centre can't be seen or clicked through computer use.

### Outside Workroom

Checked 2026-10-20:

- **Minimum versions.** Claude Code's changelog adds "Program Status Protocol (OSC 7501) support" under 2.1.295; Codex's rust-v0.163.0 release notes have "Report terminal program status with OSC 7501" (#52725).
- **"About 6 seconds".** Claude Code 2.1.304 run in a pty that answers the probe: it reported `state=blocked:kind=permission` and posted its own notification (OSC 777) 6.01 s later. Answering at 3 s, it posted nothing. Its idle "waiting for your input" notification is a separate one, at 60 s (`messageIdleNotifThresholdMs`).
- **"1 to 3 seconds in".** Workroom's own timing: an unprobed request is promoted once it has waited `GRACE` (1 s), checked on the agent's 2 s tick (`screens::INTERVAL`).
- **macOS wording and paths.** macOS 27.0.1's TCC strings have “%@” would like to access data from other apps, as `help/troubleshooting.md` quotes, and System Settings has Privacy & Security ▸ Full Disk Access and ▸ Microphone. TCC also has a newer prompt, "Allow “%@” to access your “%@” data?", and a "Data Access Blocked" notice pointing to Files & Folders. Which one a terminal program triggers on macOS 27 was not seen; if it is the newer one, the troubleshooting heading needs it.

Still open:

- The microphone recovery steps (close every terminal, quit, wait about 30 seconds, relaunch) on a real update.

### Remote workrooms

Checked 2026-10-20:

- **Publishing a port.** exe.dev's docs: `ssh exe.dev share port <vm> <port>` changes the port its proxy serves and keeps the visibility, private by default; `share set-public` makes it public. Its proxy also serves ports 3000 to 9999 privately at `https://<vm>.exe.xyz:<port>/` with no command, so `remote/port-forwarding.md` now says so and gives the arguments. boxd's `boxd machine proxy --help` reads "Publish machine ports on the public internet", as the page says.
- **Runtime stopped.** Apple's `container` 1.5.0 with its service stopped prints "XPC connection error" and `container system start`, which Workroom reads as the runtime being down, so the page's message is right. Docker 29.8.1 prints "failed to connect to the docker API" for a stopped daemon and "permission denied while trying to connect to the docker API" for a socket it can't open. Workroom only knew the older "Docker daemon" wording, so a create with Docker stopped said "couldn't download the workroom host image. Check your network connection", and an unopenable socket said the registry refused the image. Fixed in 117b3b029 (`ContainerHostDriver.runtimeDown`, with `RuntimeDownTests`).
- **Port numbers after a relaunch.** `AgentPortForwarding` tries the declared number first and only takes another when the Mac holds it, which matches the page. Not seen in the running app.
- **Sleep.** Dropped (owner, 2026-10-20): the docs no longer say how a container behaves when the Mac sleeps or restarts, only that Workroom creates it, starts it when you open its workroom, and stops and removes it on delete (`ContainerHostDriver` runs `start` and `rm --force`/`delete --force`, never `stop`).

Still open, by hand:

- **Setup sheets.** These need a signed-out boxd or a new exe.dev account. Check that the sheet covers the window while the pane row reads **Waiting for you**, that the ticks update live as you sign in, and that **Stop** stops a boxd sign-in. On exe.dev, check the **Choose a Plan** and **Connect GitHub** flows on the website, and that **Check Again** picks them up.
- **Container live checks.** Image download progress on **Pull host image** (needs the image removed, which the running container holds). The new Docker message with Docker Desktop really quit. OrbStack and Colima (neither is installed here).
- **Port forwarding live.** A browser reaches a real dev server in a container workroom, and the same local port comes back after a relaunch.
- **Reconnecting.** <kbd>⌃C</kbd> on a restored pane while the network is off. Programs on a boxd or exe.dev host end when the host restarts (a paid machine). Panes don't blink on wake when the host answers. The retry notice looks as the page shows.
