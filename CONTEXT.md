# Workroom

Workroom is a native macOS app for working on several branches of a git project at once. Each branch gets its own workroom, a git worktree with its own terminals, history and diffs. A Go CLI is the engine under the app, and a Rust daemon, workroomd, keeps terminal sessions alive and serves version control and file reads, on this Mac or on a remote host.

## Naming rules

- **Daemon** means workroomd, the Workroom daemon, and nothing else (renamed from "the agent" by #525, ADR 0057). Claude and Codex are **coding agents**; names for them say `CodingAgent` (`CodingAgentRunner`, `TerminalCodingAgentManager`). Bare "agent" names nothing: say daemon or coding agent. The retired Swift `workroom-session` is the **legacy session helper**, never a daemon.
- **Host** is the one word for remote compute. Do not call one a machine, a box, a VM or a base. Provider-facing names (boxd and exe.dev call theirs machines and VMs) and older code keep their words; new names say host.
- **Base** means a base branch only. It no longer names a machine that remote workrooms are derived from.
- Use the terms below in code, issues, tests and docs. A name that is not here either belongs to one of the contexts below or is a gap to add.

## Workroom management

Owns projects, workrooms, setup and teardown, and the labels the sidebar shows. The Go CLI is the engine; the app is a client of its `--json` contract.

**Project**:
A git repository registered with Workroom, identified by its canonical path.

**Workroom**:
A branch of a project, `workroom/<name>`, that Workroom creates for one line of work, with its own terminals. On this Mac it is a linked git worktree; on a host it is its own clone.
_Avoid_: Workspace

**Root**:
A project's own checkout, shown in the sidebar beside its workrooms.

**Target**:
A root or a workroom, as the thing a window selects and opens terminals in.

**Base branch**:
The branch a new workroom starts from, set per project or for all projects.
_Avoid_: Base (alone)

**Setup script**, **Teardown script**:
The project's hooks, `scripts/workroom_setup` and `scripts/workroom_teardown`, run inside a workroom when it is created and before it is deleted, on every kind of workroom: the Go CLI runs them locally, the app runs them on a remote workroom's host through `workroomd run-script`. A failed teardown stops the delete; **Delete Anyway** deletes without it.

**Trusted script**:
A setup or teardown script whose exact contents this Mac has approved, recorded per project. Workroom runs no other script, except a root copy that git ignores, which never arrives by a pull. A changed script needs approving again.
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

**Split**:
A tree that lays several of a target's tabs, or several workrooms in a window, out side by side or stacked.

**Pane**:
The area on screen that shows one tab.

**Pane footer**:
The strip along the bottom of a pane about that pane alone: its tab's live state and the coding agent running in it.
_Avoid_: Status bar, terminal footer

**Session**:
A persistent pseudo-terminal held by workroomd, so a pane's shell outlives the pane, the window and the app.

**Surface**:
The libghostty view that renders a tab's terminal.

**Reattach**:
Reconnecting a pane to a session that is still running and repainting its screen.

**Run command**:
A command the user sets to run in a workroom, such as `npm start`, started in a tab. It runs where the workroom lives, this Mac or its host, and its tab survives quit like any terminal (ADR 0058). The daemon runs it as a **run session**, under the run supervisor.

**Program status**:
What the program in a session (Claude Code, say) reports about itself over OSC 7501: working, waiting on the user, finished or failed. workroomd keeps it per session and the app shows it as a mark; not progress (OSC 9;4), which only says a command is busy.

**Command result**:
How the last long shell command in a session ended, passed or failed, as the shell reports it. workroomd keeps it beside program status and the app shows it with the same finished and failed marks; not program status, which the program reports about itself.

## Remote hosts

Owns hosts, their drivers, provisioning, the credential relay and port forwarding. A remote workroom is a workroom whose files, shells and daemon live on a host.

**Host**:
The compute that holds a remote workroom: a VM or container a host driver made for it, on a provider or in a container runtime on this Mac, or an SSH host.
_Avoid_: Machine, box, VM, base

**SSH host**:
A Linux server the user already has and reaches with their own ssh, which can hold several remote workrooms, each in its own folder. Workroom never creates or destroys one.
_Avoid_: Generic host, BYO host, server

**Host driver**:
The adapter for one kind of host that reaches it, and creates and destroys it where Workroom makes it: a local container runtime, boxd, exe.dev or SSH.

**Provisioning**:
Readying a host for one remote workroom: the driver creates it (on an SSH host, makes the workroom's folder instead), and the repository is cloned and checked out.

**Provider credentials**:
The GitHub access a remote provider gives its own hosts (boxd's git integration, exe.dev's GitHub integration), which a host on that provider fetches and pushes with. Workroom gives such a host none.

**Credential relay**:
How a local container workroom's git asks this Mac's own `gh` for GitHub credentials, over the app's connection.

**Port forward**:
A loopback port on the host of a container workroom, or of a workroom on an SSH host, made reachable on this Mac for as long as the app is attached: the ports its `devcontainer.json` declares, and any the user adds. boxd and exe.dev publish ports themselves, so their workrooms have none.

## Daemon connection

Owns the workroomd wire protocol, its transport and its hand-off. The Mac's end of the connection is the app; the far end is workroomd.

**Daemon**, **workroomd**:
The Rust daemon that holds sessions and serves version control, files, exec and port forwarding over one multiplexed stream, on this Mac or a host.
_Avoid_: Agent

**Service**:
One capability a workroomd serves over its stream, such as terminal sessions, version control or file reads.

**Hand-off**:
Replacing a running workroomd's program with a newer binary in place, keeping its process and every session.

**Bootstrap**:
Putting the bundled Linux workroomd, with Ghostty's terminfo and shell integration, on a host that has none or an older one, and handing a running older daemon off to it. It runs on every connect; the host's supervisor starts the daemon.

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

**Claude account**:
One Claude login whose usage is metered on its own, such as a personal plan and a work organization. cswap numbers each one with a slot.
_Avoid_: cswap account, slot (for the account itself)

**Claude profile**:
The config directory a running Claude Code uses, the default one or one cswap made; it decides which Claude account that Claude bills.
_Avoid_: Config dir, session (workroomd's term)

## App shell

Owns windows, selection, navigation, inspector layout, notifications and theme. It is the composition root that wires the other contexts together.

**Window**:
One app window, with its own selection and layout. Windows share projects.

**Window footer**:
The strip along the bottom of a window about the whole app, such as every coding agent's usage and notifications; not tied to any pane.

**Workroom tab**:
A chip in a window's title bar for one target that has terminals open in that window; choosing it selects that target.
_Avoid_: Tab (alone), chip

**Selection**:
The target a window's sidebar has chosen.

**Navigation history**:
A window's back and forward trail through targets, tabs and what each tab showed.
_Avoid_: History (alone)

**Inspector**:
The right-hand column of Changes, History, Pull Request and Files sections for the selected target.

**Notification**:
A badge or desktop banner raised when a program in a terminal asks for attention with an OSC notification sequence.

**Theme**:
A bundled colour scheme applied to the terminals and the interface.
