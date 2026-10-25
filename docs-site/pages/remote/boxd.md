---
title: boxd
description: Set up boxd once from the app, then create workrooms that run on boxd machines.
nightly: true
---

[boxd](https://boxd.sh) is a cloud service that runs each workroom on a machine of its own. This page covers the one-time setup, which Workroom walks you through, and creating a workroom on boxd. For what remote workrooms are, see [Remote workrooms](overview.md).

To use a server you already have, choose an [SSH host](ssh.md) instead.

## Before you start

- Your project's `origin` must be on github.com, and its base branch must be on `origin`. See [Remote workrooms](overview.md#what-a-project-needs).
- You need a boxd account. After signing up, payment is required, as the setup sheet says.

You do not need to install anything first. Workroom installs boxd for you.

## Set up boxd

The first time you create a workroom on boxd, Workroom checks that boxd is ready. If it is, the create carries on. If it is not, the **Set up boxd** sheet opens over the new workroom's pane, and the pane's **Check boxd account** step shows **Waiting for you**.

The sheet has three steps. Workroom checks each one itself and ticks it off when it is done, so you only do what is not done yet.

1. **Install.** Click **Install boxd**. Workroom runs boxd's own installer, which puts the `boxd` command in `~/.local/bin`. It needs no admin password and changes nothing else. If it fails, click **Try Again**.
2. **Account.** Click **Sign In**. boxd opens in your browser. Sign in there, or create an account there, and Workroom carries on by itself. While it waits, **Open the Sign-In Page Again** reopens the page, and **Stop** stops waiting.
3. **GitHub.** Click **Connect GitHub**, and connect your GitHub account in your browser. This lets your machines clone and push as you, through boxd's git integration. **Open GitHub Again** and **Stop** work as they do for the account step.

When every step has a tick, click **Create Workroom**. The create that the sheet interrupted carries on, in the same pane. **Cancel** ends it and removes the pane. Closing the sheet cancels the setup.

If a check cannot get an answer, the step says so, and **Create Workroom** is available anyway. **Check Again** reads the step again. In that case boxd decides: if something is really missing, the create fails and says what.

> [!NOTE]
> If the **Account** step says you are signed in to boxd but Workroom can't read the sign-in, boxd has changed how it keeps it. Update Workroom, then try again.

## Create a workroom on boxd

1. Click the **+** on a project, or right-click the project and choose **New Workroom**.
2. Under **Remote**, choose **boxd**.
3. Watch the checklist in the pane. When it finishes, click **Done**, or turn on **Close automatically when done** and the terminal opens by itself.

The workroom's terminals run on the boxd machine. A coding agent you start there keeps running when you close Workroom. See [Reconnecting](reconnecting.md) for what happens when your Mac sleeps or changes network.

If the clone fails with a message that GitHub refused it, a boxd machine reaches GitHub through your boxd git integration. Connect it by running `boxd manage integrations connect git` in a terminal.

## Ports

A boxd machine has no **Ports** list in the inspector. To reach a server running on it from a browser, publish the port with boxd. See [Port forwarding](port-forwarding.md#boxd-and-exedev).

## Delete the workroom

Deleting the workroom destroys its machine and everything on it. See [Delete a remote workroom](overview.md#delete-a-remote-workroom).
