# Docs site: checks before launch

The pages under `docs-site/` were drafted from the code and the README, never from the running app (D5). Each item below is a claim to check in the app, a detail left out because it could not be confirmed, or a place where the code and the older docs disagree. Work through it before the Codaset PR goes live, then delete this file.

## Contradictions found while drafting (resolved 2026-10-20)

- **The six README contradictions** (pull request creation, the ⌘§ Quick Terminal hotkey, install variables before `curl`, exit code 2, the 10-second lock, Delete Anyway as shipped) went with the README trim (D14). The README now links to the docs, which had the code's version of each.
- **CONTRIBUTING** put the release channel under Settings ▸ General. Fixed to Settings ▸ About, where `AboutSettingsPane` has the picker, in CONTRIBUTING.md (twice) and `macapp/AGENTS.md`.
- **`DeleteProjectSheet.swift`'s "base machine" warning is not stale.** It shows only when `project.host` is set, and a project can still record a base an older build made until `BaseRetirement` takes it down (a base it can't take down keeps its record). `RemoteWorkroomDeletionTests` pins the wording. No change.
- **Voice mode recovery:** `app/coding-agents.md` was the odd one out. `macapp/README.md` and the #368 release-note plan agree: terminals, new ones included, run under the previous version's helper while it lives, so the fix is to close every terminal, quit, wait about 30 seconds and relaunch, then check System Settings ▸ Privacy & Security ▸ Microphone. Both pages now say that, in that order.
- **Architecture:** the shipped app is universal. Every executable in v2.1.0's `.dmg` (Workroom, ghostty, workroom-session, wr-agent) and the bundled CLI is `x86_64 arm64` (`lipo -archs`), and `release.sh` refuses a release that isn't. The README and CONTRIBUTING.md no longer say Apple Silicon only; they say macOS 15 or later, like `get-started/install.md`. Whether to say Intel Macs are supported is the owner's call, since no one has checked the app on one.

## Notes: docs-site/pages/app/*

Sources are under macapp/WorkroomApp/ unless stated. "Nightly" = not in v2.1.0 (checked with `git grep ... v2.1.0`).

### Cross-cutting items to check in the running app

- Menu names: I assumed the Window menu holds "New Window", "Move pane into new window" / "Move back to main window", "Move workroom into new window" (WorkroomApp.swift CommandGroup(before: .windowSize), ~line 1558) and that Settings is "Workroom > Settings...". Settings window title is "Settings".
- Em-dashes: I removed them from prose. Real labels containing em-dashes (delete-project radio options, "No agent CLI found — ...", etc.) are paraphrased or truncated in the docs. Full delete-project labels: "Remove from Workroom only — keep all files", "Also delete N workroom(s) — permanently; branches kept", "Delete everything → Bin (project + N workroom(s))" / "Delete the project → Bin" (DeleteProjectSheet.swift ~175-190).
- The global-hotkey setting is labelled "Global show/hide hotkey (⌘§)" but also registers ⌥§ (Quick Terminal) (WorkroomApp.swift ~660-683). Debug builds register neither.

### projects.md
- Sources: AddProjectSheet.swift (labels "From existing path…", "Create new directory…", "Repository path"/"New project path", "Choose…", "Add Project"), ProjectSettingsSheet.swift (Run command, "Run automatically when a workroom is created", Base branch, Save/Cancel, run warning text), DeleteProjectSheet.swift, ProjectSidebar.swift:345-359 (context menu), :392-395 (missing folder tooltip "Project folder not found"), :466-468 (workroom warnings, text from warning.message), :809-823 (bottom "+" help "Add a project folder").
- Verify in app: File > New Project... exists (WorkroomApp.swift:1199). Hover reveals gear + "+" on project row. "Workroom hides the Run button on a missing-folder root row" (ProjectSidebar.swift ~410, canRunCommand comment). Delete sheet button labels. Delete refuses while a create runs (AppStore.deleteProject comment ~2631) and shows an error.
- Left out: what the app does on launch for a missing project beyond the warning triangle; onboarding wizard (OnboardingWindow.swift) not documented.
- Nightly: Base branch (Project Settings, feat 2026-10-09); the "+" place menu. Base branch row marked {nightly}.
- Delete project warning about remote workrooms: source text also mentions "base machine" (retired in #395); I only wrote about remote workrooms.

### workrooms.md
- Sources: NewWorkroomDialog.swift (title "New Workroom", "Filter projects", places step with back arrow help "Back (←)", places This Mac/containers/remote), PickerSplitIntent.swift (hints "⏎ create · ⌥⏎ split"), OpenWorkroomDialog.swift ("Filter workrooms"), CreationRun.swift:36-68 (step titles), CreationPane.swift (Done, "Close automatically when done", "Waiting for you"), CreationPanePresentation.swift:120-170 (failure buttons), WorkroomContextMenu.swift, WorkroomLabelSheet.swift, RootView.swift:249-285 (delete dialog "Delete 'name'?"), AppStore.swift:2560-2575 (Teardown of ‘name’ failed, Delete Anyway, Approve and Run), QuickSwitcherReducer.swift (switcher behaviour), KeyboardShortcutsView.swift.
- Verify in app: switcher behaviour (tap flips, hold shows rail after ~250 ms, Tab/arrows step, Esc cancels, release commits, click commits). ⌥⌘1-9 label is "Switch to workroom 1–9" in KeyboardShortcutsView (what it indexes: tab position vs sidebar order is NOT confirmed; docs just say "workroom 1 to 9"). "Drag a tab to reorder" for the workroom tab bar (workroomTabOrder default + TabReorderMath). Workroom tab "Close" confirmation text "Close ‘name’?". "Workroom ▸ ... A label cannot match another workroom's name" (WorkroomLabelSheetModel, not read in full). Auto-run starts "when the create succeeds" (commit 2026-10-17). Default location ~/workrooms and generated names come from README (CLI).
- Left out: the sheet shown for approving a teardown script in detail; remote create steps (container/boxd/exe.dev step lists exist in CreationRun.swift:48-65); "Retry"/progress circle on provisional sidebar rows (#483).
- Nightly: creation pane (#483), place picker (#309), Delete Anyway, Move to New Window (#444). Labels, Open/New pickers, switcher are in v2.1.0.
- README contradiction: README says "Deleting is a hover-to-trash with a confirmation; ... **Delete Anyway**" as if shipped, but "Delete Anyway" is absent from v2.1.0.

### terminals-and-tabs.md
- Sources: README (shell integration, /bin/bash caveat, copy-on-select), TerminalTabStrip.swift:1040-1200 (tab menu), GhosttySurfaceView.swift:1925-1960 (terminal right-click menu: Paste, New Terminal, Split Right/Left/Down/Up, Move to New Window/Move Back to Main Window, Close Terminal), TerminalLinkOpener.swift + ExternalEditor.swift (editors: Visual Studio Code, Zed, Xcode), TerminalSearchBar.swift, DetachedSessionsButton.swift (popover "Detached terminals", buttons "Active tab", "New tab", "Stop"), TerminalStatusBar.swift:72, TargetDetailToolbar.swift:120-200 (Run controls, tooltips), QuickTerminalController.swift, SettingsView.swift Terminal pane, docs/program-status.md (shell list zsh, bash, fish, elvish, nu).
- Verify in app: where the new-terminal button sits; Quick Terminal opens in ~ (home); File > Quick Terminal item; the pane footer folder-path click offers copy/reveal (TerminalStatusBar.swift cwdSegment comment, item titles not read); toast on run exit (AppStore+RunCommand.swift:35-70, comment only); "Press Stop a second time to force-quit" (tooltip "Stop the run command (⇧⌘R) — again to force-quit").
- Left out: what exactly leaves a session "detached" (not stated in code I read); pointer shapes (#466); tab "Keep Open" for previews (in inspector page only).
- Nightly: Stop Detached Terminals… button, always-persist terminals. v2.1.0 had "Persist sessions" toggle (SettingsView.swift:368 at v2.1.0). The Detached sessions button itself is in v2.1.0.
- README contradiction: README Key Features says Quick Terminal's global hotkey is ⌘§; code says ⌥§ (⌘§ is show/hide).

### splits-and-windows.md
- Sources: WorkroomApp.swift View/Window menus, KeyboardShortcutsView.swift (⌃⌘ arrows, ⌃⌘O), PaneTitleBar.swift:261-285 (tooltips "Move to new window", "Split right (⌘D)", "Split down (⇧⌘D)", "Close (⌘W)"), DetachedPaneController.swift (red button/⌘W close the pane; "Move Back" toolbar button, tooltip "Move this pane back to the main window"), SettingsView.swift Appearance pane, WorkroomWindowDrag.swift, AppStore+WindowMove.swift, ProjectSidebar.swift (drag a row onto a pane to split, comment issue #101).
- Verify in app: dragging a sidebar workroom onto a pane edge shows a drop band; dragging a pane title bar or tab past the window edge pops it out (DetachedPaneController doc diagram); popped-out pane restored on relaunch (session.json detachedFrame); confirmation when a process is running; ⌃⌘ arrows pass through at a split's edge (comment on isAppShortcut).
- Left out: window size of new windows; behaviour of dragging terminals (not panes) between windows beyond README text.
- Nightly: moving a workroom between windows (#444). Pop-out (#172) is in v2.1.0.

### inspector.md
- Sources: ActivitySection.swift, ChangesPanel.swift (confirm dialog "<action> with uncommitted changes?", message "Your uncommitted changes will be stashed and reapplied after the rebase.", commit button help "Commit changes…"/"Nothing to commit", PR actions menu), HistoryPanel.swift, FilesPanel.swift, ChangesetDetailView.swift, CommitSheet.swift + CommitDraft.swift, VCSToolbar.swift + VCSSyncPresentation.swift (Publish branch / Pull ... with rebase / Push / "Fetch from the remote"), PullRequestPanel.swift (gh warning copy), WorkroomStatus.swift PRAction labels, PRMergeMethod.swift, WorkroomApp.swift Source Control menu.
- Verify in app: sync button wording per state; Source Control shortcuts ⌥⇧⌘F / ⇧⌘P / ⌥⇧⌘P; "Workroom actions" menu contents; merge confirmation is a confirmationDialog (PullRequestPanel.swift:404); rename/moved file tooltips.
- Left out: unified/side-by-side narrow fallback exact width; conflict-resolution UI; "Merge" chip/diverged expander in History.
- README contradiction: README Key Features says "Pull Requests: create, view, and manage pull requests directly from each workroom". I found no PR creation in macapp (grep "gh pr create", "createPullRequest" finds nothing); the panel views, marks ready, converts to draft, closes, reopens and merges. The page says Workroom does not create PRs and suggests `gh pr create`.
- Nightly: Details pane and workroom header. Everything else is in v2.1.0.

### details-and-ports.md (nightly: true)
- Sources: DetailsPanel.swift (labels "Running on", "Machine Name", "Path"/"Path on its host", "Ports", "New port number…", tooltips "Forward a port from this workroom's container", "Stop forwarding port N", "Copy localhost:N", messages "No agent is connected." / "Not connected. A forward reconnects when it is used.", "Select a workroom to see where it runs."), README "Ports in container workrooms".
- Verify in app: where "Details" icon sits in the activity bar (first in ActivitySection.allCases); Ports list only for container workrooms (DetailsPanel.ports).
- Left out: devcontainer.json fields, port limit 32, requireLocalPort (left to remote/port-forwarding page).

### notifications.md
- Sources: ActivityBar.swift:147-200 (bell, tooltips, ⌘-click), NotificationsList.swift, MenuBarController.swift + MenuBarNotificationsView.swift, docs/program-status.md (all program-status and command-result content), WorkroomApp.swift Go menu, SettingsView.swift Notifications pane.
- Verify in app: bell location (WindowFooter, right side), "×N" repeat count, unread dot on tab and project, banner behaviour when Workroom is not frontmost (README), glyph descriptions (hand.raised.fill, checkmark.circle.fill, red mark) as shown on screen; Dock badge count.
- Left out: protocol details (probe, record limits, key table), known limits section, troubleshooting `wr-agent program-status`, test steps. Linked the protocol spec URL from docs/program-status.md.
- Nightly: program status marks, alerts, Go to Terminal That Needs You (⇧⌘M), command result (#473), Notifications settings pane. Bell, menu bar item and ⇧⌘N are in v2.1.0.

### coding-agents.md
- Sources: TerminalStatusBar.swift:248-286, TerminalCodingAgentBanner.swift, CodingAgentBannerViewModel.swift (headlines), SettingsView.swift AI Agents pane, WindowFooter.swift, CodingAgentUsageSegment.swift (Enable usage…, Don’t Ask Again, Repair, Remove, +N), CodingAgentUsageDetailView.swift (Session/Weekly), CodingAgentSettingsPane in SettingsView, project.yml:244-250, Info.plist NSMicrophoneUsageDescription, macapp/README.md (voice recovery), commit 590697d95.
- Verify in app: the failed-command indicator in the pane footer reads "Command failed (exit N)"; Diagnose button visibility rules; whether Investigate is shown always; pane-footer usage hidden for remote workrooms (TerminalStatusBar.swift:68 `!target.isRemoteWorkroom`); cswap label format "alias #slot".
- Left out: "✦ badge on the tab" (a code comment says diagnosis adds one; not confirmed visually); how usage polling works; Codex 0.163/Claude 2.1.295 version checks (only in notifications page).
- Memory note (owner): release notes for the mic entitlement mention closing all terminals, quitting and relaunching if no prompt; the docs follow macapp/README.md (open a new terminal, then check System Settings) instead.
- Nightly: usage (#480), AI Agents pane name, Codex alerts (#481), voice/microphone (not in v2.1.0). Failed-command diagnosis is in v2.1.0 (pane named "Agent" there).

### settings.md
- Source: SettingsView.swift (all panes), SettingsPane.swift (labels General, Notifications, Appearance, Terminal, AI Agents, About), ReleaseChannel.swift (Stable, Pre-release), Theme.swift (System, Light, Dark), DiffViewMode.swift (Unified, Side by Side), DefaultsKeys.swift (defaults: copyOnSelect true, confirmOnQuit true, globalHotkey true, dimUnfocusedPanes true, usageInWindowFooter true, usageInPaneFooter false).
- Verify in app: "Workroom ▸ Settings…" path; hover help texts; the Claude usage Enable… row only appears after "Don’t Ask Again".
- Left out: the switcher modifier preferences (no Settings UI; DefaultsKeys.swift:221), container CPU/memory and host image keys (no UI found in SettingsView).
- Differences from v2.1.0: no Notifications pane (menu bar toggle in General), "Agent" pane name, "Persist sessions" instead of Stop Detached Terminals…, no New Workrooms section.

### updates-and-channels.md
- Sources: SettingsView.swift About pane, ReleaseChannel.swift, UpdateAvailableButton.swift (Update/Updating…, note text), CONTRIBUTING.md:610-640, 660-690 (Nightly product, artifact names), README.md (workroom update), docs-site/pages/cli/workroom-update.md, install.sh.
- Contradiction: CONTRIBUTING.md says the release channel setting is at "Settings ▸ General ▸ Release channel"; the code (SettingsView.swift About pane) and v2.1.0 put it in Settings ▸ About. The docs say About.
- Verify in app: the Update button location ("trailing title bar" per code comment), the nightly download URL (the nightly prerelease on the releases page), nightly version format example `2.2.0-nightly.1234` (derived from CONTRIBUTING; the example number is illustrative).
- Nightly: the "Safe to update" note (#505). The Update button itself is in v2.1.0.

## Notes: docs-site/pages/remote/*

### overview.md
Check in the running app:
- New Workroom menu: "+" on project row, context menu "New Workroom", and Cmd-N picker then a places list. Entries: "This Mac", section "Local containers" (Docker, Apple Container), section "Remote" (boxd, exe.dev); unusable entries dimmed with a reason (ProjectSidebar.swift:206-245, NewWorkroomDialog.swift WorkroomPlace).
- Step titles per kind (CreationRun.swift plan, ~line 40-70); "Copy local files" only with .worktreeinclude, "Run setup script" only with a script.
- Failure footer buttons "Try Again", "Close", "Open Anyway", "Delete Workroom…" (CreationPanePresentation.swift).
- Details pane facts "Running on", "Machine Name", "Path on its host" (DetailsPanel.swift:30-40); shortcut Opt-Cmd-I (WorkroomApp.swift:1446).
- Delete confirmation text "This destroys the workroom's remote machine and everything on it, including changes and commits that aren't pushed." (RootView.swift:267); Delete Anyway (AppStore.swift:2569).
- Claimed: CLI `workroom delete` refuses a remote workroom with a live host (ADR 0040, README error codes).
- Claimed: deleting a project destroys its remote workrooms in every scope (DeleteProjectSheet.swift:68-76). That sheet's copy still mentions "its base machine" (stale vs CONTEXT.md, which says bases were removed in #395). Possible contradiction; the docs page does not mention bases.
- Claimed: Release and Nightly share boxd/exe.dev hosts, containers stay with the build (RemoteWorkrooms.swift ownsHost, ADR 0036); error text in Failure.anotherBuildsHost.
- Left out: wakefulness behavior of boxd/exe.dev beyond "Workroom doesn't keep awake / put to sleep" (ADR 0017). Costs/prices: not stated anywhere, left out.
- WORKROOM_HOST values local/boxd/exedev/docker/apple from README environment table.

### boxd.md
- Sheet title "Set up boxd"; steps Install / Account / GitHub; buttons "Install boxd", "Try Again", "Sign In", "Open the Sign-In Page Again", "Stop", "Connect GitHub", "Open GitHub Again", "Check Again", "Cancel", "Create Workroom" (BoxdSetupSheet.swift, RemoteSetupSheet.swift).
- "Check boxd account" row shows "Waiting for you" while the sheet is up (CreationPanePresentation.trailing, design boxd-first-time-setup "Since #483"). Not seen live.
- Cancel removes the pane; closing sheet cancels setup (RemoteSetupSheet comment, design doc). Not seen live.
- Credential hint command `boxd manage integrations connect git` (RemoteWorkrooms.swift credentialHint).
- Left out: boxd org/account handling, hibernation/standby details, Billing step (design says boxd gets no Billing step; intro only says "payment is required").
- "Create Workroom enabled when a check can't answer" from BoxdSetupSheet doc comment and .unknown cases.
- I wrote "Under Remote, choose boxd"; the "Done" button / "Close automatically when done" taken from README.

### exe-dev.md
- Sheet "Set up exe.dev"; steps Account / Plan / GitHub; buttons per ExeDevSetupSheet.swift ("Create SSH Key", "Try Again", "Send Link", "Use a Different Email", "Sign Up in a Terminal Instead", "Finish Signing Up in a Terminal", "Use the Email Form", "Choose a Plan", "Open exe.dev Again", "Check Again", "Connect GitHub"). I did not list "Finish Signing Up in a Terminal" (shown after an email error).
- Claimed: Workroom adds an exe.dev GitHub integration per repository on first exe.dev workroom, public repos still work, private fails at clone (ADR 0049).
- exe.dev hint text and `ssh exe.dev integrations list` / `auto:all` from credentialHint.
- Not verified: the Plan/GitHub steps' website flows.

### containers.md
- Requirements from RemoteWorkrooms.unavailability(of:) (not installed / run gh auth login / needs Apple silicon / needs macOS 26), runtimeCandidates and appleCandidates paths, Failure strings, ContainerHostDriver.runtimeDown strings.
- RemoteSetupSheet is only the shared shell of the boxd/exe.dev sheets; containers have no setup sheet, so the page does not describe one.
- Apple default resources (half cores, quarter memory, 2-8 GB): RemoteWorkrooms.resources. The hidden defaults containerCPUs, containerMemory, remoteHostImage are left out on purpose.
- "Image pull progress on the project's row": ContainerHostDriver.swift:122 comment; not seen.
- Container stops when Mac sleeps (ADR 0039), started on open (remote-host-states.md "Stopped container"). Not tested live.
- Relay: anything in the container can use the Mac's gh access (ADR 0039).

### port-forwarding.md
- README "Ports in container workrooms" section is now lines 714-753 (task said 657-696). Content lifted from it plus DevContainerPorts.swift (paths, 32 cap, 256 KiB file cap not mentioned) and DetailsPanel.swift (button help "Forward a port from this workroom's container", "Stop forwarding port N", placeholder "New port number…", messages).
- "the Ports list says only the first 32 are forwarded": message is "<path> declares N ports; only the first 32 are forwarded." (AgentPortForwarding.swift:1177).
- ::1 and 127.0.0.1: commit b60bd4c58.
- "Ports kept across relaunch": commit a004c41e7 means the same port NUMBER is reclaimed (SO_REUSEADDR) at the next launch; the list itself is not persisted (DetailsPanel comment, README "once per launch"). The docs say so. Hand-added ports not remembered: from the DetailsPanel comment "Nothing is persisted across launches".
- Left out: what happens when a declared forward fails because the port is taken (exact message text), a file too large or refused.
- boxd / exe.dev commands from README only (not run).

### reconnecting.md
- Retry notice text: SSHTransport.retryNotice; waiting line `workroom: waiting for this terminal's host...` (attachWrapper, erased once ssh is in).
- Backoff 1 s doubling to 30 s, forever; 5 refusals within 30 s stop (RemoteReconnectBackoff, GhosttySurfaceView.swift:2279).
- Wake/network: RemoteLinkMonitor.swift; 2 s deadline (RemoteHosts.answerDeadline); containers left alone.
- Ctrl-C: GhosttySurfaceView.reconnectIfTheLinkDropped comment (#507). Not tried live.
- Host restart: ADR 0027 (supervised agent), ADR 0046 (an ended pane shows its last screen / "ended", remote user opens a new tab). The exact on-screen wording for an ended pane is not confirmed, so the page paraphrases it.
- Not confirmed: whether boxd/exe.dev programs always die on host restart (assumed, processes end with a reboot).
- "May be out of date: reconnecting…" is ProgramStatusPresentation.staleLine; where it shows (tooltip) not checked.
- Link to ../help/troubleshooting.md assumes that page exists.

## Notes: reference + help pages

### reference/json-output.md
- Sources: internal/errs/errs.go registry (kinds + exit codes), cmd/json.go, cmd/jsonlog.go, cmd/create.go, cmd/list.go, cmd/root.go, testdata/contracts/*.
- Nightly (not in v2.1.0, checked with git grep v2.1.0): step events (71a5a3422), `warning` on created event/create, ScriptNotTrusted + `script` object (8b9a126ed), BaseBranchNotFound, ProjectNotFound, WorkroomNotFound, WorkroomExists, InvalidHostDescriptor, list `base_branch`, base set/clear, trust commands in --json. Kinds NotADirectory, UnsafeDeletePath are in v2.1.0.
- Not verified live: exit code of an unknown flag in --json mode (code says unrecognised errors map to 1/InternalError; README says "2 usage"). README "usage/validation 2" only truly applies to ConfirmationMismatch, UnsafeDeletePath, InvalidHostDescriptor.
- README lists `DirExists / WorkspaceExists` etc. but omits NotADirectory, UnsafeDeletePath, ProjectNotFound, WorkroomNotFound, WorkroomExists, InvalidHostDescriptor; I added them from the registry.
- Left out: `delete-project`, `add-project` field shapes; `include-archive` and `host` descriptors schema (app-owned).
- `cli_version` examples use v2.1.0 (README said v2.0.0).

### reference/config-json.md
- Sources: internal/config/config.go (reservedKeys, WorkroomsDir, withLock 30 s backstop, atomic Write, unknown keys round-trip per decodeProject comment), README ~698/760, CONTRIBUTING ~332.
- Contradiction: README troubleshooting says a stale lock "self-heals after ~10s, or delete it manually"; code uses flock released by kernel and a 30 s backstop (CONTRIBUTING agrees with code). I wrote the code version.
- Claim "unknown keys are kept on rewrite": inferred from Read/Write working on map[string]any and the Project doc comment; not tested live.
- Claim "existing workrooms keep their path when workrooms_dir changes": each entry stores `path` (AddWorkroom); not run.
- `channel` values stable/pre from cmd/update.go help. `channel` key is in v2.1.0; base_branch, trusted_scripts, WORKROOM_CONFIG are Nightly.
- Left out: Dev build config location (~/Library/Application Support/Workroom/<bundle id>/config.json), remote "bases", claim-provisioned.

### reference/environment-variables.md
- Sources: internal/script/script.go:46-52, RemoteProvisioning.swift:285-336 (hostKind: docker, apple, boxd, exedev; env passes only NAME/PATH/HOST), run_script.rs:1-34/202 and tests (env_remove ROOT_PATH/PARENT_DIR), ShellEnvironment.swift:140,175,193 (3 s timeout, denylist keeps PROBE out of script), cmd/create.go:122,178 (EDITOR, --no-editor), install.sh:85-135, install.ps1:39-47, WorkroomCLI.swift:614 / WorkroomApp.swift:42 (WORKROOM_CONFIG).
- WORKROOM_HOST is Nightly (absent in v2.1.0). WORKROOM_SHELL_PROBE on the app side is in v2.1.0; the remote-host probe is Nightly. EDITOR is not offered with --json (create's JSON branch returns before the editor code).
- Check in app: that the 3 s probe timeout is what a user sees; the README says ".zshrc ending in exec tmux, fish and nushell" fall back (copied).
- install.ps1 reads VERSION and WORKROOM_CHANNEL but not WORKROOM_INSTALL_PATH (grep only found those two).

### reference/keyboard-shortcuts.md
- Copied verbatim from KeyboardShortcutsView.swift groups. Switcher defaults: DefaultsKeys.swift:226-229 (.option, .control) and SwitcherModifier.display (QuickSwitcher.swift:57): ⌥⇥ and ⌃⇥.
- NO Settings UI exists for the switcher modifiers (DefaultsKeys.swift comment "No Settings UI yet", grep found none). I did not name a setting or a `defaults write` command.
- Menu location: "Keyboard Shortcuts…" is in the app (Workroom) menu just below Settings… (WorkroomApp.swift:1307-1315). The Help menu (D26) now has it too, and the page names both.
- More section (all confirmed in WorkroomApp.swift): History ⌥⌘Y 1390, Files ⌥⌘F 1431, Details ⌥⌘I 1446 (Nightly only: "Details" absent in v2.1.0), Fetch ⇧⌥⌘F 1518, Push ⇧⌘P 1521, Pull with Rebase ⇧⌥⌘P 1524. Not added: Last-used items menu names ("Last-Used Workroom") differ in capitalisation from the sheet; sheet wording used.
- `KeyboardShortcutsDocsTests` checks each catalog row is on the page; it has not been run yet (`make app-test`).

### help/troubleshooting.md
- From README Troubleshooting (VCS, in-workroom, setup failed, not trusted, update dev build, branch left, list warnings, bash 3.2, gh >= 2.57.0, config lock) plus the extras.
- Check in app: "Project folder not found" tooltip (ProjectSidebar.swift:395). The fix "put it back at the same path, or remove the project from the sidebar" is inferred from config keying by path; the remove route was not confirmed against a menu label.
- Check in app: Approve / Cancel / Approve and Run / Delete Anyway / Delete Without Teardowns / Open Anyway labels come from README, not re-read in Swift.
- Mic section: entitlement and the "no prompt, no error" behaviour from macapp/project.yml comments (~245). The "close every terminal, quit, wait about 30 s, relaunch" recovery is from PR #368 notes in project memory, not code. The Privacy & Security ▸ Microphone path is standard macOS, unverified in Workroom. Marked Nightly (d076a96b not an ancestor of v2.1.0).
- FDA section: project.yml comment says no entitlement suppresses the prompt, grant Full Disk Access. Prompt text "would like to access data from other apps" quoted from that comment.
- Remote section: HostDestroyed warning (list.json contract), wake/network reattach (docs/remote-host-states.md, #506, Nightly), opening starts a stopped container (same doc). Nightly. "Opening wakes a boxd host" was removed: Workroom doesn't manage a host's wakefulness.
- Left out: remote host unreachable fixes beyond Delete Anyway; boxd/exe.dev sign-in problems; Apple container runtime missing.

### help/release-notes.md
- WhatsNewSheet.swift: title "What’s New in Workroom", "View on GitHub ↗", "Done". Shown automatically on first launch after an update (comment). Left out: any menu item to reopen it (none found).
- Check in app: Nightly "updates itself" (README: self-updates within nightly).
