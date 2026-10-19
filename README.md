# Workroom

True parallel software development in a native MacOS development environment.

```
It's your IDE (Integrated Development Environment)
     your ADE (Agent Development Environment)
     your TDE (Terminal Development Environment)
     your EDE (Everything Development Environment)
```

## But What is Workroom?

Workroom is a native MacOS IDE with the terminal at its heart. We believe that the terminal is now
the best interface for developers, and that it should be the center of your development environment.
The terminal is where the magic happens - it's where your agents live, your servers and tests run,
and where you review and commit your code.

Workroom also embraces agentic development, where you can have multiple agents working on different
bugs/chores/features at the same time, or even on different projects. Give each agent its own
workroom, with its own terminal and its own context, so you can work on multiple projects and
branches at the same time without losing context. You can even work on multiple projects in a single
split view.

The app is the product. Under it runs the `workroom` Go CLI, the engine the app bundles and drives
for every project and workroom operation. The CLI also works on its own from a shell (see
[The CLI](#the-cli)), but app users never install it.

<p align="center">
  <video src="https://github.com/user-attachments/assets/ee234785-981c-4dc6-a9e4-306d9033ad2f" width="900" controls muted
    alt="The Workroom macOS app: a sidebar tree of several projects and their workrooms with current branches and change badges; two workrooms open side by side, one with a vertically split terminal running a test suite and a dev server, the other showing a syntax-highlighted file diff; and an inspector with Changes, History, Pull Request, and Files sections.">
  </video>
</p>

<p align="center">
  <a href="https://github.com/joelmoss/workroom/releases"><strong>⬇&nbsp;&nbsp;Download for macOS</strong></a>
  &nbsp;·&nbsp;
  <a href="#the-macos-app">The macOS app</a>
  &nbsp;·&nbsp;
  <a href="#the-cli">The CLI</a>
  &nbsp;·&nbsp;
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

---

## Table of Contents

- [Key Features](#key-features)
- [What is a "workroom"?](#what-is-a-workroom)
- [Requirements](#requirements)
- [The macOS app](#the-macos-app)
  - [Install](#install)
  - [What you get](#what-you-get)
- [The CLI](#the-cli)
  - [Installation](#installation)
  - [CLI Usage](#cli-usage)
  - [The `--json` machine contract](#the---json-machine-contract)
- [Setup and teardown scripts](#setup-and-teardown-scripts)
- [Ports in container workrooms](#ports-in-container-workrooms)
- [Configuration & Environment Variables](#configuration--environment-variables)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Key Features

- **Multiple projects** — add/create Git repos.
- **Mutiple Workrooms** — each workroom is an isolated project copy (a Git worktree),
  so several branches/features run side by side without stashing or switching.
- **Git support** — Shows changes, commits, and file diffs (side-by-side or unified) for each workroom.
- **Pull Requests** — create, view, and manage pull requests directly from each workroom.
- **File explorer** — browse and view the workroom's files with automatic language detection, and syntax highlighting.
- **Multiple terminals, multiple tabs** — each workroom keeps its own terminal alive, and you can
  open as many terminals as you like in a draggable tab strip.
- **Split view** — Open and arrange multiple workrooms and tabs horizontally or vertically, in one or many views. Splits even themselves out as you add and remove panes, so a third pane never lands at a quarter width (turn it off in *Settings ▸ Appearance*).
- **Persistent Layout** — Layout and terminal persistence across sessions
- **Move workrooms between windows** — drag a workroom's tab out of the window to give it a window of its own, or onto another Workroom window to join it; its terminals keep running.
- **Live activity & notifications** — tabs and sidebar rows animate while busy; desktop banners fire
  when a backgrounded terminal needs you.
- **Custom Run Command** — set a custom command to run in each workroom (e.g. `npm start` or `rails s`).
- **Setup/teardown hooks** — run a project script automatically on create and delete.
- **Quick Terminal** — a global hotkey (⌘§) to open a quick terminal.
- **Quick Switcher** — quickly switch between workrooms (⌥⇥) and terminals (⌃⇥)
- **Keyboard shortcuts** — at the heart of the app, including a global hotkey to show/hide Workroom from anywhere.
- **Themes** — Dozens of themes, each with light/dark mode, and live re-theming of the entire app, including terminals.

---

## What is a "workroom"?

A **workroom** is an isolated, on-disk copy of your project that shares the same underlying
repository history but has its own working directory and its own branch. It's implemented as a
**Git worktree** (`git worktree add`).

Workrooms live under a central directory (default `~/workrooms`) rather than next to the source repo,
each named after the generated workroom name (e.g. `~/workrooms/swift-meadow`). The branch
created inside the repo is namespaced `workroom/<name>` (e.g. `workroom/swift-meadow`).

This lets you have, say, three feature branches and a hotfix all checked out simultaneously — four
real directories, four terminals — without the constant `git stash` / `git switch` churn.

---

## Requirements

**The macOS app:** nothing to install — the `.dmg` is self-contained (the CLI is bundled inside it).
macOS 15 Sequoia or later on Apple Silicon.

**The standalone CLI:** [Git](https://git-scm.com/) on your `PATH`. That's it.

**Optional:** [`gh`](https://cli.github.com) ≥ 2.57.0, authenticated — the app's Pull Request / CI
inspector shells out to the GitHub CLI.

Building either component from source has its own toolchain requirements — see
[CONTRIBUTING.md](CONTRIBUTING.md#prerequisites).

---

## The macOS app

> The macOS app is under active development and moving quickly.
> [Bug reports and feedback](https://github.com/joelmoss/workroom/issues) are very welcome.

The native app (macOS 15 Sequoia or later, Apple Silicon) is a home for every project you work on
and every workroom inside it. Pick a workroom in the sidebar, get a real terminal already `cd`'d
into it, and run whatever you like — Workroom keeps each one alive and out of the others' way.

### Install

Download the latest `workroom-macos-app_<version>.dmg` from the
[Releases page](https://github.com/joelmoss/workroom/releases) — the newest build is at the top —
open it, and drag **Workroom** into Applications. The app is Developer ID-signed and notarized, so it launches with
no Gatekeeper warning — and it **updates itself** in the background (or on demand via
*Workroom ▸ Check for Updates…*).

That's the whole install. The `workroom` CLI is bundled inside the app and driven for you, so
there's nothing else to download. Want the command in your own shell too? *Workroom ▸ Install
'workroom' Command in PATH…* symlinks it into your `PATH` (prompting for admin once if needed).

Building from source instead? See [Working on the macOS app](CONTRIBUTING.md#working-on-the-macos-app)
and [`macapp/README.md`](macapp/README.md) (`make app-run`).

### What you get

**A sidebar of everything you're working on.** Each project expands into its workrooms as a tree,
and every row shows its current Git branch inline, with a change badge and a warning
when a folder has gone missing. Add a project, expand/collapse it, and pick a target; your layout,
selection, and expansion state are remembered across launches.

**A live terminal in every workroom.** Selecting a workroom gives you an embedded terminal (powered
by [libghostty](https://ghostty.org)) already in the right directory. Each workroom keeps **its own
terminal alive for the session** — switch away to another workroom and your dev server, build, or
REPL keeps running, ready exactly as you left it when you come back. Open as many terminals per
target as you want in a draggable tab strip; tabs label themselves with the running command or
working directory.

**See work happening at a glance.** While a command runs, the tab and its sidebar row animate so
you can tell what's busy without switching to it. When a backgrounded terminal posts a notification,
its tab and project light up, and — if Workroom isn't the frontmost app — you get a desktop banner.
The bell at the right of the app footer opens notifications; click an entry (or the banner) to jump
straight to the terminal that raised it. A program that reports its status, such as Claude Code,
also shows when it is waiting on you (a permission, a question) or has finished its turn, and
alerts you once when it starts waiting or finishes in a terminal you are not looking at (the
toggles are in **Settings ▸ Notifications**). ⇧⌘M goes to the terminal that has waited longest. See [program status](docs/program-status.md).

**Use more than one window.** Drag a workroom's tab, or its title bar, out of the window and it opens in a new window at the drop point. Drop it on another Workroom window to join that window, at the slot under the cursor on its tab bar, or at the end. **Move to New Window** is also in the workroom's right-click menu and sidebar row, and **Move workroom into new window** is in the Window menu. A terminal moves on its own from its tab menu, right-click menu or sidebar row (**Move to New Window**, then **Move Back to Main Window**). A window's only workroom cannot move.

The [persistent app footer](docs/screenshots/window-footer.png) also shows Claude and Codex usage on
the left, once there is a reading, whether or not an agent is running. With
[cswap](https://github.com/realiti4/claude-swap) installed it shows every Claude account it manages;
without it, Claude usage comes from Claude's status line, which you enable once from the footer.
Click the usage bars for details. **Settings ▸ AI Agents ▸ Usage** hides it, and can also show the
usage of the coding agent running in a pane in that pane's footer. The footer stays visible when switching
workrooms or hiding sidebars; undocked terminal windows keep only their pane footer.

**Review your work without leaving the app.** A right-hand inspector reads each workroom's VCS
directly — a **History** log of commits, a **changeset detail** tab (message, authors, changed files,
and per-file diffs in unified or side-by-side), and a live **Changes** view of the working copy.
A **Pull Request** panel lets you create and track PRs, and a **file explorer** browses the tree
with language detection and syntax highlighting. It's read structurally from Git (libgit2) — not
scraped from CLI output. A **Details** pane shows where the selected workroom runs and, for a
container workroom, its forwarded ports (see [Ports in container
workrooms](#ports-in-container-workrooms)).

**Create and delete without touching the command line.** Hit the **+** on a project to spin up a
new workroom. Its pane opens at once with a checklist of the create's steps, each with its time
and its log a click away, so you watch the fetch, the worktree and your `scripts/workroom_setup`
in real time; the terminal opens when you click **Done**, or by itself a few seconds after setup
finishes if you turn on **Close automatically when done**.
Deleting is a hover-to-trash with a confirmation; teardown runs in the background and the row clears
immediately. If the teardown script fails, the workroom comes back with the script's output and a
**Delete Anyway** button that deletes it without the script. (See [Setup and teardown
scripts](#setup-and-teardown-scripts).)

**Jump in with the keyboard.** `⌘1`–`⌘9` focus terminals left-to-right, `⌘T` opens a new one, and
`⌘W` closes the active one (with an optional confirm). `⌘N` creates a workroom and `⌘O` opens an
existing one; hold `⌥` on either (`⌥⌘N` / `⌥⌘O`) to land it beside the current workroom as a split
instead of replacing it. A global `⌘§` hotkey shows or hides Workroom from anywhere.

**Stay in your editor.** `⌘`-click a file path in any terminal to open it in your editor — VS Code,
Zed, or Xcode — at the right working directory. The detail toolbar also has *Open in…*, *Reveal in
Finder*, and *Copy Path* for the selected workroom.

**Make it yours.** System / Light / Dark theming (terminals re-theme live), copy-on-select,
confirm-before-quit and confirm-before-close toggles, and an editor preference all live in
Settings (`⌘,`), also available from the gear at the bottom of the right sidebar.

---

## The CLI

The `workroom` CLI is the engine the macOS app is built on — bundled inside the app and driven for
you, so **app users never install it**. It's also a fully standalone addon for people who prefer the
terminal, and the only option on Linux/Windows. **Skip this whole section if you use the app.**

### Installation

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

**Windows (PowerShell):**

```powershell
iwr https://raw.githubusercontent.com/joelmoss/workroom/master/install.ps1 -useb | iex
```

**Install a specific version:**

```bash
VERSION=v1.2.0 curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

**Install from a release channel:**

```bash
WORKROOM_CHANNEL=pre     curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
WORKROOM_CHANNEL=nightly curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

`WORKROOM_CHANNEL=pre` installs the latest prerelease as `workroom` and remembers the channel, so a
later `workroom update` stays on it. `WORKROOM_CHANNEL=nightly` installs a **separate
`workroom-nightly`** binary (tip of `main`) that coexists with `workroom` and self-updates within
nightly. `VERSION` takes precedence when set. Same variable works for the Windows PowerShell
installer.

**Override install location (macOS / Linux):**

By default, the binary is installed to `~/.local/bin`. Set `WORKROOM_INSTALL_PATH` to change this:

```bash
WORKROOM_INSTALL_PATH=/usr/local/bin curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

The install script auto-detects your OS (`darwin`/`linux`) and architecture (`amd64`/`arm64`),
fetches the matching release archive, unpacks the binary, and (if your install dir isn't on `PATH`)
prints the `export PATH=…` line to add to your shell profile.

#### Alternative methods

**Via Go:**

```bash
go install github.com/joelmoss/workroom@latest
```

**Build from source:**

```bash
git clone https://github.com/joelmoss/workroom.git
cd workroom
make cli-build      # produces ./workroom with the version injected via ldflags
```

### CLI Usage

#### Create a workroom

```bash
workroom create
```

A random friendly name (e.g. `swift-meadow`) is auto-generated from a 120-adjective × 210-noun word
list. If the generated name collides, it retries up to 5 times, then falls back to appending a random
2-digit suffix (e.g. `swift-meadow-42`).

Workroom creates a Git worktree for the workroom, on a new branch from `origin`'s default branch.
Workroom fetches `origin` first. If the fetch fails, Workroom uses the last fetched copy and prints a
warning. The macOS app shows the warning as a notification on the new workroom. A repository without
`origin` branches from the current `HEAD`. A repository with no commits gets an empty branch.

Alias: `workroom c`. Flags: `--project <dir>` (operate on a directory other than the cwd),
`--no-editor` (suppress the post-create "open in `$EDITOR`?" prompt).

A setup script runs only once this Mac has approved it; a new or changed one is shown first and you
are asked (see [Approving scripts](#approving-scripts)).

#### Choose the branch new workrooms start from

```bash
workroom base set develop
workroom base set upstream/main --global
workroom base clear
```

`workroom base set <branch>` makes the project's new workrooms start from that branch. Workroom
fetches the remote and uses the remote's copy of the branch. If the remote does not have it,
Workroom uses the local branch and warns that it may be out of date. If neither exists, the create
fails with `BaseBranchNotFound`.

A plain name such as `develop` is a branch on `origin`. To use another remote, write
`<remote>/<branch>`. For example, if you work from a fork, `upstream/main` starts new workrooms from
the real project's `main` instead of your fork's. Workroom reads the part before the first `/` as a
remote only if the repository has a remote of that name, so `release/1.0` stays a branch on
`origin`.

`--global` sets the default for every project that names no base branch. A project's own setting
wins. If the default does not exist in a project, for example `upstream/main` in a project without
an `upstream` remote, that project's workrooms start from `origin`'s default branch with a warning.
If Workroom cannot fetch to check, the create fails instead. `workroom base set` registers the
project if it is not registered yet. Run it from the project's root checkout: inside a workroom it
fails with `InWorkroom`. `workroom base clear` removes the setting; both commands take `--project <dir>` or
`--global`. In the macOS app, set the default in Settings and a project's own branch in Project
Settings, both under New Workrooms. Remote workrooms use the same setting, but they have only
`origin` and no local branch to fall back to, so the branch must be on `origin`.

#### List workrooms

```bash
workroom list
```

Lists all workrooms for the current project. When run from outside a known project, lists all
workrooms grouped by parent project. When run from inside a workroom, shows the parent project path.
Rows flag warnings such as a missing directory or a missing VCS workspace.

Aliases: `workroom ls`, `workroom l`

#### Delete a workroom

```bash
workroom delete my-feature
```

Removes the workspace/worktree and cleans up the directory. You'll be prompted for confirmation
before deletion.

When run without a name, an interactive multi-select menu is shown, allowing you to pick one or more
workrooms to delete:

```bash
workroom delete
```

To skip the confirmation prompt (useful for scripting), pass `--confirm` with the workroom name:

```bash
workroom delete my-feature --confirm my-feature
```

> **Note on Git:** deleting a workroom removes the worktree and its directory but **does not** delete
> the underlying `workroom/<name>` branch. Workroom prints the `git branch -D` command to run if you
> want it gone.

Alias: `workroom d`

#### Update the CLI

```bash
workroom update                # download & install the latest build on your channel
workroom update --check        # only report whether an update is available (never writes config)
workroom update --channel pre  # switch to the pre channel and install its latest build
```

**Release channels.** The main `workroom` binary tracks one of two channels, and `--channel`
remembers your choice for future `workroom update` runs:

- `stable` (default) — GA releases only.
- `pre` — betas / release candidates, **plus** stable (whichever is newer).

Switching to a lower channel installs that channel's current build even if it's a version
*downgrade* (you're told so). Downloads are verified against the release `checksums.txt` before the
binary is replaced.

**Nightly is a separate install, not a channel switch.** Nightly builds (from the tip of `main`)
ship as a distinct **`workroom-nightly`** binary that runs alongside `workroom`, so you never risk
your working install. Get it via the installer's `WORKROOM_CHANNEL=nightly` (below); it self-updates
within nightly on its own. `workroom update --channel nightly` is rejected with a pointer to that.

(Dev builds can't self-update — install from a release first. A `workroom` bundled inside the macOS
app is managed by the app; run *Check for Updates…* there instead of `workroom update`.)

#### Print the version

```bash
workroom version
```

#### Global Options

- `-v`, `--verbose` — Print detailed, step-by-step output.
- `-p`, `--pretend` — Run through the command without making changes (dry run).
- `--json` — Emit a single machine-readable JSON object on stdout (see
  [the `--json` contract](#the---json-machine-contract)). Used by the macOS app.
- `--confirm NAME` — (delete only) Skip confirmation when `NAME` matches the workroom being deleted.
- `--skip-teardown` — (delete only) Delete without running the teardown script, after it failed.

### The `--json` machine contract

Every `--json` invocation prints **exactly one JSON object on stdout** (the result envelope) and
exits with a [stable code](#exit-codes). Progress (setup/teardown logs) streams as
**NDJSON on stderr**, so stdout stays a single object.

**Success envelope:**

```json
{ "ok": true, "schema_version": 1, "cli_version": "v2.0.0",
  "command": "create", "name": "swift-meadow", "path": "/Users/you/workrooms/swift-meadow",
  "vcs": "git", "project": "/Users/you/dev/myapp" }
```

**Error envelope** (machine code + human message):

```json
{ "ok": false, "schema_version": 1, "cli_version": "v2.0.0",
  "command": "create", "error": { "kind": "WorkspaceExists", "message": "git worktree already exists: …" } }
```

**Streaming log event (stderr, one per line):**

```json
{ "type": "log", "phase": "setup", "step": "script", "text": "npm install…" }
```

`create --json` also emits an early `{"type":"created", …}` event on stderr the moment the workroom
exists (before setup runs), so a GUI can mount it and dock the streaming setup log immediately.

`create --json` reports its steps as `step` events, in order: `fetch` (fetch the base branch),
`worktree` (`git worktree add`) and `script` (the setup script). `state` is `running`, `done`,
`warning`, `skipped` or `failed`; `detail` carries the warning text, the reason a step was skipped,
or the failure message, and is left out when there is none:

```json
{ "type": "step", "id": "fetch", "state": "warning", "detail": "Could not fetch origin. …" }
```

Each `log` event carries the `step` that last started (left out before any step has).
The `fetch` and `worktree` logs hold each `$ git …` command line and its output.

**Commands available in `--json` mode:** `create`, `list` (with `--warnings none|fast|full`),
`delete` (requires `--confirm <name>`), `version`, plus two hidden, app-only commands — `add-project`
(register an empty project) and `delete-project` (drop a project; `--with-workrooms` cascades the
teardown). The schema is versioned (`schema_version: 1`); breaking changes bump it.

`base set` and `base clear` also run in `--json` mode. They print `{"project": …, "base_branch": …}`,
or `{"global": true, "base_branch": …}` with `--global`.

If the new workroom starts from out-of-date refs or from a fallback base, the `create` result has a
`warning` string. The early `created` event always has a `warning` field, and an empty
one means no warning. `list` adds `base_branch` at the top level for the global default. It also adds it to
each project that sets its own. Without a setting, the field is absent.

In `list`, a workroom (or project) on another host carries a `host` object, absent for a local
one. A remote workroom never gets the local `DirectoryMissing` / `VCSWorkroomMissing` warnings; one
whose host its provider destroyed gets `HostDestroyed` instead.

#### Error codes

`internal/errs` maps each sentinel error to a stable `kind` string used in the JSON contract:

| `kind` | Meaning |
| --- | --- |
| `InWorkroom` | Command run from inside an existing workroom |
| `UnsupportedVCS` | No Git repo detected |
| `InvalidName` | Workroom name failed validation |
| `DirExists` / `WorkspaceExists` | Target dir / VCS workspace already exists |
| `WorkspaceNotFound` | Workroom to delete doesn't exist |
| `ConfirmationMismatch` | `--confirm` value didn't match |
| `Cancelled` | User aborted / no-op |
| `SetupScriptFailed` / `TeardownScriptFailed` | Hook returned non-zero |
| `ConfigReadFailed` / `ConfigWriteFailed` | Config I/O / parse error |
| `VCSCommandFailed` | Underlying `git` command failed |
| `RemoteProjectUnsupported` | `add-project` was given a remote path (`host:path`, `ssh://…`) |
| `RemoteWorkroomUnsupported` | `delete` / `delete-project` on a remote workroom (not yet supported) |
| `BaseBranchNotFound` | A base branch exists neither on its remote nor locally, or the fetch that checks the remote failed |
| `ScriptNotTrusted` | A setup or teardown script this Mac has not [approved](#approving-scripts); the envelope's `script` carries its `name`, `origin`, `sha256` and `text` |
| `InternalError` | Anything else |

#### Exit codes

Non-interactive callers can branch on the process exit code:

| Code | Class |
| --- | --- |
| `0` | Success |
| `2` | Usage / validation (e.g. confirmation mismatch) |
| `3` | Domain precondition / not-found (unsupported VCS, exists, invalid name, in-workroom) |
| `4` | Cancelled / no-op |
| `5` | Setup / teardown script failed |
| `6` | Config read / write / parse error |
| `1` | Internal error |

---

## Setup and teardown scripts

Both the macOS app **and** the CLI automatically run user-defined scripts during create and delete
operations — the app drives the same engine, so the same hooks work no matter how you use Workroom.
They run on every kind of workroom: on this Mac, and on a remote workroom's host (boxd, exe.dev, a
Docker or Apple container), where they behave the same way except where a section below says
otherwise.

### Approving scripts

A setup or teardown script is code from the repository, so Workroom runs one only after this Mac has
approved its **exact contents**. The first create or delete that would run an unapproved script, or
one that changed since you approved it (by a `git pull`, say), stops before it does anything and
shows you the script:

- In a terminal, `workroom create` and `workroom delete` print the script and ask. Yes records the
  approval and carries on; no cancels with nothing made or removed (exit code 4).
- In the macOS app, the creation pane's "Run setup script" row waits with the script shown and
  **Approve** / **Cancel**; Approve records it and creates again. A delete's sheet offers **Approve
  and Run**, **Delete Anyway** and **Cancel**. A remote create checks before any machine is made.
- Without a terminal, and with `--json`, the command refuses with `ScriptNotTrusted` (exit code 3).

For a create, the setup script judged is the one the new workroom will hold: the base commit's
`scripts/workroom_setup`, after the fetch, else the root's copy. For a delete, it is the teardown
script that would run: the workroom's copy, else the root's. The file is hashed again just before it
runs, so bytes that change in between are refused too.

A root copy that **git ignores** needs no approval: it can't arrive by a pull. An untracked file git
doesn't ignore still needs one.

Approve ahead of time, or check, from the project's root (or with `--project DIR`):

```bash
workroom trust          # show each script a create or delete would run next, and approve it
workroom trust status   # exit 0 when every script is approved or ignored, 1 when one is not,
                        # 2 when it can't tell (the base branch can't be resolved)
workroom untrust        # forget this project's approvals
```

In a terminal, `trust` shows each script and asks. Without one (in a script, or with `--json`) it
approves every script it finds without showing it, so read them first. `trust` and `trust status`
fetch and resolve the base branch as a create does, so they judge the
setup script the next create would run. Approvals are kept per project, as a SHA-256 for each script,
in this Mac's config (`trusted_scripts`); they never leave it. Removing a project from Workroom
forgets them.

### Gitignored files (`.worktreeinclude`)

A fresh workroom is a clean checkout, so gitignored files your project needs (`.env`,
`config/master.key`, local certificates) are missing. List them in a `.worktreeinclude` file at your
project's root, in `.gitignore` syntax, and Workroom copies them from the root into every new
workroom, on this Mac or on a remote host, before the setup script runs:

```gitignore
.env
.env.local
config/master.key
certs/
```

- Only files that match a pattern **and** are gitignored in the root are copied. A tracked file, or
  an untracked file git doesn't ignore, never is.
- Patterns mean what git means by them: `**/`, directories and anchoring work as in a `.gitignore`,
  and so does git's re-include rule. `!x` can't bring back a file under a directory a pattern already
  included: `secrets/` followed by `!secrets/skip.json` still copies `skip.json` (use `secrets/**`
  to exclude it).
- Only the root's `.worktreeinclude` counts, whatever branch the workroom starts from.
- Each file keeps its mode. A file the workroom already has is left alone. Symlinks are never
  copied: the "Copy local files" step names each one it skipped, so link a symlinked `.env` yourself.
- Nothing is copied when the file is missing. When a file can't be copied, the create still finishes:
  its "Copy local files" step ends as a warning naming the file.

The same file name and format work with Orca, Claude Code and the Codex app, so you can commit it
once for every tool your team uses.

### Setup script

Place an executable script at `scripts/workroom_setup` in your project (remember `chmod +x`). Workroom
runs the new workroom's own copy of the script. If the workroom has no copy, for example because the
script is gitignored, Workroom runs the copy in the root project. A new workroom can start from a
newer commit than your root checkout, so the script that runs can be newer than the one you see. It
runs **inside the new workroom** right after creation, and after its [gitignored
files](#gitignored-files-worktreeinclude) are copied in: a good place to install dependencies. (In
the macOS app, its output streams into the new workroom's creation checklist, under "Run setup
script", as it runs.)

On a remote workroom the script runs **on its host**, inside the clone: the clone's own copy, or, when
the clone has none, the root's copy, copied to the host with its mode. Its output streams into the
same "Run setup script" row.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Install dependencies for this isolated copy.
npm install

# Give the workroom its own database, named after it, so it can't clobber others.
createdb "myapp_${WORKROOM_NAME}"
```

> A setup failure is **not** transactional: the workroom directory and config entry already exist
> by the time setup runs. The CLI reports the failure (exit code 5); the macOS app surfaces the
> error and offers **Open Anyway** or **Delete**. A remote workroom's machine is kept, and keeps
> running, until you choose. A script that can't start (no `chmod +x`) fails the same way.

### Teardown script

Place an executable script at `scripts/workroom_teardown` in your project (`chmod +x`). Workroom
looks for it as it looks for the setup script: the workroom's own copy first, then the root project's.
It runs **inside the workroom** just before it's deleted — undo anything setup created that lives outside
the workroom (the directory itself is removed for you):

```bash
#!/usr/bin/env bash
set -euo pipefail

# Drop the per-workroom database that setup created.
dropdb "myapp_${WORKROOM_NAME}" 2>/dev/null || true
```

On a remote workroom the teardown runs on its host before the machine is destroyed, in every kind of
delete, including removing its project from Workroom only (which destroys remote machines too). A
machine a create or an earlier delete left half-made is destroyed without it.

If the teardown fails, can't start, runs out of time, isn't [approved](#approving-scripts) on this
Mac, or the remote host can't be reached, the delete **stops** and nothing is removed, so you can fix the script and delete again. The macOS app shows why,
with the script's output, and offers **Delete Anyway**, which deletes without the script; the CLI's
equivalent is `workroom delete <name> --skip-teardown`. On a project delete the button is **Delete
Without Teardowns**: it skips every remaining workroom's teardown, not only the one that failed.

### Environment variables

The same environment variables are available to **both** the setup and teardown scripts. The script
runs with its **working directory set to the workroom directory**.

Scripts also inherit **your login shell's environment**, so the tools and settings you've configured
in your dotfiles are available — `psql` from Postgres.app, version-manager shims, `$PNPM_HOME`, and
anything else you export. Run from the terminal, the CLI simply passes its own environment through.
The macOS app has to work harder: a Finder-launched app starts with a minimal `PATH`, so the app
reads `/etc/paths` and `/etc/paths.d` (the same files `path_helper` reads) and additionally runs one
`$SHELL -lic` to pick up what only an interactive login shell knows. That runs fresh each time a
workroom is created or deleted, so a tool you installed a minute ago is already visible.

Two things worth knowing:

- **Your environment includes your secrets.** A setup script is code from the repository, and it
  runs with everything your shell exports. That is why Workroom shows you each script and runs it
  only once you [approve](#approving-scripts) it: read it before you do, above all in a repository
  you haven't read.
- **`WORKROOM_SHELL_PROBE=1`** is set while the app is reading your environment. Guard slow or
  interactive blocks in your `.zshrc` with it if shell startup is expensive:
  ```bash
  [ -n "$WORKROOM_SHELL_PROBE" ] || eval "$(something-slow init)"
  ```

If the probe fails — a `.zshrc` that ends in `exec tmux`, a prompt waiting on input, `fish` or
`nushell` as your `$SHELL` — the app falls back to the `/etc/paths.d` layer, which still resolves
everything the system knows about. You lose the dotfile extras, not the basics.

| Variable | Meaning |
| --- | --- |
| `WORKROOM_NAME` | The name of the workroom being created or deleted. |
| `WORKROOM_PATH` | Absolute path to the workroom directory (also the script's working directory). |
| `WORKROOM_ROOT_PATH` | Absolute path to the root project the workroom belongs to. Since scripts run inside the workroom, this lets you reference files back in the original project. |
| `WORKROOM_PARENT_DIR` | _Deprecated_ alias for `WORKROOM_ROOT_PATH`, still set for existing scripts. Prefer `WORKROOM_ROOT_PATH`. |
| `WORKROOM_HOST` | Where the script runs: `local`, or a remote workroom's host kind, `boxd`, `exedev`, `docker` or `apple`. |

On a remote workroom's host:

- `WORKROOM_ROOT_PATH` and `WORKROOM_PARENT_DIR` are **not set**: there is no root project on the
  host. Bring what a script copies from the root with [`.worktreeinclude`](#gitignored-files-worktreeinclude)
  instead, and guard what still needs the root:
  ```bash
  if [ -n "${WORKROOM_ROOT_PATH:-}" ]; then
    cp "$WORKROOM_ROOT_PATH/.env" .env
  fi
  ```
  With `set -u`, an unguarded `$WORKROOM_ROOT_PATH` fails the script, and so the create.
- The environment is the **host user's** login shell's, read the same way (with
  `WORKROOM_SHELL_PROBE=1` while it is read), never your Mac's: your Mac's secrets stay on your Mac.
- A Docker or Apple container's git asks your Mac for GitHub credentials while the script runs, as
  its terminals do; boxd and exe.dev hosts use their own GitHub access.

This repo ships its own `scripts/workroom_setup` as a working example: it guards against the root
and workroom paths resolving to the same inode (which would clobber source) and copies
`.claude/settings.local.json` into the new workroom.

---

## Ports in container workrooms

A dev server running in a Docker or Apple container workroom listens inside the container, where
your Mac's browser can't reach it. Workroom forwards its ports to `127.0.0.1` on your Mac, and the
**Ports** list in the inspector's **Details** pane (`⌥⌘I`) shows each one.

Declare the ports in the repository's dev container file, `.devcontainer/devcontainer.json` (or
`.devcontainer.json`), the same file VS Code, Codespaces and DevPod read:

```jsonc
{
  "forwardPorts": [5173, 3000],
  "portsAttributes": {
    "5173": { "label": "Web" },
    "3000": { "label": "API", "requireLocalPort": true }
  }
}
```

- The ports are forwarded when you open the workroom, once per launch, from the workroom's own
  copy of the file. A port you stop forwarding stays stopped until the app relaunches. At most
  32 ports are forwarded from one file; the Ports list says when the file declares more.
- A forward that keeps its number holds that port on your Mac until you stop forwarding it or
  quit Workroom, even after you switch to another workroom. A server you start on your Mac later
  on the same port (the project's own dev server, Postgres) then can't take it, or is shadowed by
  the forward. Stop the forward in the Ports list first.
- Each port keeps its number on your Mac when that number is free, so 5173 is
  `http://localhost:5173`. When something on your Mac already uses it, the port gets a free number
  instead, and the Ports list shows which. With `"requireLocalPort": true` the port isn't forwarded
  at all then, and the list says why.
- Only these fields are read: numbers in `forwardPorts`, and `label` and `requireLocalPort` for a
  single port in `portsAttributes`. A `"host:port"` entry, port ranges and patterns, `appPort`, and
  the container definition itself (`image`, `build`, `features`) are ignored: a container workroom
  runs Workroom's own image.
- To forward a port the file doesn't list, type it into the Ports list and press **+**.
- Workrooms on boxd and exe.dev have no Ports list: publish a machine's port with
  `boxd machine proxy add` (public on the internet) or `ssh exe.dev share port` (private to you by
  default). A workroom on your Mac needs none.

---

## Configuration & Environment Variables

Workroom has no required environment for normal use. The relevant variables:

| Variable | Used by | Purpose |
| --- | --- | --- |
| `WORKROOM_INSTALL_PATH` | `install.sh` | Override the CLI install directory (default `~/.local/bin`). |
| `VERSION` | `install.sh` / `install.ps1` | Install a specific CLI version instead of the latest. |
| `EDITOR` | `workroom create` | If set (and not `--no-editor`/`--json`), Workroom offers to open the new workroom in it. |
| `WORKROOM_NAME`, `WORKROOM_PATH`, `WORKROOM_ROOT_PATH`, `WORKROOM_HOST` | setup/teardown scripts | See [Environment variables](#environment-variables). Set by Workroom, not by you. |

**Config file:** `~/.config/workroom/config.json`. Two keys are for you to
set. `workrooms_dir` is where workrooms are created (default `~/workrooms`, a leading `~` works).
`base_branch` is the default start branch for new workrooms, set with `workroom base set --global`.
Workroom manages everything else.

---

## Troubleshooting

**"no supported VCS detected in this directory"** — `workroom create`/`delete` must be run from the
root of a Git repo (a directory containing `.git`). Use `--project <dir>` to point at
one explicitly.

**"looks like you are already in a workroom"** — you're inside a workroom directory (it has a
`.Workroom` marker). Run the command from your main project root, not from within a workroom.

**Created the workroom but setup failed** — creation isn't transactional, so the workroom exists. Fix
your `scripts/workroom_setup`, then `workroom delete <name>` and recreate (the CLI exits with code 5
on setup failure; the app offers to delete the half-created workroom).

**"script is not trusted on this Mac"** — the setup or teardown script is new, or changed since you
approved it. Read it, then approve it: answer yes when `workroom create` or `delete` asks in a
terminal, or run `workroom trust` in the project (see [Approving scripts](#approving-scripts)). A
`--json` or scripted call can't ask, so it exits with code 3. `workroom trust status` exits 2 when
the base branch can't be resolved; fix the base branch first.

**`workroom update` says it can't update** — you're on a `dev` build (built without version ldflags).
Install from a release, via `make cli-install` with a tag, or `go install …@latest`.

**Deleted a workroom but the Git branch is still there** — that's intentional. Workroom never deletes
the `workroom/<name>` branch; remove it with `git branch -D workroom/<name>` if you want.

**`list` shows "directory not found" / "workspace not found"** — the workroom's directory or its VCS
workspace was removed out from under Workroom. Run `workroom delete <name>` to reconcile the config.

**macOS's built-in bash: no command-finished features** — if your login shell is `/bin/bash`
(Apple's bash 3.2), terminals get no shell integration, so the inline agent, the tab title reset
when a command ends, and working-directory tracking don't work there. Apple's bash ignores the
startup hook the integration uses. Homebrew bash (4.4 or newer) gets all of them:

```bash
brew install bash
echo "$(brew --prefix)/bin/bash" | sudo tee -a /etc/shells
chsh -s "$(brew --prefix)/bin/bash"
```

Then log out and back in, so apps you open from the Dock see the new shell, and open a new terminal
in Workroom. `echo $BASH_VERSION` should print 5.x.

**App's PR/CI inspector is empty** — it shells out to the GitHub CLI. You need `gh` ≥ 2.57.0 on
`PATH`, authenticated (`gh auth status --active`).

**Config seems out of sync between the CLI and the app** — both read/write
`~/.config/workroom/config.json` under a best-effort advisory lock. If a process crashed mid-write
you may have a stale `config.json.lock`; it self-heals after ~10s, or delete it manually.

---

## Contributing

Issues and PRs are welcome at <https://github.com/joelmoss/workroom>. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the architecture, the local dev setup, the test and lint
gates, and the release process.

---

## License

[MIT](MIT-LICENSE)
