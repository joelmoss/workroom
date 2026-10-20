---
title: Projects
description: Add, create, configure and delete the projects that Workroom lists in its sidebar.
---

A project is a Git repository you have registered with Workroom. This page shows how to add one, set its run command and base branch, and remove it.

## The sidebar

The sidebar on the left lists every project. Each project expands into its root, then its workrooms. The root is the project's own checkout. Click the project name to expand or collapse it. Workroom remembers which projects are open, and which one you had selected, when you relaunch.

Each project row has a **+** button that creates a workroom. See [Workrooms](workrooms.md#create-a-workroom). Hover the row to reveal a gear button, which opens [Project Settings](#project-settings).

Right-click a project row for **New Workroom**, **Project Settings…** and **Delete Project…**.

To hide or show the sidebar, use **View ▸ Projects** (<kbd>⌃⌘S</kbd>).

## Add a project

1. Click the **+** at the bottom right of the sidebar, or choose **File ▸ New Project…**. With no projects yet, the sidebar is hidden and the main window shows an **Add Project…** button instead.
2. Choose one of the two sources:
   - **From existing path…** adds a Git repository that is already on disk.
   - **Create new directory…** makes a new folder and runs `git init` in it.
3. Type the full path in the field, or click **Choose…** to pick a folder. A leading `~` works.
4. Click **Add Project**.

The **Add Project** button stays off until the path is absolute. In **Create new directory…** mode it also stays off if the path is an existing file, and a folder that does not exist yet is created and initialised as a Git repository. **From existing path…** needs a folder that is already a Git repository.

> [!NOTE]
> Workroom does not accept a path on another computer, such as `ssh://…` or `host:repo`. Add the project from a local repository. A remote workroom always belongs to a local project. See [Remote workrooms](../remote/overview.md).

## Project Settings

Open Project Settings from the gear on a project row, or from the project's right-click menu. Your changes apply when you click **Save**. **Cancel** throws them away.

### Run command

**Run command** is the command Workroom starts for the project, for example `npm run dev`. It runs in a dedicated terminal at the workroom's directory, in your login shell. Start it from the Run button in a workroom's title bar or with <kbd>⌘R</kbd>. See [Run a command](terminals-and-tabs.md#run-a-command).

Turn on **Run automatically when a workroom is created** to start the command in every new workroom. The switch is off, and stays off, while the command is empty.

If you press <kbd>⌘R</kbd> in a project that has no run command, Project Settings opens with a warning that you cannot run the workroom until you set one.

### Base branch {nightly}

**Base branch** is the branch new workrooms of this project start from. Leave it empty to use the app default from **Settings ▸ General ▸ New Workrooms** (see [Settings](settings.md#general)), or `origin`'s default branch when neither is set.

New workrooms start from `origin`'s copy of the branch, which Workroom fetches first, and fall back to the local branch. Write `upstream/main` to start from another remote's branch, such as a fork's upstream. Remote workrooms need a branch that exists on `origin`.

The CLI sets the same value with [`workroom base`](../cli/workroom-base.md).

## A missing folder

If a project's folder is no longer there, its root row shows a yellow warning triangle. Hover it to read **Project folder not found**. Workroom hides the Run button on that row. Move the folder back, or delete the project and add it again from its new location.

A workroom whose folder or worktree has gone also shows a yellow triangle, with the reason in its tooltip.

## Delete a project

Deleting a project removes it from Workroom. What happens to the files depends on the option you pick.

1. Right-click the project and choose **Delete Project…**.
2. Choose what to delete:
   - **Remove from Workroom only** (the full label adds that all files are kept) forgets the project and leaves every file on disk. This is the default.
   - **Also delete N workrooms** (the label adds that this is permanent and branches are kept) removes the workroom directories. This cannot be undone. The branches stay in your repository. This option only appears when the project has workrooms.
   - **Delete everything → Bin (project + N workrooms)** moves the project folder and all of its workrooms to the Bin. You can put them back from the Trash. With no workrooms it reads **Delete the project → Bin**.
3. Type the project's name to confirm. The delete button stays off until the name matches exactly, including case.
4. Click the delete button. Its label follows your choice: **Delete Project**, **Delete Project & N Workrooms** or **Delete Everything to Bin**.

With either option that removes workrooms, each workroom's teardown script runs before its directory goes, and a failing teardown stops the delete. **Remove from Workroom only** runs no scripts. See [Delete a workroom](workrooms.md#delete-a-workroom).

Deleting a project also closes its terminals. If a coding agent started with **Investigate** is still running there, the sheet warns you that deleting stops it. Workroom will not delete a project while a workroom in it is still being created.

> [!WARNING]
> Whichever option you choose, deleting a project destroys its remote workrooms and the hosts they run on, with everything on them that is not pushed.
