---
title: Remote workrooms
description: Run workrooms on cloud machines, local containers or an existing SSH host, and keep working in the same app.
nightly: true
---

A remote workroom is a workroom whose files, terminals and coding agents live on a host instead of on your Mac. You still use it from Workroom's window, with the same tabs, splits, inspector and notifications.

boxd, exe.dev and container workrooms each get a fresh host of their own. SSH workrooms use a
Linux server you already have, with a separate folder for each workroom and several workrooms
on one server.

## Choose a host

You choose where a workroom goes when you create it. Click the **+** on a project in the sidebar, or right-click the project and choose **New Workroom**, or press <kbd>⌘N</kbd> and pick a project. Each of these asks where the workroom should go:

| Choice | What you get | Page |
| --- | --- | --- |
| **This Mac** | A normal workroom, a git worktree on your Mac. Not a remote workroom. | [Workrooms](../app/workrooms.md) |
| **Docker** | A container on this Mac, run by Docker Desktop, OrbStack or Colima. | [Containers](containers.md) |
| **Apple Container** | A container on this Mac, run by Apple's `container` tool. | [Containers](containers.md) |
| **boxd** | A machine in the boxd cloud. | [boxd](boxd.md) |
| **exe.dev** | A VM in the exe.dev cloud. | [exe.dev](exe-dev.md) |
| **SSH** | A folder on a Linux server you already reach with ssh. | [SSH hosts](ssh.md) |

In the menu, Docker and Apple Container sit under **Local containers**, and boxd, exe.dev and SSH sit under **Remote**. A choice that cannot be used right now is dimmed, and says why next to its name. For example, a container runtime that is not installed says `not installed`.

## What a project needs

A remote workroom is always a workroom of a project that is on your Mac. You cannot add a project that exists only on a host.

- The project's `origin` must be on github.com. Workroom clones the repository on the host from `origin`, and reads pull request status through your Mac's `gh`.
- The workroom's base branch must be on `origin`. A remote workroom cannot start from a branch that only exists on your Mac, or on a remote other than `origin`. If it cannot, the create stops and tells you to push the branch or change the base branch in **Project Settings**.
- Only pushed work reaches the host. Changes and commits that are only on your Mac do not appear in a remote workroom until you push them.

## What runs where

Workroom starts a small program, `workroomd`, on every host. It keeps your terminal sessions running, and answers the questions the inspector asks about the repository: history, changes and files.

Your terminals are sessions on the host, not processes on your Mac. A dev server or a coding agent keeps running when you quit Workroom, close the window or lose your network. When you come back, your tabs attach to the same sessions. See [Reconnecting](reconnecting.md).

In Nightly, the project's run command runs on the host too, in its own tab. See [Run on a remote workroom](../app/terminals-and-tabs.md#run-on-a-remote-workroom).

What stays on your Mac:

- The app itself, your windows and your settings.
- The `gh` sign-in that Workroom uses for pull requests and CI.
- A container's GitHub access. A Docker or Apple container gets its GitHub credentials from your Mac's `gh`, while you have Workroom open. boxd and exe.dev hosts use GitHub access you set up with the provider, so they keep working with your Mac closed.

An SSH host uses the GitHub credentials you set up on that server. The app's Git commands on every
kind of remote host use that host user's login-shell environment, so they can find tools and
credentials from the user's profile.

The **Details** pane in the inspector shows where a workroom runs: **Running on**, **Machine Name** (the name the host is listed under, in boxd's or exe.dev's dashboard or in `docker ps`) or **Host** (the SSH destination), and **Path on its host**. Open it with <kbd>⌥⌘I</kbd>. See [Details and ports](../app/details-and-ports.md).

## Create one

When you pick a host, the workroom's pane opens at once with a checklist. It shows each step of the create with its time, and a log you can open:

- A container: **Check repository**, **Read devcontainer.json**, **Run initializeCommand**, **Pull image**, **Build image**, **Start container**, **Connect**, **Clone repository**, **Check out branch**, then your `devcontainer.json`'s lifecycle commands after **Copy local files**. See [Docker and Apple containers](containers.md#create-a-container-workroom).
- boxd: **Check repository**, **Check boxd account**, **Create machine**, **Set up machine**, **Connect**, **Clone repository**, **Check out branch**.
- exe.dev: **Check repository**, **Check exe.dev account**, **Create VM**, **Wait for boot**, **Set up machine**, **Connect**, **Clone repository**, **Check out branch**.
- SSH: enter the host and parent folder, check the host and its key, then make the workroom's
  folder, connect, clone the repository and check out the branch. See [SSH hosts](ssh.md).

After these, **Copy local files** runs if your project has a `.worktreeinclude`, and **Run setup script** runs if it has a `scripts/workroom_setup`. If a step fails, the pane tells you why and offers **Try Again** or **Close**. If the failed create could not take its machine down, the pane says the machine is still running and offers **Delete Workroom…** or **Close** instead.

The first time you use boxd or exe.dev, the **Check ... account** step waits for you while a setup sheet walks you through signing up. See [boxd](boxd.md) and [exe.dev](exe-dev.md).

## Setup and teardown scripts

Your project's `scripts/workroom_setup` and `scripts/workroom_teardown` run on the host, inside the clone. They behave as they do on your Mac, apart from these differences:

- `WORKROOM_HOST` tells the script where it runs: `boxd`, `exedev`, `docker`, `apple` or `ssh`. On your Mac it is `local`.
- `WORKROOM_ROOT_PATH` is not set. There is no root project on a host. A script that copies a file from the root has to check first:

  ```sh
  if [ -n "${WORKROOM_ROOT_PATH:-}" ]; then
    cp "$WORKROOM_ROOT_PATH/.env" .env
  fi
  ```

  With `set -u`, an unguarded `$WORKROOM_ROOT_PATH` fails the script, and so the create. To bring gitignored files such as `.env` to the host, list them in `.worktreeinclude` instead.
- The script gets the host user's login environment, never your Mac's. Your Mac's secrets stay on your Mac.
- You approve the script on your Mac before it runs, as for any workroom. See [Prepare a project](../guides/prepare-a-project.md).

See [Environment variables](../reference/environment-variables.md) for the full list.

If the setup script fails, the workroom is kept until you choose. The pane offers **Open Anyway** or **Delete Workroom…**.

## Delete a remote workroom

Deleting a boxd, exe.dev or container workroom destroys its host and everything on it, including
changes and commits that were not pushed. The confirmation says so.

1. Run the project's teardown script on the host, if there is one.
2. Destroy the host.
3. Remove the workroom from Workroom.

If the teardown script fails, can't start, runs out of time, or the host can't be reached, the delete stops and the host stays. Its terminals in Workroom were closed before the script ran. Workroom shows why, with the script's output, and offers **Delete Anyway**, which deletes without the script.

If destroying the host fails part of the way, the workroom stays in the sidebar, so you can delete it again to finish the job.

Deleting an SSH workroom runs its teardown, ends only its sessions, then removes its folder when
the folder's marker matches. The server and its other folders stay. If the host is unreachable or
the marker is missing or different, the delete stops; **Delete Anyway** forgets the workroom and
names the folder left behind. See [Delete an SSH workroom](ssh.md#delete-a-workroom).

Delete a remote workroom in the app. The `workroom delete` command refuses a remote workroom whose
host is still recorded as running. Deleting a project also deletes its remote workrooms,
whichever option you pick, with the same rules for each host kind.

> [!NOTE]
> Workroom does not put a host to sleep. Whether a cloud host sleeps is up to you and the provider.
> A provider host exists until you delete its workroom. An SSH server stays after deletion.

Workroom starts a Docker or Apple container when you open its workroom and it isn't running.

## Release and Nightly

Release and Nightly share one config, so each can open and delete the other's boxd, exe.dev and SSH
workrooms. They share the daemon on an SSH host too; an older build keeps a newer daemon already
running there. A container belongs to the build that made it. If a workroom runs on a container
another build made, deleting it from this build is refused, and the message names that build.
