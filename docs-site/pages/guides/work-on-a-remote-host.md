---
title: Work on a remote host
description: Run a workroom on a cloud machine or in a container, from choosing a host to deleting it when you're done.
nightly: true
---

A remote workroom runs on a host, so a coding agent can keep working with your Mac asleep,
or a heavy build can run without slowing your Mac down. You still work in it from the Workroom window,
as you would a local one. This guide takes you from a project on your Mac to a running remote workroom.

## Choose a host

| If you want                                              | Choose                                   |
| -------------------------------------------------------- | ---------------------------------------- |
| Work that keeps running with your Mac asleep or closed   | [boxd](../remote/boxd.md) or [exe.dev](../remote/exe-dev.md) |
| An isolated Linux environment on this Mac, with no cloud account | [Docker or Apple Container](../remote/containers.md) |
| Folders on a Linux server you already reach with ssh | [SSH](../remote/ssh.md) |

boxd and exe.dev are cloud services that need an account and a paid plan; Workroom walks you through
signing up the first time you use one. A container runs on your Mac. An SSH host is your own server,
which can hold several workrooms. See
[Remote workrooms](../remote/overview.md) for how they differ.

## Get your project ready

A remote workroom clones your project from GitHub, so:

1. Make sure the project's `origin` is on github.com.
2. Push the branch new workrooms start from. Only what is on `origin` reaches the host.
3. If your setup script reads `WORKROOM_ROOT_PATH`, guard it. There is no root checkout on a host:

   ```sh
   if [ -n "${WORKROOM_ROOT_PATH:-}" ]; then
     cp "$WORKROOM_ROOT_PATH/.env" .env
   fi
   ```

4. List gitignored files the workroom needs, such as `.env`, in `.worktreeinclude`. Workroom copies them
   to the host for you. See [Prepare a project](prepare-a-project.md#copy-gitignored-files-into-new-workrooms).

## Create the workroom

1. Click the **+** on the project in the sidebar.
2. Choose the host: Docker or Apple Container under **Local containers**, or boxd, exe.dev or SSH under
   **Remote**.
3. The first time you use boxd or exe.dev, a setup sheet opens. Follow it, then click **Create
   Workroom**. For SSH, enter your host and the parent folder, and trust its host key if asked.
4. Watch the checklist in the workroom's pane. When it finishes, click **Done**.

## Work in it

The terminal is on the host, in the workroom's clone. Start your coding agent, run your tests, and
review, commit and push as you would locally: see [Review and ship](review-and-ship.md).

- Your terminals keep running on the host when you quit Workroom or lose your network, and reattach when
  you come back. See [Reconnecting](../remote/reconnecting.md).
- To open a server running on the host in your browser, see
  [Port forwarding](../remote/port-forwarding.md).
- Press <kbd>⌥⌘I</kbd> to see where the workroom runs.

## Delete it

Push anything you want to keep first. Deleting a boxd, exe.dev or container workroom destroys its
host and everything on it. Deleting an SSH workroom removes only its own folder and ends its
sessions; the server and the other workrooms stay. Hover over the workroom in the sidebar, click
its trash button and confirm. Its teardown script, if
your project has one, runs on the host first. See
[Delete a remote workroom](../remote/overview.md#delete-a-remote-workroom).
