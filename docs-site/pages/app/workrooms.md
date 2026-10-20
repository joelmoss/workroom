---
title: Workrooms
description: Create, open, switch between, label, move and delete workrooms in the Workroom app.
---

A workroom is a branch of your project with its own working copy and its own terminals. On your Mac it is a Git worktree. This page covers everything you do with workrooms in the app, from creating one to deleting it.

## Create a workroom

Each workroom gets a generated name such as `swift-meadow`, and a branch called `workroom/swift-meadow`. New workrooms start from `origin`'s default branch unless you set a [base branch](projects.md#base-branch). Workrooms live under `~/workrooms` by default.

You can start a create in three ways:

- Click the **+** on a project's row in the sidebar.
- Right-click a project and choose **New Workroom**.
- Press <kbd>⌘N</kbd> (**File ▸ New Workroom…**) and pick a project.

The picker for <kbd>⌘N</kbd> has a **Filter projects** field. Type to narrow the list, use <kbd>↑</kbd> and <kbd>↓</kbd> to move, and press <kbd>Return</kbd> to pick. Press <kbd>⌥Return</kbd> to open the new workroom beside the current one as a split. <kbd>⌥⌘N</kbd> (**File ▸ New Workroom (split right)**) opens the picker already in split mode.

The workroom opens with a terminal in its directory when the create finishes. If the project has a [run command](projects.md#run-command) set to run automatically, it starts then.

### Choose where it runs {nightly}

After you pick a project, Workroom asks where the workroom goes: **This Mac**, a local container, or a remote provider. The sidebar **+** and **New Workroom** menus offer the same choices. Press <kbd>←</kbd> or click the back arrow to return to the project list.

Anything other than **This Mac** is a remote workroom. See [Remote workrooms](../remote/overview.md).

### Watch the steps {nightly}

A new workroom opens a creation pane at once, with a checklist of the steps. For a workroom on your Mac they are:

1. **Fetch base branch**
2. **Create worktree**
3. **Copy local files**, which copies the files listed in your project's `.worktreeinclude`
4. **Run setup script**, which runs your project's `scripts/workroom_setup`

The last two rows appear only when your project has a `.worktreeinclude` or a setup script.

Each row shows how long its step took. Click a row, or press <kbd>Space</kbd> on it, to open its log. <kbd>↑</kbd> and <kbd>↓</kbd> move between rows, <kbd>→</kbd> opens a log and <kbd>←</kbd> closes it. A row says **Waiting for you** while it needs an answer from you.

When every step is done, click **Done** to open the terminal. Turn on **Close automatically when done** at the bottom left of the pane, and the pane closes itself a few seconds after the workroom is ready. The same switch is in **Settings ▸ General** as **Close the checklist automatically when done**.

If a step fails, the pane shows the reason and two buttons:

| Failure | Buttons |
| --- | --- |
| The create failed before a workroom existed | **Try Again**, **Close** |
| The setup script failed | **Open Anyway**, **Delete Workroom…** |
| The setup script is new or changed and needs your approval | **Approve**, **Cancel** |

**Open Anyway** opens the workroom's terminal even though setup failed. The run command does not start automatically. See [Prepare a project](../guides/prepare-a-project.md) for setup scripts and the approval step.

## Open a workroom

Click a workroom in the sidebar to open it. Workroom shows its terminals, and your other workrooms keep running in the background.

To open one by name, press <kbd>⌘O</kbd> (**File ▸ Open Workroom…**). Type in **Filter workrooms**, pick a row and press <kbd>Return</kbd>. Rows are grouped by project, and each project's root comes first. Press <kbd>⌥Return</kbd>, or use <kbd>⌥⌘O</kbd> (**File ▸ Open Workroom (split right)**), to open it as a split instead. See [Splits and windows](splits-and-windows.md).

You can also right-click a workroom in the sidebar and choose **Open (split right)**.

## Switch between workrooms

| To do this | Use |
| --- | --- |
| Switch to the 1st to 9th workroom tab | <kbd>⌥⌘1</kbd> to <kbd>⌥⌘9</kbd> |
| Step through workroom tabs | <kbd>⇧⌥⌘→</kbd> and <kbd>⇧⌥⌘←</kbd> (**Go ▸ Next Workroom Tab** and **Previous Workroom Tab**) |
| Flip to the workroom you used last | <kbd>⌥Tab</kbd> (**Go ▸ Last-Used Workroom**) |
| Go back and forward through where you have been | <kbd>⌘[</kbd> and <kbd>⌘]</kbd> |
| Jump to a terminal that needs you | <kbd>⇧⌘M</kbd> (see [Notifications](notifications.md)) |

Open workrooms also appear as tabs in a bar across the top of the window. Drag a tab to reorder it.

### The workroom switcher

Hold <kbd>⌥</kbd> and press <kbd>Tab</kbd>. A quick tap flips to the workroom you were in before. If you keep the key held, or press <kbd>Tab</kbd> again, a rail of cards appears, ordered by how recently you used each workroom. Press <kbd>Tab</kbd> or the arrow keys to move along the rail, and release <kbd>⌥</kbd> to switch. You can also click a card. <kbd>Esc</kbd> cancels.

The switcher steps through workrooms in every window. <kbd>⌃Tab</kbd> does the same for the panes of the current workroom.

## Label a workroom

A label is a name that shows in place of the workroom's own name. The workroom and its branch keep their names.

1. Right-click the workroom, in the sidebar or on its tab, and choose **Set Label…**.
2. Type the label and click **Save**.

Choose **Edit Label…** to change it, or **Remove Label** to go back to the real name. A label cannot match the name or label another workroom in the same project already shows.

## Close a workroom

Right-click a workroom's tab and choose **Close** to close all of its terminals and take it out of the tab bar. The workroom itself and its files stay, and you can open it again. Workroom asks you to confirm.

## Move a workroom to another window {nightly}

You can give a workroom a window of its own, or move it into another Workroom window. Its terminals keep running.

- Drag its tab, or its title bar, out of the window. It opens in a new window at the drop point.
- Drop it on another Workroom window to join that window. It lands at the slot under your cursor on that window's tab bar, or at the end.
- Right-click the workroom, in the sidebar or on its tab, and choose **Move to New Window**.
- Use **Window ▸ Move workroom into new window** for the selected workroom.

A window's only workroom cannot move, because that would leave an empty window. The items are also off while the workroom is still being created.

## Delete a workroom

Deleting removes the workroom's directory. Workroom keeps the `workroom/<name>` branch in your repository.

1. Hover the workroom in the sidebar and click the trash button, or right-click it and choose **Delete Workroom…**.
2. Confirm in the **Delete 'name'?** dialog.

The row leaves the sidebar at once. Workroom runs your project's `scripts/workroom_teardown` script in the background, then removes the directory. You cannot delete a workroom while its setup is still running.

### When the teardown fails

If the teardown script fails or can't start, the delete stops. The workroom comes back in the sidebar with its folder and branch, but its terminals were closed before the script ran, so open new ones if you keep it. A sheet titled **Teardown of ‘name’ failed** shows why, with the script's output. Fix the script and delete again. If the script has not been approved on this Mac, the sheet is titled **Approve the teardown script of ‘name’?** instead and shows the script.

### Delete Anyway {nightly}

The sheet has a **Delete Anyway** button that deletes the workroom without running the teardown script. If the script has not been approved on this Mac, the sheet shows it with an **Approve and Run** button. See [Prepare a project](../guides/prepare-a-project.md).

> [!NOTE]
> Deleting a remote workroom destroys its host and everything on it, including changes and commits that are not pushed. The confirmation dialog says so.
