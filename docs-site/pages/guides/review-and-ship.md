---
title: Review and ship
description: Read a workroom's changes, commit and push them, and take the pull request through CI to merge, without leaving the app.
---

When the work in a workroom is ready, you can review it, commit it, push it and follow its pull request
to merge from the inspector on the right of the window. This guide covers each step. You can always do
any of them with `git` and `gh` in the workroom's terminal instead: the inspector shows the result
either way.

Press <kbd>⌘B</kbd> to show or hide the inspector.

## Read the changes

Press <kbd>⌥⌘C</kbd> to open **Changes**. It lists every file that differs from
the last commit in this workroom, live, as you or an agent edit them. Select a file to see its diff.

Diffs show unified or side by side. Choose the default in **Settings ▸ Appearance**. See
[Inspector](../app/inspector.md) for the rest of what it shows: the commit history, a single commit's
changes, and a browser for the workroom's files.

## Commit

1. Click the check mark in the **Changes** header to open **Commit changes**.
2. Tick the files to include. The checkbox at the top includes or excludes them all.
3. Write a **Summary**, and a **Description** if you want one.
4. Click **Commit**.

To change the message of the commit you just made, choose **Amend last commit** in the same sheet. To
commit a single file on its own, use **Commit Only This File** from that file.

If the commit fails, for example because a commit hook rejected it, the app shows why and what to do
next.

## Push

When the workroom has commits that aren't on the remote yet, the toolbar at the top of the inspector
offers **Push origin**. Click it to push the workroom's branch. A new workroom's branch isn't on the
remote yet, so the toolbar offers **Publish branch** instead, which pushes the branch and sets its
upstream.

The same toolbar fetches from the remote, and pulls when the remote has commits you don't.

## Open a pull request

The app shows and manages pull requests but doesn't open them. Open one from the workroom's terminal
with the [GitHub CLI](https://cli.github.com):

```sh
gh pr create --fill
```

Or ask your coding agent to open it.

## Follow it through CI

Press <kbd>⌥⌘P</kbd> to open the **Pull Request** panel. It shows the pull
request's state, its reviewers, and each CI check as it runs. Click a check to open it on GitHub. The
sidebar shows the branch's CI result too, so you can see a failing build without opening the panel.

From the panel you can:

- Mark a draft **Ready for Review**, or turn it back into a draft with **Convert to Draft**.
- Merge it with **Merge**, **Squash and merge** or **Rebase and merge**. Choose the method from the
  merge button's menu.
- **Close Pull Request**, or **Reopen Pull Request** a closed one.

The panel needs `gh` 2.57.0 or later, signed in with `gh auth login`. Without it, the panel tells you
what is missing.

## Clean up

Once the pull request is merged, delete the workroom: hover over it in the sidebar, click its trash
button and confirm. If your project has a [teardown script](prepare-a-project.md#undo-it-with-a-teardown-script),
it runs first. The workroom's branch is kept; delete it with `git branch -D` when you're sure.
