---
title: exe.dev
description: Set up exe.dev once from the app, then create workrooms that run on exe.dev VMs.
nightly: true
---

[exe.dev](https://exe.dev) is a cloud service that runs each workroom on a VM of its own. This page covers the one-time setup, which Workroom walks you through, and creating a workroom on exe.dev. For what remote workrooms are, see [Remote workrooms](overview.md).

## Before you start

- Your project's `origin` must be on github.com, and its base branch must be on `origin`. See [Remote workrooms](overview.md#what-a-project-needs).
- You need an exe.dev account, a paid plan, and a GitHub account connected to exe.dev. After signing up, payment is required, as the setup sheet says.

You do not need to prepare any of it first. Workroom checks each one and asks only for what is missing.

## Set up exe.dev

The first time you create a workroom on exe.dev, Workroom checks that your account is ready. If it is, the create carries on. If it is not, the **Set up exe.dev** sheet opens over the new workroom's pane, and the pane's **Check exe.dev account** step shows **Waiting for you**.

The sheet has three steps. Workroom checks each one itself and ticks it off when it is done.

1. **Account.** exe.dev signs you in with an SSH key.
   - If your Mac has no SSH key, click **Create SSH Key**. Workroom makes one at `~/.ssh/id_ed25519`, the key `ssh` uses by default. It has no passphrase, so anyone who can use your Mac account can use it, and `ssh` offers it to every server.
   - If your key has a passphrase, add it to your ssh agent with `ssh-add`, then click **Try Again**.
   - Enter your email and click **Send Link**. Use the email of the account you already have, or a new one to create an account. exe.dev sends you a link. Click it, and Workroom carries on by itself. **Use a Different Email** changes the address.
   - To sign up by hand instead, click **Sign Up in a Terminal Instead**. A terminal inside the sheet runs exe.dev's own sign-up. Enter your email when it asks, then click the link it sends. **Use the Email Form** goes back.
2. **Plan.** exe.dev runs VMs on a paid plan. Click **Choose a Plan**, and pick one on exe.dev in your browser. Workroom carries on as soon as the plan is active.
3. **GitHub.** Click **Connect GitHub**, connect your GitHub account on exe.dev, and give its GitHub App access to your repositories. This lets your VMs clone and push as you, with no GitHub token on them.

For the Plan and GitHub steps, **Open exe.dev Again** reopens the page, and **Check Again** reads your account again, for a step you finished elsewhere.

When every step has a tick, click **Create Workroom**. The create that the sheet interrupted carries on, in the same pane. **Cancel** ends it and removes the pane. Closing the sheet cancels the setup.

If a check cannot get an answer, the step says so, and **Create Workroom** is available anyway. In that case exe.dev decides: if something is really missing, the create fails and says what.

## Create a workroom on exe.dev

1. Click the **+** on a project, or right-click the project and choose **New Workroom**.
2. Under **Remote**, choose **exe.dev**.
3. Watch the checklist in the pane. When it finishes, click **Done**, or turn on **Close automatically when done** and the terminal opens by itself.

On your project's first exe.dev workroom, Workroom adds an exe.dev GitHub integration for the repository, so the VM can clone and push. It stays for the project's next workrooms. If exe.dev won't add one, the create carries on, and a private repository then fails at the clone.

The workroom's terminals run on the VM. A coding agent you start there keeps running when you close Workroom. See [Reconnecting](reconnecting.md) for what happens when your Mac sleeps or changes network.

If the clone fails with a message that GitHub refused it, check that GitHub is still connected at `https://exe.dev/integrations#github`, and that `ssh exe.dev integrations list` shows the repository attached to `auto:all`.

## Ports

An exe.dev VM has no **Ports** list in the inspector. To reach a server running on it from a browser, share the port with exe.dev. See [Port forwarding](port-forwarding.md#boxd-and-exedev).

## Delete the workroom

Deleting the workroom destroys its VM and everything on it. See [Delete a remote workroom](overview.md#delete-a-remote-workroom).
