---
title: Projects
description: Add, create, configure and delete the projects that Workroom lists in its sidebar.
---

A project is a Git repository you have registered with Workroom. This page shows how to add one, set its run command and base branch, and remove it.

## The sidebar

The sidebar on the left lists every project. Each project expands into its root, then its workrooms. The root is the project's own checkout. Click the project name to expand or collapse it. Workroom remembers which projects are open, and which one you had selected, when you relaunch.

Each project row has a **+** button that creates a workroom. See [Workrooms](workrooms.md#create-a-workroom). Hover the row to reveal a gear button, which opens the project's [settings](#project-settings). Nightly only: the **+** shows only while you hover the row too, beside the gear, and so does the arrow after the project's name. Click anywhere else on the row to fold its workrooms away or show them again.

Right-click a project row for **New Workroom**, **Project Settings…** and **Delete Project…**.

To hide or show the sidebar, use **View ▸ Projects** (<kbd>⌃⌘S</kbd>). Nightly only: it's **View ▸ Sidebar ▸ Show Sidebar**.

### Open Tabs and Projects {nightly}

The sidebar shows one of two views at a time. The bar at its top switches between them: the terminal icon is the **Open Tabs** view, and the four-squares icon is **Projects**, the project tree. Hover either for its name. The view you're on is underlined. A new window starts on **Open Tabs**, and each window remembers its view when you relaunch. **View ▸ Sidebar ▸ Open Tabs** (<kbd>⌃⌘T</kbd>) and **View ▸ Sidebar ▸ Projects** (<kbd>⌃⌘P</kbd>) switch too, and show the sidebar if it's hidden. The one showing is checked.

A dot in the accent colour after the other view's tab means something there needs you: a workroom with unread notifications, or a terminal waiting for you.

The **+** at the end of the bar works on the view you're on. In **Open Tabs** it opens a menu: **New Terminal** (<kbd>⌥⌘T</kbd>) and **New Terminal Group…**; to open a workroom, press <kbd>⌘O</kbd> (**File ▸ Open Workroom…**). In **Projects** it adds a project.

While you drag a terminal or a tab, rest it on the other view's tab for a moment to switch to that view, then drop it on a row there. Let a terminal go on the **Open Tabs** view's tab to make it a standalone terminal.

The sidebar sits flat against the window's edge, with a thin line between it and the workroom. When you hide it and hover the sidebar button to reveal it, it floats over the workroom as a card, with the same bar and views.

### The Open Tabs view {nightly}

The **Open Tabs** view lists this window's workroom tabs, in the title bar's order, so you can see everything open in the window at once when the tabs there have run out of room. Each row unfolds to that workroom's tabs, the same ones the tab strip shows: terminals, diffs, files and changesets. Another window's tabs never appear.

- **Select.** Click a row to select it, or one of its tabs to show that tab. Selecting a workroom unfolds it. Fold it by hand, with the arrow that takes the place of its icon when you hover the row, and it stays folded until you next select it.
- **What's highlighted.** Only the row that has the keyboard: the focused tab's row, or the selected workroom's own row while it shows no tab rows.
- **Close.** Hover a row for its **✕**, or right-click it and choose **Close**. It asks when the title bar's tab would. A workroom's, project root's or terminal group's row also shows a **+** on hover, for a new terminal in it.
- **Menus.** A row's right-click menu is the one its title-bar tab has.
- **Reorder, split, move.** Drag a row as you drag its title-bar tab: up or down to reorder the tabs, onto a pane to split, out of the window to move the workroom to another window or a new one. Drag a tab row to reorder it among its workroom's tabs, between the rows outside its workroom to make it a standalone terminal there (see [Move a terminal](terminals-and-tabs.md#move-a-terminal)), onto another row or tab to move it there, into the panes to split, or out of the window to tear it off. The row lifts off the list and follows the pointer, and the other rows slide apart to show where it will land; let go and it settles there. Over the middle of a row that takes it, that row lights up instead. Press <kbd>Esc</kbd>, or let go where nothing takes it, and it goes back to its place. A workroom's tab rows leave with it while you drag and come back under it when it lands.
- **Terminals with no project.** A standalone terminal or a terminal group is listed only while it has tabs in this window, as its title-bar tab is, and leaves when its last tab closes. A group you closed is not lost: open it again with **Open Workroom…** (<kbd>⌘O</kbd>). See [Terminals with no project](terminals-and-tabs.md#terminals-with-no-project).
- **Nothing open.** The view offers a **New Terminal +** link, which opens a new standalone terminal.

The tabs in the title bar are unchanged.

### The Projects view {nightly}

The **Projects** view is the project tree described above. With no projects yet, while the **Open Tabs** view lists standalone terminals, it says **No projects yet** and offers **Add Project…**.

## Add a project

1. Click the **+** at the bottom right of the sidebar, or choose **File ▸ New Project…**. Nightly only: the **+** is beside **Projects** at the top of the projects instead. With no projects yet, the sidebar is hidden and the main window shows an **Add Project…** button instead.
2. Choose one of the three sources:
   - **From existing path…** adds a Git repository that is already on disk.
   - **Create new directory…** makes a new folder and runs `git init` in it.
   - **Clone a repository…** clones a repository from a URL into a new folder, then adds the clone.
3. Type the full path in the field, or click **Choose…** to pick a folder. A leading `~` works.
4. Click **Add Project**, or **Clone Project** when cloning.

The **Add Project** button stays off until the path is absolute. In **Create new directory…** mode it also stays off if the path is an existing file, and a folder that does not exist yet is created and initialised as a Git repository. **From existing path…** needs a folder that is already a Git repository.

New projects start in your home folder. To start them somewhere else, set **Settings ▸ General ▸ Default project folder**. It is where **Clone a repository…** clones to and **Create new directory…** creates in, and where **Choose…** opens.

### Clone a repository

Type the repository's URL: an `https://`, `ssh://` or `git://` URL, or `git@host:owner/repo.git`. **Clone into** fills itself with the repository's name inside your default project folder, and you can change it. **Choose…** picks the folder to clone inside: the repository gets its own folder in it. The destination must be a folder that does not exist yet, or an empty one. If an earlier clone there crashed or was force-quit, cloning again first removes the hidden folder it left. Workroom removes only what it can tell is left over, never a clone that may still be running. If a hidden folder it keeps is all that is in the way, the error names it, so you can delete it once no clone is running.

While the clone runs, the sheet shows git's progress. **Cancel** stops the clone and puts the folder back as it was. If the clone fails, git's error appears in the sheet, so you can fix the URL or folder and try again. Once the clone finishes, the project is selected and a terminal opens on it.

Git can't ask for a password, passphrase or host-key confirmation here. It signs in with what works without asking: SSH keys loaded in your SSH agent or Keychain, and git credential helpers such as the macOS Keychain or `gh auth`. A repository you can't reach that way fails with git's own message, such as `Permission denied (publickey).`

The clone is a full clone of the repository's default branch.

> [!NOTE]
> Workroom does not accept a path on another computer as a project, such as `ssh://…` or `host:repo`. To work on a remote repository, clone it with **Clone a repository…**. A remote workroom always belongs to a local project. See [Remote workrooms](../remote/overview.md).

## Project settings

A project's settings are in **Settings ▸ Projects**. The pane lists your projects; click one to open its settings, and the back button at the top of the window to return to the list. The gear on a project row, and **Project Settings…** in its right-click menu, open the project's settings straight away.

Changes apply straight away. A text field saves when you press <kbd>Return</kbd> or leave it.

The pane also holds the project's boxd and exe.dev options. See [Choose a host's image and size](../remote/overview.md#choose-a-hosts-image-and-size).

### Run command

**Run command** is the command Workroom starts for the project, for example `npm run dev`. It runs in a dedicated terminal at the workroom's directory, in your login shell. Start it from the Run button in a workroom's title bar or with <kbd>⌘R</kbd>. See [Run a command](terminals-and-tabs.md#run-a-command).

Turn on **Run automatically when a workroom is created** to start the command in every new workroom. The switch is off, and stays off, while the command is empty.

If you press <kbd>⌘R</kbd> in a project that has no run command, **Settings ▸ Projects** opens on it with a warning that you cannot run the workroom until you set one.

### Base branch

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

With either option that removes local workrooms, each workroom's teardown script runs before its directory goes, and a failing teardown stops the delete. **Remove from Workroom only** runs no local teardown scripts. Remote workrooms are deleted, with their teardowns, whichever option you choose. After a failure, **Delete Without Teardowns** skips the scripts for every remaining workroom. See [Delete a workroom](workrooms.md#delete-a-workroom).

Nightly only. A coding agent can't delete a project for you: run by one, `workroom delete-project` deletes nothing and tells it to ask you. See [What a coding agent leaves to you](../guides/drive-terminals-from-agents-and-scripts.md#what-a-coding-agent-leaves-to-you).

Deleting a project also closes its terminals. If a coding agent started with **Investigate** is still running there, the sheet warns you that deleting stops it. Workroom will not delete a project while a workroom in it is still being created.

> [!WARNING]
> Whichever option you choose, deleting a project also deletes its remote workrooms. For boxd, exe.dev and containers, this destroys their hosts and everything on them that is not pushed. For SSH, it removes each workroom's marked folder and sessions; the server stays. See [Delete a remote workroom](../remote/overview.md#delete-a-remote-workroom).
