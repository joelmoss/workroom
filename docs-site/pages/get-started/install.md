---
title: Install
description: Install the Workroom app, put the workroom command on your PATH, or install the CLI on its own.
---

Install the Mac app and you have everything: the `workroom` command-line tool is bundled inside it.

## Install the app

You need a Mac with Apple silicon, running macOS 15 Sequoia or later.

1. [Download the latest Workroom](https://codaset.dev/workroom/download). Older versions are on the
   [Releases page](https://github.com/joelmoss/workroom/releases).
2. Open the `.dmg` and drag **Workroom** into **Applications**.
3. Open Workroom from Applications.

The app is signed and notarized by Apple, so it opens without a security warning. It updates itself in
the background. To check for an update yourself, choose **Workroom ▸ Check for Updates…**. See
[Updates and channels](../app/updates-and-channels.md).

The first time you open it, a short welcome walks you through what Workroom does and asks you to add
your first project. You can skip that and add a project later from the sidebar.

## Use the workroom command in Workroom's terminals

Every terminal pane in the app has `workroom` on its `PATH`, so you can run it there without installing
anything. It is the app's own copy. If you have also installed `workroom` yourself, with the menu item
below or the installer, your shell runs that one instead.

Nightly only. A pane's `workroom` comes first on its `PATH`, ahead of one you installed yourself: it
is the build of the Workroom daemon that runs the pane, so its commands always match it. See
[Environment variables](../reference/environment-variables.md#variables-your-terminals-receive).

## Use the workroom command in your shell

You don't need the CLI to use the app. If you also want the `workroom` command in other terminals, such
as Terminal:

1. Choose **Workroom ▸ Install ‘workroom’ Command in PATH…**.
2. Enter your password if macOS asks for it.

This links the app's own copy of the command into your `PATH`, so the app keeps it up to date. See the
[CLI reference](../cli/workroom.md) for what it can do.

## Install the CLI on its own

The CLI runs without the app, on macOS and Linux, on Apple silicon, Intel, ARM64 and x86-64. It needs
[Git](https://git-scm.com/) on your `PATH`. Windows builds of the CLI have ended; installed copies keep
working but get no updates.

```sh
curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | sh
```

The installer picks the right build for your system and installs it to `~/.local/bin`. If that folder
isn't on your `PATH`, it prints the line to add to your shell profile. On Linux the build is a single
static binary, so it runs on any distribution.

You can change what it installs with these variables:

| Variable                | What it does                                                                 |
| ----------------------- | ---------------------------------------------------------------------------- |
| `WORKROOM_INSTALL_PATH` | Installs to another folder, such as `/usr/local/bin`.                        |
| `VERSION`               | Installs a specific version, such as `v3.0.0`.                               |
| `WORKROOM_CHANNEL`      | `pre` installs the latest prerelease. `nightly` installs `workroom-nightly`. |

Set them in front of `sh`, so the installer sees them:

```sh
curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | WORKROOM_CHANNEL=pre sh
```

A CLI installed this way updates itself with `workroom update`. See
[Updates and channels](../app/updates-and-channels.md).

## Optional: GitHub CLI

The app's pull request and CI panel uses the [GitHub CLI](https://cli.github.com), `gh`, version 2.57.0 or
later, signed in with `gh auth login`. Everything else works without it.
