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
2. **Workspace.** Pick the workspace Workroom keeps its hosts in. Workroom uses a project named **Workroom** there, or makes one, and gives this Mac an environment of its own in it.

Click **Create Workroom**, and the create carries on.

## Create a workroom on Railway

1. Click the **+** on a project, or right-click the project and choose **New Workroom**.
2. Under **Remote**, choose **Railway**.
3. Watch the checklist in the pane.

The sandbox uses Railway's default image, region and size. Its idle timeout is off, so it keeps running, and Railway keeps billing for it, until you delete the workroom.

The first workroom on a Mac makes an SSH key for Railway in Workroom's own folder and adds it to your Railway account. Workroom reaches the sandbox through Railway's SSH relay, and remembers the relay's host key the first time. If the relay later shows a different key, Workroom refuses to connect and says why.

## GitHub on the sandbox

Railway has no GitHub integration for sandboxes, so Workroom gives each sandbox a copy of this Mac's `gh` token:

- When it creates the sandbox, Workroom writes the token to a file there that only the sandbox's own account can read. It is never a Railway variable, so it isn't kept in Railway's variable store.
- The sandbox's git uses it for github.com, and any GitHub remote, in its `git@github.com:` or `ssh://` form too, goes over HTTPS with it.
- Each time Workroom connects to the sandbox, it checks the copy against this Mac's current token and replaces it if you rotated it.

The token has the scope you gave `gh`, and anything running in the workroom can read it.

## Signed out

If your Railway sign-in is revoked or expires, a Railway workroom's **Details** says Workroom is signed out of Railway. Click **Sign In to Railway…** to sign in again.

## A sandbox that is gone

If a sandbox is destroyed outside Workroom, for example from Railway's dashboard, its workroom's **Details** says the host is gone. Its work went with it. Click **Remove Workroom…** to remove the workroom.

## Delete the workroom

Deleting the workroom destroys its sandbox and everything on it. See [Delete a remote workroom](overview.md#delete-a-remote-workroom).
