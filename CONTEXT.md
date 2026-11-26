# Workroom

Workroom is a native macOS app for working on several branches of a git project at once. Each branch gets its own workroom, a git worktree with its own terminals, history and diffs. One Rust binary, `workroom`, is the engine under the app: its commands do every project and workroom operation, and run as the daemon (`workroom serve`) it keeps terminal sessions alive and serves version control and file reads, on this Mac or on a remote host (ADR 0078).

## Naming rules

- **workroom** names the binary, the CLI the app bundles and a host runs; a **command** is `workroom <command>` (`workroom create`, `workroom sessions`). "workroomd" (the Rust daemon's binary before ADR 0078) and "Go CLI" (the CLI before it, retired by #682) survive only as old names: in older code and history, the crate's folder `vcs/crates/workroomd`, and the daemon's file on a host.
- **Daemon** means the Workroom daemon, the `workroom serve` role, and nothing else (renamed from "the agent" by #525, ADR 0057). Claude and Codex are **coding agents**; names for them say `CodingAgent` (`CodingAgentRunner`, `TerminalCodingAgentManager`). Bare "agent" names nothing: say daemon or coding agent. The retired Swift `workroom-session` is the **legacy session helper**, never a daemon.
- **Host** is the one word for remote compute. Do not call one a machine, a box, a VM or a base. Provider-facing names (boxd and exe.dev call theirs machines and VMs, Railway calls its sandboxes) and older code keep their words; new names say host.
- **Base** means a base branch only. It no longer names a machine that remote workrooms are derived from.
- Use the terms below in code, issues, tests and docs. A name that is not here either belongs to one of the contexts below or is a gap to add.

## Workroom management

Owns projects, workrooms, setup and teardown, and the labels the sidebar shows. The `workroom` binary's commands are the engine; the app is a client of their `--json` contract.

**Project**:
A git repository registered with Workroom, identified by its canonical path.

**Workroom**:
A branch of a project, `workroom/<name>`, that Workroom creates for one line of work, with its own terminals. On this Mac it is a linked git worktree; on a host it is its own clone.
_Avoid_: Workspace

**Root**:
A project's own checkout, shown in the sidebar beside its workrooms.

**Target**:
A root, a workroom, a terminal group or a standalone terminal, as the thing a window selects and opens terminals in. A create's pane before its workroom has a name is one too (`TargetID`).

**Base branch**:
The branch a new workroom starts from, set per project or for all projects.
_Avoid_: Base (alone)

**Start point**:
The commit a new workroom's branch starts from: the remote's copy of the base branch, or the local branch when the user includes local work.
_Avoid_: start ref, base commit

**Create question**:
A create that stops to ask the user something before anything exists: whether to approve its setup script, or where it starts when the root has local work. Answering continues the same create from its start point; it is not a Try Again, which starts over and reads the base branch afresh.
_Avoid_: retry, restart (for an answered question)

**Setup script**, **Teardown script**:
The project's hooks, `scripts/workroom_setup` and `scripts/workroom_teardown`, run inside a workroom when it is created and before it is deleted, on every kind of workroom: the CLI runs them locally, the app runs them on a remote workroom's host through `workroom run-script`. A failed teardown stops the delete; **Delete Anyway** deletes without it.

**Trusted script**:
A setup or teardown script whose exact contents this Mac has approved, recorded per project. Workroom runs no other script, except a root copy that git ignores, which never arrives by a pull. A changed script needs approving again. Only a person approves one: `workroom trust` run under a coding agent (one of its parent processes is `claude` or `codex`) approves nothing and is `NeedsTheUser`, as are `delete` and `delete-project` (#793).
_Avoid_: allowed script, whitelisted script

**Include file**, **Included files**:
The include file is the root's `.worktreeinclude`, a list of `.gitignore`-style patterns. The included files are the root's gitignored files that match it, such as `.env`, copied into every new workroom, on this Mac or on a host.
_Avoid_: Shared files, synced files

## Version control

Owns repositories, changesets, diffs, history, working status, and the commit and pull request actions. Local reads and reads routed through a host's daemon answer the same questions.

**Repository**:
The git data behind a project or a workroom, wherever it is read from.

**Changeset**:
The files one commit changes, with its message and authors. The working tree's changes are shown as Changes, not as a changeset.

**Diff**:
The patch for one file in a changeset.

**History**:
The log of commits on a workroom's branch.
_Avoid_: Navigation history (a different thing, see App shell)

**Working status**:
Whether a workroom's working copy has uncommitted changes, and how many lines they add and remove.

## Terminal

Owns panes, tabs, splits, sessions, surfaces and run commands. The terminal is libghostty, and sessions outlive the panes that show them.

**Tab**:
One terminal, or one diff, file or changeset view, opened in a target.

**Terminal name**:
What a terminal is labelled with: the name the user gave it, kept across a quit, or else the title its program sets, or else its program and folder, `<program> <folder>` ("zsh ~/dev/workroom", "claude ~/workrooms/calm-dune"), drawn with the program bright and the folder faded, and joined by a space wherever it is plain text. The program is the terminal's foreground process by its short name; the folder is the shell's live folder, else where it started, in full with the home folder as `~`. This holds for every terminal, in a workroom or the Terminals section, and nothing numbers two alike apart. Any terminal can be renamed.

**Standalone terminal**:
A terminal that belongs to no project and no terminal group, with a sidebar row and a workroom tab of its own. It runs on this Mac, starts in the folder the user chose for them, and comes back after a quit like a workroom's terminals. It has no version control of its own, but its inspector follows its shell's folder and the git repository that folder is in. The app calls it just a terminal; say standalone where it must be told apart.
_Avoid_: Loose terminal, free terminal

**Terminal group**:
A set of terminals belonging to no project, with its own starting folder. A window selects and uses one as it does a workroom, but no branch or worktree backs it, so it has no version control, run commands or host of its own. Its inspector follows the focused terminal's folder, and the git repository that folder is in, as a standalone terminal's does. The user makes one by splitting a standalone terminal, dropping one standalone terminal on another, or asking for a new one. Until it is named it is numbered ("Group 1", the lowest number free when it was made, kept while it lasts; never its terminals' titles, which change) and goes when one terminal is left, which becomes standalone again. Named or not, a group goes with its last terminal across every window, but never at a quit. The Quick Terminal's group is never deleted. Deleting one makes its terminals standalone.
_Avoid_: Group (alone), workroom (for a terminal group)

**Split**:
A tree that lays several of a target's tabs, or several workrooms in a window, out side by side or stacked.

**Pane**:
The area on screen that shows one tab.

**Pane footer**:
The strip along the bottom of a pane about that pane alone: its tab's live state and the coding agent running in it.
_Avoid_: Status bar, terminal footer

**Pane host**:
What a pane asks about where it is shown, and acts through: the workroom window it belongs to (also when the pane is popped out into a window of its own), or the Quick Terminal (`PaneHost`). A pane reaches no further into either than its host offers.

**Session**:
A persistent pseudo-terminal held by the daemon, so a pane's shell outlives the pane, the window and the app.

**Saved layout**:
The tabs, splits and windows a Mac restores on its next launch: `session.json` for this Mac's targets (`SavedLayout.swift`, `SavedLayoutStore`), and the host layout for a remote workroom's (ADR 0044). Not a session: restoring a layout reattaches its panes' sessions, which the daemon kept alive.
_Avoid_: Session (for the saved layout), session snapshot

**Surface**:
The libghostty view that renders a tab's terminal.

**Reattach**:
Reconnecting a pane to a session that is still running and repainting its screen.

**Run command**:
A command the user sets to run in a workroom, such as `npm start`, started in a tab. It runs where the workroom lives, this Mac or its host, and its tab survives quit like any terminal (ADR 0058). The daemon runs it as a **run session**, under the run supervisor.

**Program status**:
What the program in a session (Claude Code, say) reports about itself over OSC 7501: working, waiting on the user, finished or failed. The daemon keeps it per session and the app shows it as a mark; not progress (OSC 9;4), which only says a command is busy.

**Command result**:
How the last long shell command in a session ended, passed or failed, as the shell reports it. The daemon keeps it beside program status and the app shows it with the same finished and failed marks; not program status, which the program reports about itself.

## Remote hosts

Owns hosts, their drivers, provisioning, the credential relay and port forwarding. A remote workroom is a workroom whose files, shells and daemon live on a host.

**Host**:
The compute that holds a remote workroom: a VM or container a host driver made for it, on a provider or in a container runtime on this Mac, or an SSH host.
_Avoid_: Machine, box, VM, base

**SSH host**:
A Linux server the user already has and reaches with their own ssh, which can hold several remote workrooms, each in its own folder. Workroom never creates or destroys one.
_Avoid_: Generic host, BYO host, server

**Host driver**:
The adapter for one kind of host that reaches it, and creates and destroys it where Workroom makes it: a local container runtime, boxd, exe.dev, Railway or SSH.

**Host options**:
What a boxd, exe.dev or Railway host is created with: its host image and its size, and on Railway its region. Set for all projects, for one project, or for a single create; the most specific choice wins.
_Avoid_: Machine options, create flags

**Host image**:
What a boxd, exe.dev or Railway host is created from: a container image on exe.dev, a snapshot on boxd, Railway's default image or a checkpoint on Railway.
_Avoid_: Machine image, template, base, snapshot (alone)

**Provisioning**:
Readying a host for one remote workroom: the driver creates it (on an SSH host, makes the workroom's folder instead), and the repository is cloned and checked out.

**Provider credentials**:
The GitHub access a remote provider gives its own hosts (boxd's git integration, exe.dev's GitHub integration), which a host on that provider fetches and pushes with. Workroom gives such a host none. Railway gives its hosts none, so Workroom gives a Railway host the user's `gh` token.

**Credential relay**:
How a local container workroom's git asks this Mac's own `gh` for GitHub credentials, over the app's connection.

**Port forward**:
A loopback port on the host of a container workroom, or of a workroom on an SSH host, made reachable on this Mac for as long as the app is attached: the ports its `devcontainer.json` declares, and any the user adds. A Railway host's ports are forwarded the same way, through Railway's relay. boxd and exe.dev publish ports themselves, so their workrooms have none.

## Daemon connection

Owns the daemon's wire protocol, its transport and its hand-off. The Mac's end of the connection is the app; the far end is the daemon.

**Daemon**:
The `workroom` binary run as `workroom serve`, which holds sessions and serves version control, files, exec and port forwarding over one multiplexed stream, on this Mac or a host.
_Avoid_: Agent, Server (an SSH host and a run command's dev server are both called servers), workroomd (its old name)

**Service**:
One capability the daemon serves over its stream, such as terminal sessions, version control or file reads.

**Hand-off**:
Replacing a running daemon's program with a newer binary in place, keeping its process and every session.

**Bin folder**:
The daemon's folder holding one link, `workroom`, to its copy of the binary it runs, re-pointed after every hand-off. It is first on every session's PATH, and its path is `WORKROOM_BIN_DIR` (#695).

**Terminal API**:
The daemon's public, versioned service for reading, typing into, waiting on and watching sessions, used by coding agents and the user's scripts from inside a pane. Its commands are `workroom` subcommands (#360, ADR 0078). It's a public contract that only ever adds fields (ADR 0079).
_Avoid_: Agent API

**Live title**:
The title a session's program last set for its terminal (OSC 0 or 2), which changes as the program runs; not the session's label.

**Label**:
A session's name in the terminal API, and the name of its tab in the app on every Mac: one name, so renaming the tab labels the session and a label set through the API renames the tab (#694, ADR 0079). It is the name the user gave the terminal, or one the app gave a tab it shows ("Run"); a terminal that shows its default name has none. A terminal group's name is no session's label.

**Target**:
How a terminal API command names one session: its id, the end of its id, its label or its live title. A target that names more than one session names none.

**Event**:
Something the terminal API's `workroom events` reports as it happens: a session created, ended or moved to another workroom, a change of its coding agent's program status, a run state, a client attaching or detaching, a send typed into it, naming its sender, or a label it was given. Each is numbered by the daemon's boot and its revision, so a script that reconnects goes on from the last one it saw (ADR 0079).
_Avoid_: Notification (the app's own, shown to the user)

**Client** (of a session):
Something attached to a session, which is shown its output and has a size: a pane of the app, the app's own connection, or a `workroom attach` someone ran. `workroom sessions --clients` lists each with its kind, its machine, when it attached, its size, whether it owns the size and its keepalive (ADR 0079). The terminal API's own commands never attach, so they are no session's clients.

**Send**:
Typing into a session through the terminal API (`workroom send`) without attaching to it: text, as a bracketed paste when its program turned that on, then named keys encoded for its keyboard modes. A send is no client: it takes no size and counts as nobody attached. Its **sender** is the session it came from, which its event names (ADR 0079).
_Avoid_: Inject, attach (a send never attaches)

**Prompt** (through the terminal API):
Giving the coding agent in a session a prompt in one step (`workroom prompt`): its text as a bracketed paste, then Enter, typed as a send is. Only into a **coding-agent session**, one whose foreground program is `claude` or `codex`, or whose program status came from the program in its foreground now; and only while that agent can take one, not working, waiting on the user or without its prompt up (ADR 0079).

**Opening a terminal** (through the terminal API):
`workroom new`: a session made as the caller's pane was, in its workroom, that the Mac showing that pane opens as a tab, or a split beside it; every other Mac lists it with the detached sessions. `workroom close` ends one, and the app closes its tab or split; `workroom run-control` restarts or stops a run session's command (ADR 0079).
_Avoid_: Spawn, create (a workroom is created; a terminal is opened)

**Turn** (of a coding agent):
What one prompt sets a coding agent doing: from the `working` it reports, to the first program status after it that isn't `working` (done, blocked, idle or error). `prompt --wait` and `wait --turn` wait for one to end, never taking the status the last turn left for this one's end (ADR 0079).

**Bootstrap**:
Putting the bundled Linux `workroom`, with Ghostty's terminfo and shell integration, on a host that has none or an older one, and handing a running older daemon off to it. It runs on every connect. A provider or container's supervisor starts the daemon; on an SSH host, the app starts it when nothing is listening.

## Coding agents

Owns the Claude and Codex features: failure diagnosis, investigating a failed command, usage and banners.

**Coding agent**:
Claude or Codex, the AI coding tool a user runs in a terminal and the app reads or calls.
_Avoid_: Agent

**Diagnosis**:
A coding agent's summary of the cause, and a suggested fix command, for a command that just failed.

**Investigate**:
A banner action on a failed command that opens a coding agent in a terminal to look into it.

**Usage**:
A coding agent's quota in each of its windows, such as five hours or a week.

**Workroom skill**:
The skill that teaches Claude Code and Codex the terminal API, the text of `workroom help agents`. Settings ▸ AI Agents installs it in each coding agent's skills folder (`$CLAUDE_CONFIG_DIR` or `~/.claude`, and `~/.agents`), on the Mac and each host, only while turned on; a marker Workroom writes in the folder is what makes it Workroom's to update or remove (#697).
_Avoid_: Agent skill

**Claude account**:
One Claude login whose usage is metered on its own, such as a personal plan and a work organization. cswap numbers each one with a slot.
_Avoid_: cswap account, slot (for the account itself)

**Claude profile**:
The config directory a running Claude Code uses, the default one or one cswap made; it decides which Claude account that Claude bills.
_Avoid_: Config dir, session (the daemon's term)

## App shell

Owns windows, selection, navigation, inspector layout, notifications and theme. It is the composition root that wires the other contexts together.

**Window**:
One app window, with its own selection and layout. Windows share projects.

**Window footer**:
The strip along the bottom of a window about the whole app, such as every coding agent's usage and notifications; not tied to any pane.

**Workroom tab**:
A chip in a window's title bar for one target that has terminals open in that window; choosing it selects that target.
_Avoid_: Tab (alone), chip

**Open view**:
The sidebar's list of the workroom tabs open in this window, in the title bar's order, each unfolding to its tabs. It shows exactly what the title bar and the tab strip show, so a standalone terminal or terminal group is in it only while it has tabs. The sidebar's switcher shows it or the Projects view, one at a time, and each window keeps which (ADR 0083).
_Avoid_: Open section (before ADR 0083), Terminals section (retired)

**Projects view**:
The sidebar's tree of every project, its root and workrooms and their terminals: the other view the sidebar's switcher shows.
_Avoid_: Projects section (before ADR 0083)

**Selection**:
The target a window's sidebar has chosen.

**Navigation history**:
A window's back and forward trail through targets, tabs and what each tab showed.
_Avoid_: History (alone)

**Inspector**:
The right-hand column of Details, Changes, History, Pull Request and Files sections, under a header naming what it is about: the selected workroom or project, or, for a standalone terminal or terminal group, the folder its focused terminal is in and the git repository containing it. That folder is the shell's live one, else where it started, and the inspector follows it as the shell moves; outside a repository the version-control sections say "Not a git repository". Each window's inspector follows only that window's selection, and the Quick Terminal never changes it.

**Notification**:
A badge or desktop banner raised when a program in a terminal asks for attention with an OSC notification sequence. The app keeps one list of them for all windows.
_Avoid_: Alert (for an entry in that list)

**Quick Terminal**:
The built-in terminal group, which can't be deleted, that a global shortcut also slides in from any app as a panel of its own. Its terminals are ordinary ones: they survive a quit and move in and out like any other.

**Shortcut**:
The keys bound to one of Workroom's own actions. The user can record another, reset it to its default, or unset it so the action has no keys and terminals get them back. Standard items macOS supplies (Quit, Hide, Settings…, Copy, Paste) are not shortcuts in this sense.
_Avoid_: Hotkey, keybinding

**Global shortcut**:
A shortcut that works from any app, not only while Workroom is in front. There are two: Show/Hide Workroom and the Quick Terminal's.

**Shortcut conflict**:
Two shortcuts bound to the same keys. Keeping the new one unsets the other.

**Appearance**:
Whether Workroom is light or dark: System (follow macOS), Light or Dark.
_Avoid_: Theme preference, colour scheme, mode (alone)

**Theme**:
A colour scheme for the terminals and the interface, either bundled or one of the user's own. Every theme is either light or dark, judged by its background.
_Avoid_: Colour scheme, palette, variant

**Light theme**:
The theme Workroom uses while its appearance is light. It is chosen apart from the dark theme.

**Dark theme**:
The theme Workroom uses while its appearance is dark. It is chosen apart from the light theme.

**Theme family**:
A bundled preset pairing one light theme with one dark theme, such as Catppuccin (Latte and Mocha). Choosing it sets both, and either can then be changed on its own. The user's own themes never form a family.
_Avoid_: Theme (alone, for a family), pair, theme set
