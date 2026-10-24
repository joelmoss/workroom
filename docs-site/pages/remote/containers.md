---
title: Docker and Apple containers
description: Run a workroom in a Docker or Apple container on your Mac, made from your repository's devcontainer.json, with its ports forwarded to localhost.
nightly: true
---

A container workroom runs in a container on your Mac instead of in a git worktree. Its terminals, files and coding agents live inside the container, so what you install or run there stays out of your Mac. For what remote workrooms are, see [Remote workrooms](overview.md).

A container is a remote workroom in every way that matters: it has a fresh host of its own, a fresh clone of your repository, and the same panes and inspector. Unlike boxd and exe.dev, the host is on your Mac and no account is needed.

> [!IMPORTANT]
> Container workrooms made by an earlier Nightly, before containers were made from `devcontainer.json`, can't be opened by this one. Their status, Changes panel and terminals say the workroom was set up by an older Workroom Nightly. Delete each one and create it again. Deleting it destroys the container, with any work in it you haven't pushed.

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
3. Watch the checklist in the pane. When it finishes, click **Done**.

The checklist runs **Check repository**, **Read devcontainer.json**, **Run initializeCommand**, **Pull image**, **Build image**, **Start container**, **Connect**, **Clone repository**, **Check out branch**, **Copy local files**, then each lifecycle command your `devcontainer.json` has, and **Run setup script**. A step your project doesn't need is skipped.

The first create from an image downloads it, and the **Pull image** row shows how far the download has got. Later creates reuse it, and that row says `Image already downloaded`. If the download fails, the message says whether the registry refused it or your network failed.

Apple's runtime gives each container a VM of its own, and its default is too small for a compiler or an agent. So Workroom gives each Apple container half of your Mac's cores and a quarter of its memory, between 2 GB and 8 GB. Docker's containers share Docker's own VM.

## Your dev container

Workroom makes the container from your repository's dev container file, `.devcontainer/devcontainer.json` or `.devcontainer.json`, the same file VS Code, Codespaces and DevPod read. It reads the file from the commit the new workroom starts from, on `origin`, so a change you haven't pushed to a file already there isn't used. When that commit has no dev container file, the one in your project's folder is used, with the Dockerfile and build context beside it, so you can try a new one before you push it. Comments and trailing commas are allowed.

Workroom uses these keys:

- **`image`**, or **`build`** with its `dockerfile`, `context`, `args` and `target`.
- **`features`**, fetched from their registry and installed in the order the spec gives them.
- **`containerEnv`**, **`remoteEnv`**, **`remoteUser`** and **`containerUser`**.
- **`mounts`** and **`capAdd`**, and on Docker **`runArgs`**, **`privileged`** and **`securityOpt`**.
- **`workspaceFolder`**: where the workroom's clone goes, `/workspaces/<repository>` if you don't set it.
- **`forwardPorts`** and **`portsAttributes`**. See [Port forwarding](port-forwarding.md).
- The lifecycle commands, below.

A key Workroom can't honour doesn't stop the create: the **Read devcontainer.json** row warns, naming each one and why. That covers `workspaceMount` (each workroom clones into `workspaceFolder` instead), `appPort`, `hostRequirements`, `postAttachCommand`, `runArgs` and the other Docker settings on Apple's runtime, and any key Workroom doesn't know. A file that describes Docker Compose services can't be used: the create stops and offers **Continue With Default Image**.

A Dockerfile on its own, with no `devcontainer.json` naming it, is ignored, as the spec has it.

### Approve it first

Your `devcontainer.json` decides what the container mounts from your Mac and what runs there, so Workroom uses it only after you have approved its exact contents on this Mac, as it does for [setup scripts](../guides/prepare-a-project.md#approve-your-scripts). The first create that would use a new file, or one that changed since you approved it, stops and shows it to you, with **Approve**, **Continue With Default Image…** and **Cancel Creation**. Continuing creates the workroom on the default image and approves nothing, so the next create asks again.

An approval covers the file's own contents only. The Dockerfile it builds, and the features it installs, aren't covered.

### Lifecycle commands

They run as the container's user:

- **`initializeCommand`** runs on your Mac, in your project, before the image is built.
- After the clone and **Copy local files**: **`onCreateCommand`**, **`updateContentCommand`**, **`postCreateCommand`** and **`postStartCommand`**, in that order, each as a row of its own.
- **Run setup script** comes last, so `scripts/workroom_setup` sees the container as VS Code would leave it, with anything `postStartCommand` started already running.
- **`postStartCommand`** runs again each time the container starts, on the first connect after it. A terminal you open meanwhile says it is waiting for it, and attaches once it is done. Updating Workroom doesn't start the container again, so it doesn't rerun.

`remoteEnv` reaches every lifecycle command, the setup script and your terminals.

### Without a devcontainer.json

A repository with no dev container file gets Workroom's default image, the devcontainers project's Ubuntu base, run as its `vscode` user, who has passwordless `sudo`. Nothing is added to it.

To use another image instead, set **Default image** under **Container Workrooms** in **Settings ▸ General**. It applies to containers made after you change it. The image needs `git` and a shell. If it lacks either, the create fails and names the missing one.

### When the file changes

A change to `devcontainer.json`, or to the Dockerfile it builds, applies to workrooms you create after it. The **Details** pane shows what a container was made from under **Made From**, and a note when the repository's file has changed since, or has been added or removed. To pick up the change, create a new workroom.

## Working in a container

- The workroom's folder is a fresh clone inside the container. Only pushed work reaches it. Changes that are only on your Mac do not appear until you push them.
- Git inside the container asks your Mac's `gh` for GitHub credentials, while Workroom is open. Anything running in the container can ask, so it has the same GitHub access that `gh` has on your Mac.
- A server you run in the container listens inside it, where your browser cannot reach it. Workroom forwards ports to `localhost` for you. See [Port forwarding](port-forwarding.md).
- Your setup and teardown scripts run in the container, with `WORKROOM_HOST` set to `docker` or `apple`. See [Remote workrooms](overview.md#setup-and-teardown-scripts).
- The image's own entrypoint and command don't run: the container runs Workroom's daemon in their place.

## Starting and stopping

Workroom creates the container, starts it when you open its workroom and it isn't running, and stops and removes it when you delete the workroom.

Terminals in a container workroom reattach after the container comes back. See [Reconnecting](reconnecting.md).

## Delete the workroom

Deleting the workroom destroys its container and everything in it, including changes and commits that were not pushed. See [Delete a remote workroom](overview.md#delete-a-remote-workroom).

A container belongs to the build of Workroom that made it. Release and Nightly cannot delete each other's containers.
