---
title: SSH hosts
description: Create workrooms in separate folders on a Linux server you already reach with ssh.
nightly: true
---

An SSH host is a Linux server you already have. Workroom puts each workroom in its own folder on
that server, and several workrooms can share it. Your terminals, files, Run command and repository
panels work there as they do on other [remote workrooms](overview.md).

## Before you start

- The server must run Linux on x86_64 or aarch64, with `git` and `setsid` installed.
- You must be able to sign in with your own `ssh`, without a password or passphrase prompt. Add
  your key to ssh-agent or the Keychain if it needs a passphrase.
- Bash and fish login shells are supported.
- Your project's `origin` must be on github.com, and its base branch must be on `origin`.
- Set up GitHub access on the server itself. Workroom uses that access for cloning, fetching and
  pushing; your Mac's `gh` sign-in stays on your Mac.

Workroom uses your `/usr/bin/ssh`, with your `~/.ssh/config`, keys, agent and Keychain. Put a port,
jump host or other connection settings in your ssh config, then enter that host's alias in Workroom.

Startup and service checks reuse a private Workroom SSH connection to reduce new connections on
servers that rate-limit SSH. Terminal panes open their own connections, so the server's SSH
connection-rate limit can still apply when opening many panes at once.

## Create a workroom

1. Click the **+** on a project, or right-click it and choose **New Workroom**.
2. Under **Remote**, choose **SSH**.
3. Enter the host as you would after `ssh`: an alias such as `myserver`, or a destination such as
   `joel@example.com`. Hosts you used before are offered again.
4. Choose a parent folder inside your home on the server. It defaults to the folder last used on
   that host, or `~/workrooms` the first time. `~` means your home on the server.
5. Continue the create and watch the checklist in its pane.

The workroom goes in `<parent folder>/<workroom name>`. An existing folder with that name stops
the create and is kept. Workroom names are unique within a project, so another project's workroom
can already have that name on the same host.

Workroom checks the host before reserving the workroom or making its folder. If the host is new
to your ssh `known_hosts`, a prompt shows its key's fingerprint. Check the fingerprint, then click
**Trust** to save that key. A changed key fails the connection; Workroom never replaces it
automatically. If the unknown key belongs to a jump host, connect with `ssh` in Terminal once to
check and trust that host first.

Trust needs a persistent known-hosts file. If your SSH config sets `UserKnownHostsFile` to
`/dev/null` or another non-file target, change it to a regular file before trusting the host.

Two destinations count as different hosts when they are typed differently, even if both reach the
same server. Reuse the same destination to keep the workrooms grouped under one host record.

## GitHub access and your environment

The clone keeps your project's GitHub URL scheme. An SSH origin needs a GitHub SSH key on the
server. For an HTTPS origin, run `gh auth login` and `gh auth setup-git` there, or configure your
own Git credential helper there.

The app's Git commands use the server user's login-shell environment, as do setup and teardown
scripts. Tools and credentials you export in that shell are available on the host. Setup and
teardown scripts receive `WORKROOM_HOST=ssh`, with no `WORKROOM_ROOT_PATH` because the root project
stays on your Mac. See [Environment variables](../reference/environment-variables.md).

## Terminals and ports

Your programs keep running on the server when you quit Workroom or disconnect. After a server
restart, Workroom starts its daemon when it next connects, and your old tabs show their last
screens. Close an ended tab to start a new terminal. See [Reconnecting](reconnecting.md).

Use the **Ports** list in **Details** (<kbd>⌥⌘I</kbd>) to reach a server listening on the host's
loopback interface from your Mac. Each workroom has its own list, populated from its own
`devcontainer.json` plus ports you add. Two workrooms forwarding the same server port get separate
ports on your Mac. See [Port forwarding](port-forwarding.md).

## Delete a workroom

Push anything you want to keep first. Deleting runs the teardown script, ends that workroom's
sessions and removes its folder, including unpushed changes and commits. The server, the parent
folder and the other workrooms stay.

Workroom checks the folder against the marker it wrote when it created the workroom. A missing
or different marker stops the delete and keeps the folder. If the server can't be reached, the
delete also stops. **Delete Anyway** removes the entry from Workroom and tells you which folder
was left on which host. A folder already removed on the server counts as deleted.

If the host refuses to create or remove the folder, Workroom shows the host's error. For example,
files created by a container running as root can cause a permission error. Fix their ownership or
permissions on the server, then retry. Workroom does not use `sudo` to remove them.

Workroom leaves its daemon and installed files on the server, even after the last workroom goes.
The daemon runs until the server restarts or you end it. Workroom installs no system service and
uses no `sudo`. Its files live under `~/.local/state/workroom`; Release and Nightly share them,
while a Dev build uses its own state folder.

If the server ends the daemon whenever an ssh login closes, Workroom reports that rather than
changing the server. Ask its administrator about the server's login-session policy.
