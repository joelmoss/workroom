---
title: Railway
description: Sign in to Railway once from the app, then create workrooms that run in Railway sandboxes.
nightly: true
---

[Railway](https://railway.com) runs each workroom in a sandbox of its own, in your Railway account. This page covers signing in, which Workroom walks you through, and creating and deleting a workroom on Railway. For what remote workrooms are, see [Remote workrooms](overview.md).

## Before you start

- Your project's `origin` must be on github.com, and its base branch must be on `origin`. See [Remote workrooms](overview.md#what-a-project-needs).
- You need a Railway workspace on the Hobby or Pro plan. On Trial and Free, Railway destroys a sandbox after 5 minutes without use and that can't be turned off, so Workroom refuses those workspaces.
- `gh` must be signed in to github.com on this Mac (`gh auth login`). The sandbox clones and pushes with your `gh` token, so your commits and pushes are yours. See [GitHub on the sandbox](#github-on-the-sandbox).

Workroom never runs your `railway` command or reads its `~/.railway` folder, so your own Railway CLI keeps working as you left it.

## Set up Railway

The first time you create a workroom on Railway, the **Set up Railway** sheet opens. You can also open it from **Settings**, **Remote Hosts**, **Set Up Railway…**.

1. **Account.** Click **Sign In with Railway**. Your browser opens Railway's page. Tick the workspaces Workroom may use, then approve. There is no token to copy. Each Workroom app (Workroom and Workroom Nightly) signs in once of its own.
2. **Workspace.** Pick the workspace Workroom keeps its hosts in.
3. **Project.** Pick one of the workspace's projects, or **New project named Workroom**, then click **Use This Project**. Workroom makes the project if it's new, and gives this Mac an environment of its own in it, so another Mac's cleanup never touches this Mac's hosts. At launch Workroom removes only sandboxes this Mac made whose workroom was never saved (after a crash, say), so even two Macs that end up sharing an environment, as a Mac restored from another's backup does, never remove each other's. A project of their own keeps your hosts apart from your apps.

Click **Create Workroom**, and the create carries on.

To move this Mac's hosts to another workspace or project later, delete its Railway workrooms first. While this Mac's environment still has a sandbox, Workroom refuses the move and says why: it would lose track of that sandbox, which would keep billing.

## Create a workroom on Railway

1. Click the **+** on a project, or right-click the project and choose **New Workroom**.
2. Under **Remote**, choose **Railway**.
3. Watch the checklist in the pane.

The sandbox is made in the region and size your host options say, from Railway's default image or a checkpoint (see [Region, size and checkpoint](#region-size-and-checkpoint)). Its idle timeout is off, so it keeps running, and Railway keeps billing for it, until you delete the workroom.

The first workroom on a Mac makes an SSH key for Railway in Workroom's own folder and adds it to your Railway account. Workroom reaches the sandbox through Railway's SSH relay, and remembers the relay's host key the first time. If the relay later shows a different key, Workroom refuses to connect and says why.

## Region, size and checkpoint

A Railway workroom's host takes three settings. Choose them in [Settings ▸ Remote Hosts](../app/settings.md#remote-hosts), in [Settings ▸ Projects](../app/settings.md#projects), or for one workroom with the **Configure** button (sliders icon) beside **Railway** in the **New Workroom** dialog. The most specific one wins. See [Choose a host's image and size](overview.md#choose-a-hosts-image-and-size).

- **Region.** Where Railway runs the sandbox: US West (California), Railway's default; US East (Virginia); EU West (Amsterdam); or Southeast Asia (Singapore). One near you answers faster.
- **CPU** and **Memory.** Up to what your workspace's Railway plan allows. If Workroom can't read the plan, type them instead. Railway bills the memory a sandbox uses.
- **Checkpoint.** A saved copy of a sandbox's disk to start from, with your tools already installed. Empty starts from Railway's default image.

### Start from a checkpoint

Workroom offers the checkpoints in this Mac's own environment of your Railway project, and only those: a checkpoint another Mac made is in that Mac's environment, so this Mac can't use it. This Mac's environment is named `mac-<your Mac's name>-<six characters>`.

To make one, set a Railway workroom's sandbox up as you want it, then capture it as a checkpoint from the sandbox's page on Railway's dashboard, or with `railway sandbox checkpoint create` in a terminal. Run `railway sandbox checkpoint create --help` to see how to name the sandbox and the checkpoint. Workroom has no button for it.

A sandbox made from a checkpoint of a used workroom starts clean: Workroom removes that workroom's checkout and its copy of your `gh` token, then clones afresh and writes this Mac's token. Anything installed outside the checkout, such as your toolchain, stays.

If the setting warns that there's no checkpoint of that name, it was made in another Mac's environment or has since been deleted, and a create from it is refused before any sandbox is made.

## GitHub on the sandbox

Railway has no GitHub integration for sandboxes, so Workroom gives each sandbox a copy of this Mac's `gh` token:

- When it creates the sandbox, Workroom writes the token to a file there that only the sandbox's own account can read. It is never a Railway variable, so it isn't kept in Railway's variable store.
- The sandbox's git uses it for github.com, and any GitHub remote, in its `git@github.com:` or `ssh://` form too, goes over HTTPS with it.
- Each time Workroom connects to the sandbox, it checks the copy against this Mac's current token and replaces it if you rotated it.

The token has the scope you gave `gh`, and anything running in the workroom can read it. So can anyone who can open a shell on the sandbox, which every member of your Railway workspace can.

A checkpoint you take on Railway's dashboard or with its CLI keeps the token file. Workroom removes it only from a sandbox it makes from a checkpoint itself, so a sandbox someone restores from that checkpoint outside Workroom still holds the token. If a checkpoint like that leaves your hands, revoke the token on GitHub and run `gh auth login` again; Workroom gives your sandboxes the new one on their next connect.

## Signed out

If your Railway sign-in is revoked or expires, a Railway workroom's **Details** says Workroom is signed out of Railway. Click **Sign In to Railway…** to sign in again.

## A sandbox that is gone

If a sandbox is destroyed outside Workroom, for example from Railway's dashboard, its workroom's pane says the host is gone, and its terminals stop trying to reach it. Its work went with it. **Remove Workroom…**, in the pane or when you right-click the workroom, is the only thing left to do.

## A create that may have left a sandbox

Sometimes a create asks Railway for a sandbox and Railway's answer never arrives, for example when the network drops at that moment. Railway may still have made the sandbox, and it bills until it's destroyed. Workroom can't tell which sandbox it was, so it never destroys one on its own.

Instead, a Railway workroom's **Details**, and **Settings**, **Remote Hosts**, under **Railway**, show **A Railway create may have left a sandbox**. Under it are the sandboxes Railway made around that time that no workroom on this Mac uses. Workroom asks Railway for them each time the notice shows.

- **Destroy…** destroys that sandbox, after you confirm. Do this only for a sandbox you know the failed create made. If a workroom on another Mac uses it, that workroom's work is lost.
- **Dismiss** removes the notice without destroying anything. Use it once you've checked Railway's dashboard yourself.
- **Check Again** asks Railway for the sandboxes again.

The notice stays, across relaunches, until you do one of these.

## Delete the workroom

Deleting the workroom destroys its sandbox and everything on it. See [Delete a remote workroom](overview.md#delete-a-remote-workroom).
