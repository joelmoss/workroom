---
title: Your first workroom
description: Add a project, make a workroom, change something in it, and take it all the way to a merged pull request.
---

This walkthrough takes one small change from start to finish: you add a project, make a workroom for
the change, work in its terminal, review the diff, commit, push, open a pull request and clean up. It
takes about ten minutes, and it uses the same steps you'll use for every task after.

You need the app [installed](install.md) and a git repository on this Mac. Pull requests also need the
[GitHub CLI](install.md#optional-github-cli).

## Add a project

1. Click **+** at the bottom right of the sidebar. The **New Project** sheet opens.
2. Choose **From existing path…**, then **Choose…**, and pick your repository's folder.
3. Click **Add Project**.

The project appears in the sidebar. Workroom only reads your checkout, which is called the root. It never
changes it.

To start a brand-new project instead, choose **Create new directory…**, and Workroom makes the folder
and a git repository in it.

## Create a workroom

1. Hover over the project's row in the sidebar and click its **+**.
2. If a menu opens asking where the workroom goes, choose **This Mac**.

A new workroom opens straight away, with a generated name such as `swift-meadow`. You can also press
<kbd>⌘N</kbd>, type to find the project, and press <kbd>Return</kbd>.

The workroom is a real folder, `~/workrooms/swift-meadow`, on a new branch, `workroom/swift-meadow`,
that starts from the latest default branch on `origin`. Your root and any other workroom are untouched.

### Watch it being made {nightly}

While the workroom is made, its pane shows a checklist of the steps: **Fetch base branch**, **Create
worktree**, then **Copy local files** and **Run setup script** if your project has them. Click a step to
see its output. When the list is done, click **Done** to open the workroom's terminal.

## Work in the terminal

The terminal is already in the workroom's folder. Use it as you would any terminal: run your tests,
start a coding agent such as `claude` or `codex`, or edit files in your editor.

To run something alongside it, press <kbd>⌘D</kbd> to split the pane and get a second
terminal, for a dev server say. Press <kbd>⌘T</kbd> for a new tab instead.

Switch to another workroom and come back: everything is still running. Each workroom keeps its own
terminals alive until you close them. When a terminal you aren't looking at needs you, its tab and
sidebar row light up. See [Notifications](../app/notifications.md).

## Review your changes

1. Press <kbd>⌘B</kbd> to show the inspector on the right.
2. Press <kbd>⌥⌘C</kbd> to open **Changes**.

Changes lists every file you have changed in this workroom. Select one to see its diff, unified or side
by side. See [Inspector](../app/inspector.md).

## Commit and push

1. Click the check mark in the **Changes** header to open **Commit changes**.
2. Tick the files you want to commit, write a summary, and click **Commit**.
3. Click **Publish branch** in the toolbar at the top of the inspector. The branch isn't on GitHub yet,
   so this first push publishes it.

The branch, `workroom/swift-meadow`, is now on GitHub. If you prefer, do all of this with `git` in the
terminal: the inspector picks it up either way.

## Open a pull request

The app tracks pull requests but doesn't open them, so open one from the terminal with the GitHub CLI:

```sh
gh pr create --fill
```

Then press <kbd>⌥⌘P</kbd> to see it in the **Pull Request** panel: its state, its
reviews, and each CI check as it runs. When it is ready, merge it from the panel's merge button, which
offers **Merge**, **Squash and merge** or **Rebase and merge**.

## Delete the workroom

When the work is merged, you don't need the workroom any more.

1. Hover over the workroom in the sidebar and click its trash button.
2. Confirm.

Workroom closes its terminals and removes its folder. The branch is kept, in case you need it; delete it
with `git branch -D workroom/swift-meadow` when you're sure.

## Next steps

- [Prepare a project](../guides/prepare-a-project.md) so new workrooms install their dependencies and
  get your `.env` files by themselves.
- [Run agents in parallel](../guides/run-agents-in-parallel.md), one workroom per task.
- [Review and ship](../guides/review-and-ship.md) in more depth.
