---
title: Docker and Apple containers
description: Run a workroom in a Docker or Apple container on your Mac, with its ports forwarded to localhost.
nightly: true
---

A container workroom runs in a container on your Mac instead of in a git worktree. Its terminals, files and coding agents live inside the container, so what you install or run there stays out of your Mac. For what remote workrooms are, see [Remote workrooms](overview.md).

A container is a remote workroom in every way that matters: it has a fresh host of its own, a fresh clone of your repository, and the same panes and inspector. Unlike boxd and exe.dev, the host is on your Mac and no account is needed.

## Requirements

For either runtime:

- Your project's `origin` must be on github.com, and its base branch must be on `origin`. See [Remote workrooms](overview.md#what-a-project-needs).
- The GitHub CLI, `gh`, must be signed in on your Mac. Run `gh auth login` if it is not. A container gets its GitHub access from your Mac's `gh`, so the choice says `run gh auth login` while you are signed out.

For **Docker**:

- Docker Desktop, OrbStack or Colima, with the `docker` command installed. Workroom looks for it at `/usr/local/bin/docker`, `/opt/homebrew/bin/docker`, and inside `Docker.app`.
- Docker must be running. If it is not, the create stops with `Docker didn't answer`. Start it, then try again.

For **Apple Container**:

- An Apple silicon Mac running macOS 26 or later.
- Apple's `container` tool, from [github.com/apple/container](https://github.com/apple/container), at `/usr/local/bin/container` or `/opt/homebrew/bin/container`.
- Its system service running. If it is not, the create stops and tells you to run `container system start`.

A runtime that does not meet these is dimmed in the New Workroom menu, with the reason beside its name: `not installed`, `run gh auth login`, `needs Apple silicon` or `needs macOS 26`.

## Create a container workroom

1. Click the **+** on a project, or right-click the project and choose **New Workroom**.
2. Under **Local containers**, choose **Docker** or **Apple Container**.
3. Watch the checklist in the pane: **Check repository**, **Pull host image**, **Start container**, **Connect**, **Clone repository**, **Check out branch**. When it finishes, click **Done**.

The first create downloads Workroom's host image, and the **Pull host image** row shows how far the download has got. Later creates reuse it, and that row says `Image already downloaded`. If the download fails, the message says whether the registry refused it or your network failed.

The container runs Workroom's own image. A `devcontainer.json` in your repository does not change it: `image`, `build`, `features` and the rest of the container definition are ignored. Only its ports are read. See [Port forwarding](port-forwarding.md).

Apple's runtime gives each container a VM of its own, and its default is too small for a compiler or an agent. So Workroom gives each Apple container half of your Mac's cores and a quarter of its memory, between 2 GB and 8 GB. Docker's containers share Docker's own VM.

## Working in a container

- The workroom's folder is a fresh clone inside the container. Only pushed work reaches it. Changes that are only on your Mac do not appear until you push them.
- Git inside the container asks your Mac's `gh` for GitHub credentials, while Workroom is open. Anything running in the container can ask, so it has the same GitHub access that `gh` has on your Mac.
- A server you run in the container listens inside it, where your browser cannot reach it. Workroom forwards ports to `localhost` for you. See [Port forwarding](port-forwarding.md).
- Your setup and teardown scripts run in the container, with `WORKROOM_HOST` set to `docker` or `apple`. See [Remote workrooms](overview.md#setup-and-teardown-scripts).

## When your Mac sleeps

A container stops when your Mac sleeps or restarts, unlike a cloud host. Workroom starts it again when you open its workroom. With Apple's runtime, every container is stopped after a restart, so each one starts when you open its workroom.

Terminals in a container workroom reattach after the container comes back. See [Reconnecting](reconnecting.md).

## Delete the workroom

Deleting the workroom destroys its container and everything in it, including changes and commits that were not pushed. See [Delete a remote workroom](overview.md#delete-a-remote-workroom).

A container belongs to the build of Workroom that made it. Release and Nightly cannot delete each other's containers.
