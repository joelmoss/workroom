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

<p align="center">
  <video src="https://github.com/user-attachments/assets/ee234785-981c-4dc6-a9e4-306d9033ad2f" width="900" controls muted
    alt="The Workroom macOS app: a sidebar tree of several projects and their workrooms with current branches and change badges; two workrooms open side by side, one with a vertically split terminal running a test suite and a dev server, the other showing a syntax-highlighted file diff; and an inspector with Changes, Pull Request, and Notifications panels.">
  </video>
</p>

<p align="center">
  <a href="https://github.com/joelmoss/workroom/releases"><strong>⬇&nbsp;&nbsp;Download for macOS (beta)</strong></a>
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
- [Configuration & Environment Variables](#configuration--environment-variables)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Key Features

- **Multiple projects** — add/create Git or JJ repos.
- **Mutiple Workrooms** — each workroom is an isolated project copy (Git worktree or JJ workspace),
  so several branches/features run side by side without stashing or switching.
- **Git/Jujutsu Support** — Shows changes, commits, and file diffs (side-by-side or unified) for each workroom.
- **Pull Requests** — create, view, and manage pull requests directly from each workroom.
- **File explorer** — browse and view the workroom's files with automatic language detection, and syntax highlighting.
- **Multiple terminals, multiple tabs** — each workroom keeps its own terminal alive, and you can
  open as many terminals as you like in a draggable tab strip.
- **Split view** — Open and arrange multiple workrooms and tabs horizontally or vertically, in one or many views.
- **Persistent Layout** — Layout and terminal persistence across sessions
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
repository history but has its own working directory and its own branch/bookmark. It's implemented as:

- a **Git worktree** (`git worktree add`) when the project is a Git repo, or
- a **Jujutsu workspace** (`jj workspace add`) when the project is a JJ repo.

Workrooms live under a central directory (default `~/workrooms`) rather than next to the source repo,
each named after the generated workroom name (e.g. `~/workrooms/swift-meadow`). The branch/bookmark
created inside the VCS is namespaced `workroom/<name>` (e.g. `workroom/swift-meadow`).

This lets you have, say, three feature branches and a hotfix all checked out simultaneously — four
real directories, four terminals — without the constant `git stash` / `git switch` churn.

---

## Requirements

**The macOS app:** nothing to install — the `.dmg` is self-contained (the CLI is bundled inside it).
macOS 15 Sequoia or later on Apple Silicon.

**The standalone CLI:** [Git](https://git-scm.com/) or [JJ (Jujutsu)](https://martinvonz.github.io/jj/)
on your `PATH`. That's it.

**Optional:** [`gh`](https://cli.github.com) ≥ 2.57.0, authenticated — the app's Pull Request / CI
inspector shells out to the GitHub CLI.

Building either component from source has its own toolchain requirements — see
[CONTRIBUTING.md](CONTRIBUTING.md#prerequisites).

---

## The macOS app

> **🚧 Beta.** The macOS app is young and under active development — expect rough edges, and some
> flows still want polish. [Bug reports and feedback](https://github.com/joelmoss/workroom/issues)
> are very welcome.

The native app (macOS 15 Sequoia or later, Apple Silicon) is a home for every project you work on
and every workroom inside it. Pick a workroom in the sidebar, get a real terminal already `cd`'d
into it, and run whatever you like — Workroom keeps each one alive and out of the others' way.

### Install

Download the latest `workroom-macos-app_<version>.dmg` from the
[Releases page](https://github.com/joelmoss/workroom/releases) — the newest build is at the top
(the app currently ships as a `v2.0.0-beta` prerelease) — open it, and drag
**Workroom** into Applications. The app is Developer ID-signed and notarized, so it launches with
no Gatekeeper warning — and it **updates itself** in the background (or on demand via
*Workroom ▸ Check for Updates…*).

That's the whole install. The `workroom` CLI is bundled inside the app and driven for you, so
there's nothing else to download. Want the command in your own shell too? *Workroom ▸ Install
'workroom' Command in PATH…* symlinks it into your `PATH` (prompting for admin once if needed).

Building from source instead? See [Working on the macOS app](CONTRIBUTING.md#working-on-the-macos-app)
and [`macapp/README.md`](macapp/README.md) (`make app-run`).

### What you get

**A sidebar of everything you're working on.** Each project expands into its workrooms as a tree,
and every row shows its current Git branch or JJ bookmark inline, with a change badge and a warning
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
A notifications inspector keeps the history; click any entry (or the banner) to jump straight to the
terminal that raised it.

**Review your work without leaving the app.** A right-hand inspector reads each workroom's VCS
directly — a **History** log of commits, a **changeset detail** tab (message, authors, changed files,
and per-file diffs in unified or side-by-side), and a live **Changes** view of the working copy.
A **Pull Request** panel lets you create and track PRs, and a **file explorer** browses the tree
with language detection and syntax highlighting. It's read structurally from Git (libgit2) and JJ
(jj-lib) — not scraped from CLI output.

**Create and delete without touching the command line.** Hit the **+** on a project to spin up a
new workroom. Your `scripts/workroom_setup` runs behind a live progress overlay so you watch
dependencies install and config copy in real time, and the terminal opens only once setup is done.
Deleting is a hover-to-trash with a confirmation; teardown runs in the background and the row clears
immediately. (See [Setup and teardown scripts](#setup-and-teardown-scripts).)

**Jump in with the keyboard.** `⌘1`–`⌘9` focus terminals left-to-right, `⌘T` opens a new one, `⌘W`
closes the active one (with an optional confirm), and `⌘O` adds a project. A global `⌘§` hotkey
shows or hides Workroom from anywhere.

**Stay in your editor.** `⌘`-click a file path in any terminal to open it in your editor — VS Code,
Zed, or Xcode — at the right working directory. The detail toolbar also has *Open in…*, *Reveal in
Finder*, and *Copy Path* for the selected workroom.

**Make it yours.** System / Light / Dark theming (terminals re-theme live), copy-on-select,
confirm-before-quit and confirm-before-close toggles, and an editor preference all live in
Preferences (`⌘,`).

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
list. Workroom automatically detects whether you're using JJ or Git and uses the appropriate
mechanism (JJ workspace or Git worktree). If the generated name collides, it retries up to 5 times,
then falls back to appending a random 2-digit suffix (e.g. `swift-meadow-42`).

Alias: `workroom c`. Flags: `--project <dir>` (operate on a directory other than the cwd),
`--no-editor` (suppress the post-create "open in `$EDITOR`?" prompt).

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

### The `--json` machine contract

Every `--json` invocation prints **exactly one JSON object on stdout** (the result envelope) and
exits with a [stable code](#exit-codes). Progress (setup/teardown logs) streams as
**NDJSON on stderr**, so stdout stays a single object.

**Success envelope:**

```json
{ "ok": true, "schema_version": 1, "cli_version": "v2.0.0-beta.1",
  "command": "create", "name": "swift-meadow", "path": "/Users/you/workrooms/swift-meadow",
  "vcs": "git", "project": "/Users/you/dev/myapp" }
```

**Error envelope** (machine code + human message):

```json
{ "ok": false, "schema_version": 1, "cli_version": "v2.0.0-beta.1",
  "command": "create", "error": { "kind": "WorkspaceExists", "message": "Git worktree already exists: …" } }
```

**Streaming log event (stderr, one per line):**

```json
{ "type": "log", "phase": "setup", "text": "npm install…" }
```

`create --json` also emits an early `{"type":"created", …}` event on stderr the moment the workroom
exists (before setup runs), so a GUI can mount it and dock the streaming setup log immediately.

**Commands available in `--json` mode:** `create`, `list` (with `--warnings none|fast|full`),
`delete` (requires `--confirm <name>`), `version`, plus two hidden, app-only commands — `add-project`
(register an empty project) and `delete-project` (drop a project; `--with-workrooms` cascades the
teardown). The schema is versioned (`schema_version: 1`); breaking changes bump it.

#### Error codes

`internal/errs` maps each sentinel error to a stable `kind` string used in the JSON contract:

| `kind` | Meaning |
| --- | --- |
| `InWorkroom` | Command run from inside an existing workroom |
| `UnsupportedVCS` | No Git or JJ repo detected |
| `InvalidName` | Workroom name failed validation |
| `DirExists` / `WorkspaceExists` | Target dir / VCS workspace already exists |
| `WorkspaceNotFound` | Workroom to delete doesn't exist |
| `ConfirmationMismatch` | `--confirm` value didn't match |
| `Cancelled` | User aborted / no-op |
| `SetupScriptFailed` / `TeardownScriptFailed` | Hook returned non-zero |
| `ConfigReadFailed` / `ConfigWriteFailed` | Config I/O / parse error |
| `VCSCommandFailed` | Underlying `git`/`jj` command failed |
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

### Setup script

Place an executable script at `scripts/workroom_setup` in your project (remember `chmod +x`). It
runs **inside the new workroom** right after creation — a good place to install dependencies and
pull in gitignored local config that the worktree/workspace doesn't carry over. (In the macOS app,
its output streams into the setup overlay as it runs.)

```bash
#!/usr/bin/env bash
set -euo pipefail

# A fresh workroom is a clean checkout, so copy gitignored local config (e.g. .env)
# from the root project this workroom belongs to.
cp "$WORKROOM_ROOT_PATH/.env" .env 2>/dev/null || true

# Install dependencies for this isolated copy.
npm install

# Give the workroom its own database, named after it, so it can't clobber others.
createdb "myapp_${WORKROOM_NAME}"
```

> A setup failure is **not** transactional: the workroom directory and config entry already exist
> by the time setup runs. The CLI reports the failure (exit code 5); the macOS app surfaces the
> error and offers to delete the half-created workroom.

### Teardown script

Place an executable script at `scripts/workroom_teardown` in your project (`chmod +x`). It runs
**inside the workroom** just before it's deleted — undo anything setup created that lives outside
the workroom (the directory itself is removed for you):

```bash
#!/usr/bin/env bash
set -euo pipefail

# Drop the per-workroom database that setup created.
dropdb "myapp_${WORKROOM_NAME}" 2>/dev/null || true
```

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
  runs with everything your shell exports. That's the same trust you extend by running the script
  at all, but it's worth being deliberate about for repositories you haven't read.
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

This repo ships its own `scripts/workroom_setup` as a working example: it guards against the root
and workroom paths resolving to the same inode (which would clobber source) and copies
`.claude/settings.local.json` into the new workroom.

---

## Configuration & Environment Variables

Workroom has no required environment for normal use. The relevant variables:

| Variable | Used by | Purpose |
| --- | --- | --- |
| `WORKROOM_INSTALL_PATH` | `install.sh` | Override the CLI install directory (default `~/.local/bin`). |
| `VERSION` | `install.sh` / `install.ps1` | Install a specific CLI version instead of the latest. |
| `EDITOR` | `workroom create` | If set (and not `--no-editor`/`--json`), Workroom offers to open the new workroom in it. |
| `WORKROOM_NAME`, `WORKROOM_PATH`, `WORKROOM_ROOT_PATH` | setup/teardown scripts | See [Environment variables](#environment-variables). Set by Workroom, not by you. |

**Config file:** `~/.config/workroom/config.json`. The only user-editable key is
`workrooms_dir` (where workrooms are created; default `~/workrooms`, supports a leading `~`). Everything
else is managed by Workroom.

---

## Troubleshooting

**"no supported VCS detected in this directory"** — `workroom create`/`delete` must be run from the
root of a Git or JJ repo (a directory containing `.git` or `.jj`). Use `--project <dir>` to point at
one explicitly.

**"looks like you are already in a workroom"** — you're inside a workroom directory (it has a
`.Workroom` marker). Run the command from your main project root, not from within a workroom.

**Created the workroom but setup failed** — creation isn't transactional, so the workroom exists. Fix
your `scripts/workroom_setup`, then `workroom delete <name>` and recreate (the CLI exits with code 5
on setup failure; the app offers to delete the half-created workroom).

**`workroom update` says it can't update** — you're on a `dev` build (built without version ldflags).
Install from a release, via `make cli-install` with a tag, or `go install …@latest`.

**Deleted a workroom but the Git branch is still there** — that's intentional. Workroom never deletes
the `workroom/<name>` branch/bookmark; remove it with `git branch -D workroom/<name>` if you want.

**`list` shows "directory not found" / "workspace not found"** — the workroom's directory or its VCS
workspace was removed out from under Workroom. Run `workroom delete <name>` to reconcile the config.

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
