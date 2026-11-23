# Signing off a Nightly

Part of the [release process](releasing.md). CI and `make app-test-remote` prove the code; this
checklist proves the build you ship: the signed **Workroom Nightly** app, updated the way users get
it, on your Mac, on a remote host and in a container. Run it in Workroom Nightly before you call a
Nightly good, and before you tag a release from the commit it was built from.

Each step says what to do, then what a pass looks like. Anything else is a fail: note the step and
what you saw. Use a throwaway project with a GitHub `origin` for the steps that create or delete
workrooms, never one you work in. The UI paths match the [user docs](../../docs-site/pages/index.md);
when the app and the docs disagree, the app's labels win, and the docs get a fix.

## 1. The Mac

### Update

1. Before updating, open two terminals in a workroom. Run `top` in one and `sleep 600` in the
   other, start the project's run command (see [step 3](#3-the-run-tab)), and note
   `pgrep -x top` from a third.
2. Choose **Workroom Nightly ▸ Check for Updates…** (also **Settings ▸ About ▸ Check for
   Updates…**). Install the update it offers.

**Pass:** the update installs and the app relaunches by itself. **Settings ▸ About** shows the new
version, `<base>-nightly.<count>`, matching the `nightly` release's title on GitHub. Before you
confirm the install, the note "Safe to update: your terminals and run commands keep running"
scrolls past next to the title bar's **Update** button. After the relaunch, `top` is still
updating with the same pid (`pgrep -x top`), `sleep 600` is still running
(<kbd>Ctrl</kbd>-<kbd>C</kbd> brings its prompt back), and the run tab is still going. The
scrollback above each is intact.

A Nightly that says it is already up to date hasn't tested the update: the `nightly` release keeps
only the latest build, so run this step again when the next Nightly is out.

### Quit and reopen

1. With `top` running in a terminal, note `pgrep -x top`, then quit with <kbd>⌘Q</kbd>. If it asks
   about dev servers, choose **Keep Running and Quit**.
2. Open Workroom Nightly again.

**Pass:** every tab comes back where it was, and `top` is still updating in its pane with the same
pid, not restarted. The run tab is still running.
**Settings ▸ General ▸ When quitting with dev servers running** decides the run tab: with **Stop**
its tab is closed and doesn't come back.

### The `workroom` in a pane

In any terminal of a workroom:

```sh
which workroom
echo "$WORKROOM_BIN_DIR"
workroom sessions
```

**Pass:** `which workroom` prints `$WORKROOM_BIN_DIR/workroom`, the folder beside the daemon's
socket (`$WORKROOM_DAEMON.bin/…`), not `/usr/local/bin/workroom` or a copy you installed.
`workroom sessions` lists this workroom's terminals by their tab names, the run tab marked as one,
and a coding agent's last status where one runs. A `DaemonTooOld` error or "command not found" is a
fail.

## 2. A remote workroom

A remote workroom is one Workroom made on a host, whose terminals the host's Workroom daemon runs.
Typing `ssh myserver` in a Mac pane is not one: that pane is still a Mac terminal, and tests none
of this.

1. Click the **+** on the throwaway project in the sidebar (or right-click it and choose **New
   Workroom**). Under **Remote**, choose **SSH**. SSH has no page in **Settings ▸ Remote Hosts**,
   which lists boxd, exe.dev and Railway: the host is entered here.
2. Enter a Linux server you reach with your own `ssh` and no password prompt, as you would after
   `ssh` (an alias from `~/.ssh/config` works). Keep the parent folder, `~/workrooms` by default.
   If the host's key is new, check the fingerprint and click **Trust**.
3. Watch the checklist in the workroom's pane until it finishes.

**Pass:** the checklist checks the host, makes the folder, connects, clones and checks out, each
step ticked, and the pane becomes a terminal on the host. **Details** (<kbd>⌥⌘I</kbd>) shows
**Running on** SSH, **Host** your destination, and **Path on its host** the workroom's folder in
the parent folder.

To tell it is a remote workroom's terminal, run in it:

```sh
ps -o pid,ppid,args -p $$ -p $PPID
uname -a
which workroom
workroom sessions
```

**Pass:** the `$PPID` row is Workroom's daemon on the host, a `…/workroomd serve --socket …`
process (the folder beside its socket), not `sshd`; an `sshd` there means you are in a plain `ssh`
session. `uname -a` names the Linux server. `which workroom` prints
`$WORKROOM_BIN_DIR/workroom` on the host, and `workroom sessions` lists the host's terminals, not
your Mac's.

Then:

1. Run `top` in the pane, quit Workroom Nightly with <kbd>⌘Q</kbd> and open it again.
   **Pass:** the pane reattaches with `top` still running on the host.
2. Run the project's run command on it ([step 3](#3-the-run-tab)), set to `sleep 600`. **Pass:**
   it runs on the host: `pgrep -af 'sleep 600'` in another pane of the workroom finds it, and the
   run tab's **Restart** and **Stop** work as on your Mac.
3. Delete the workroom: right-click it in the sidebar, choose **Delete Workroom…** and confirm.
   **Pass:** the folder is gone from the server (`ls ~/workrooms` there), and the server and its
   other folders stay.

## 3. The run tab

A project's **run command** is the one command Workroom starts for it, such as `npm run dev`, in a
**Run** tab of its own: **Settings ▸ Projects**, the project, **Run command**. A project with none
can't run (<kbd>⌘R</kbd> opens Settings on it); for this check set it to `top`, which keeps
redrawing, or `sleep 600`, which keeps running quietly.

1. In a workroom, press <kbd>⌘R</kbd> (**Room ▸ Run**).
2. Press <kbd>⌥⌘R</kbd> (**Room ▸ Restart**), then <kbd>⇧⌘R</kbd> (**Room ▸ Stop**).

**Pass:** a tab named **Run** opens with the command running, and the title bar shows **Restart**
and **Stop** while it runs; the workroom's sidebar row shows its run control. Restart ends it and
starts it again in the same tab. Stop shows **Stopping…** in the tab's footer, then the command
ends within about six seconds, the title bar shows **Run** again, the tab keeps its output, and the
sidebar control goes. Do it on your Mac, the remote workroom and the container workroom.

## 4. A container workroom

Needs Docker running (Docker Desktop, OrbStack or Colima), or Apple's `container`
(`container system start`) for **Apple Container**. Check both when you can.

1. Click the **+** on the throwaway project. Under **Local containers**, choose **Docker** (then
   again with **Apple Container**).
2. Watch the checklist; click **Done** when it finishes.

**Pass:** the checklist ticks **Check repository**, **Read devcontainer.json**, **Pull image**,
**Start container**, **Connect**, **Clone repository** and **Check out branch** (a step the project
doesn't need is skipped), and the pane becomes a terminal in the container. In it,
`ps -o pid,ppid,args -p $$ -p $PPID` shows Workroom's daemon as the shell's parent and `uname -a`
names Linux. **Details** shows **Running on** Docker (or Apple Container) and the **Machine Name**
`docker ps` lists. The run tab works there as in [step 3](#3-the-run-tab), and quitting and
reopening reattaches its terminals. Deleting the workroom removes the container: it is gone from
`docker ps -a` (or `container list --all`).

## 5. The terminal API

Run these from one terminal of a workroom, about the others. Name the tabs you aim at (right-click
a tab ▸ **Rename…**) so a command can find them by name. See
[Drive terminals from agents and scripts](../../docs-site/pages/guides/drive-terminals-from-agents-and-scripts.md).

### `prompt`, with real coding agents

Open two tabs named `claude` and `codex`, and start the real `claude` and `codex` in them. From a
third tab, run (the script from PR #751, which checked these against fakes only):

```sh
workroom sessions --json
workroom prompt claude 'Reply with one word' --wait --timeout 2m
workroom prompt claude 'Summarise @README.md in one line' --wait --timeout 5m
workroom prompt claude 'x'                             # while it works → exit 3 AgentBusy
workroom prompt codex 'Reply with one word' --wait     # before its first turn → NotAnAgent
workroom prompt codex 'Reply with one word'
workroom prompt codex 'Summarise @README.md in one line' --wait --timeout 5m
```

Run the fourth command while Claude is still working on the third (start the third without
`--wait`, or from another tab).

**Pass:** `sessions --json` lists both tabs with their `label`s, and `coding_agent` for Claude.
Each prompt appears in the agent's input box as a paste and is submitted: the agent answers it,
once. Each `--wait` returns when the turn ends, printing `status: done`, and within its timeout.
`@README.md` stays a file reference: Claude reads the file, and Codex's file popup doesn't swallow
the Enter. `prompt claude 'x'` while Claude works exits 3 with `AgentBusy` and types nothing.
`prompt codex … --wait` before Codex's first turn exits 3 with `NotAnAgent`. A prompt typed but not
submitted, or submitted twice, is a fail.

### The typing marker

Open a fourth tab, a plain shell, named `shell`. From the third tab, type into it:

```sh
workroom send shell 'echo typed' --enter
```

**Pass:** the `shell` tab runs `echo typed`, and while it is typed a marker at the top of that pane
names who is typing: a terminal symbol and **Terminal · tab 3**, the tab it came from (**tab 3 in
<workroom>** from another workroom). Typed by an agent instead (ask Claude to run that command),
it shows the agent's logo and **Claude · tab 1**. Run from Terminal.app, outside Workroom, it reads
**Outside Workroom**. It fades about 3 seconds after the last keystroke, and
hovering over it names who typed.

### `new`, labels, `run-control` and `close`

```sh
workroom new --title probe
workroom api call session.label '{"target": "probe", "label": "renamed"}'
workroom sessions
workroom api call session.label '{"target": "renamed", "label": null}'
workroom new --split right --title runner --run 'sleep 600'
workroom run-control runner restart
workroom wait runner --run running --timeout 1m
workroom run-control runner stop
workroom close runner
workroom close <the id the first new printed>
workroom close "$WORKROOM_PANE"
```

**Pass:** the first `new` prints an id, and a tab named **probe** opens beside yours. The label
renames that tab **renamed** at once, and `workroom sessions` lists it so; clearing it shows the
tab's default name again. The second `new` opens a split to the right named **runner**, running
`sleep 600` as a run tab. `run-control runner restart` restarts it, and the `wait` returns once it
is running again. `stop` stops it, as the tab's **Stop** does. Each `close` closes its tab or
split. The last, on your own pane, is refused with `RefusedSelf` and closes nothing.

Do the `new` and `close` checks, and `prompt` where the host has an agent, in the remote
workroom's panes too: there `workroom` is the host's, and acts on the host's terminals.

## 6. The Workroom skill

1. Open **Settings ▸ AI Agents** and turn on **Install the Workroom skill for Claude Code and
   Codex** (under **Workroom skill**). Look at the section in light and in dark (<kbd>⇧⌘L</kbd>,
   **View ▸ Light Mode** or **Dark Mode**).
2. In a terminal: `ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/workroom" ~/.agents/skills/workroom`.
3. Turn the setting off and run the same `ls`.

**Pass:** the section reads clearly in both appearances, and no line under the setting says a skill
was left alone or failed. With it on, both folders hold the skill's `SKILL.md`: the Claude one in
`$CLAUDE_CONFIG_DIR/skills/workroom` when your login shell sets `CLAUDE_CONFIG_DIR`, else
`~/.claude/skills/workroom`. Turned off, both folders are gone (a `~/.agents` Workroom made for it
goes too when it is empty). With the remote workroom from [step 2](#2-a-remote-workroom) open, the
host gets the skill in the same folders of its user's home after Workroom next connects, and loses
it the same way.

## 7. What a coding agent leaves to you

Since #793 and #798, `trust`, `delete` and `delete-project` refuse under a coding agent, and so
does a `create` that would run a setup script you haven't approved. In a workroom of the throwaway
project, start Claude Code and ask it to run each of these with its shell tool and report the exit
code and output (`<name>` is a workroom of the project, `<path>` the project's folder):

```sh
workroom trust
workroom delete <name> --confirm <name>
workroom delete-project <path> --confirm <path>
workroom delete <name> --pretend
workroom delete-project <path> --pretend
workroom create            # with a setup script you haven't approved, or have changed since
workroom create --skip-setup
```

**Pass:** the first three exit 3 with `NeedsTheUser`, saying to ask you to do it in the app or your
own terminal, and change nothing: `workroom trust status` (which runs under the agent) is as
before, and the workroom and the project are still in the sidebar. Both `--pretend` runs work,
printing what they would remove, and remove nothing. The plain `create` exits 3 with
`NeedsTheUser` and makes no workroom; `create --skip-setup` makes one without running the script.
Delete that workroom in the app afterwards. In your own terminal, outside any agent,
`workroom trust` asks you as it always has.
