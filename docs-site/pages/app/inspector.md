---
title: The inspector
description: Review a workroom's history, changes, files and pull request in the right-hand inspector, and commit, push and sync from the app.
---

The inspector is the panel on the right. It reads each workroom's Git repository directly, so you can review commits, diffs, files and the pull request without leaving the app, and commit and sync from the same place.

## Open the inspector

Press <kbd>⌘B</kbd> (**View ▸ Inspector**) to show or hide it. The icon strip at its right edge, the activity bar, switches between panes:

| Pane | Shows | Shortcut |
| --- | --- | --- |
| Details | Where the workroom runs, and its forwarded ports. See [Details and ports](details-and-ports.md) | <kbd>⌥⌘I</kbd> |
| Changes | Three sections: Changes, History and Pull Request | <kbd>⌥⌘C</kbd> |
| Files | The workroom's file tree | <kbd>⌥⌘F</kbd> |

**View** also has an item for each section of the Changes pane: **Changes**, **History** (<kbd>⌥⌘Y</kbd>) and **Pull Request** (<kbd>⌥⌘P</kbd>). Each opens the inspector at that section. The **Room** menu repeats these pane and section items, without the shortcuts. The sections stack in the Changes pane, and you can collapse them or drag the dividers to resize them.

The inspector follows the workroom you are in. Nightly only: in a terminal with no project it follows the terminal's folder instead. See [Terminals and the inspector](#terminals-and-the-inspector).

### Workroom header

The inspector shows the project and workroom name above its panes, led by the icon the sidebar shows for the workroom, or a house for a project's root. The **Workroom actions** menu beside the name has **Move to New Window**, the label items and **Delete Workroom…**. See [Workrooms](workrooms.md).

## Terminals and the inspector {nightly}

A standalone terminal or a terminal group has no workroom, but its inspector still works. It follows the folder the focused terminal is in. Run `cd` and the inspector moves with it. The Quick Terminal is the exception: it has no inspector.

The folder is the terminal's working directory, as the shell reports it. In a group the focused terminal sets it, so clicking another pane moves the inspector to that pane's folder. When the focused tab is a diff or a file, the inspector keeps the last terminal you used in that group. If you `ssh` to another machine, the inspector stays on the last local folder the terminal was in, because that machine's folders are not on your Mac.

The inspector is on for these terminals as it is for a workroom: <kbd>⌘B</kbd> shows it, and the activity bar is there, including in a window that has only terminals and no projects.

### The folder's repository

Where the folder is inside a Git repository, the inspector shows that repository, whichever folder of it you are in:

- The header shows the repository's folder name, with its branch and the folder's path, `~`-relative, beneath. It has no **Workroom actions** menu, because a followed folder is not a workroom.
- **Details** shows **Running on** and the folder's **Path**. It has none of a workroom's host options or ports.
- **History** lists the repository's commits, as for a workroom.
- **Changes** and **Pull Request** read the repository live, and work as they do for a workroom, so you can [commit](#commit), [push, pull and sync](#push-pull-and-sync), and use the pull request's buttons and menu. It reads the pull request with the GitHub CLI as before. The repository's status updates as files change, and as you `git switch` or commit in the terminal.
- A repository that is also one of your workrooms or projects shows that workroom's own status, and a write goes through it.

Changing folder within the same repository does not reload anything. Moving into another repository switches all of it at once.

### Not a repository

A folder in no Git repository says **Not a git repository** in **Changes**, **History** and **Pull Request**, with the folder beneath. If Git cannot tell which repository the folder is in, because the volume is slow or disconnected or the folder belongs to another user, the message is **Couldn't read the repository**, with a tooltip that says why. Workroom tries again shortly. **Files** still lists the folder either way.

### Files follows the folder

**Files** is rooted at the terminal's folder, not the repository's root. A breadcrumb above the list shows the path from the repository root (or from `~` outside a repository) to the folder. Click a segment to browse up to that folder. The inspector keeps showing the terminal's own repository while you browse. The next time the terminal changes folder, **Files** snaps back to it. A long path keeps its first segment, a **…** and its last two.

### It remembers each repository

Workroom remembers where you were in each repository you visit. Go away and come back, and **Files** has the same folders open and the lists are scrolled where you left them. Which pane is open, and which sections are collapsed, do not change when the inspector moves.

## Changes

**Changes** lists the files with uncommitted changes in the workroom, with a count in its header and the lines added in green and removed in red. It is live: it updates as you or a coding agent edit files. When nothing has changed it says **No uncommitted changes**.

- Click a file to open its diff in a preview tab. Click again quickly to keep the tab open.
- <kbd>⌘</kbd>-click a file to open the file itself in your editor.
- Hover a row for a button that opens the file in the app. Right-click for **Open File** and **Open File in…**.
- The refresh button in the header reads the status again.

### Read a diff

A diff opens as a tab beside your terminals. The view is **Unified** by default. Switch to **Side by Side** from the diff pane's title bar, or from **Settings ▸ Appearance ▸ Diff view**, which sets the layout for diffs you open afterwards. With **Side by Side** set in Settings, a pane that is too narrow falls back to unified. A diff you switch from its title bar keeps the layout you chose at any width.

Right-click a diff tab to switch the view, **Open File**, **Open File in…**, or **Keep Open**.

## History

**History** is the log of commits on the workroom's branch, newest first. Under each commit's message, its row shows the short commit id, its authors and how long ago it was made. Hover the time for the full date and time. Click a commit to open its changeset in a preview tab: the message, the authors, the changed files, and a diff for each file you select. Click quickly twice to keep the tab open. Branch and tag names show beside the commits they point at, and a commit that is not pushed yet has an orange up-arrow beside it. Hover it, or open the commit, to read **Not pushed**.

The list shows the newest commits first. Use **Load more** at the bottom to go further back.

## Commit

Click the check-mark button in the **Changes** header, or choose **Room ▸ Commit…** (<kbd>⌥⌘↩</kbd>), to open **Commit changes**. It is off when there is nothing to commit.

1. Untick any files you do not want in the commit. A file that appears while the sheet is open arrives ticked. To commit a single file, use **Commit Only This File** on its row.
2. Type a **Summary**. Add a **Description (optional)** if you want one.
3. Click **Commit N files**.

The sheet explains why the button is off, for example when there are unresolved conflicts or no summary. If a file has staged changes that differ from the file on disk, the sheet says so, and the button turns into **Commit anyway**. The commit records the file as it is on disk.

**Amend last commit** changes the message of the last commit to what you typed. It touches nothing else about that commit. The sheet names the commit it would rewrite.

## Push, pull and sync

The bar at the top of the Changes pane has three parts: the current branch, a sync button and a fetch button.

- The branch name is on the left. Right-click it for **Copy Branch Name**.
- The sync button shows the next sensible step for the branch. It reads **Publish branch** for a branch that is not on the remote yet, **Push** when you have commits to push, and **Pull with rebase** when the remote has commits you lack, with counts of how many. With nothing to do it shows when you last fetched. Click it to run that step.
- The fetch button, with the tooltip **Fetch from the remote**, contacts the remote and updates the counts.

The **Room** menu has the same actions.

| Action | Shortcut |
| --- | --- |
| **Fetch** | <kbd>⇧⌥⌘F</kbd> |
| **Push** | <kbd>⇧⌘P</kbd> |
| **Pull with Rebase** | <kbd>⇧⌥⌘P</kbd> |

If you have uncommitted changes when you pull, Workroom asks first. It stashes your changes and puts them back after the rebase.

When a push or pull fails, the sync button turns into a warning. Right-click it and choose **Show Error Details…** to read why. If a lock file is blocking the repository, the same menu has **Copy Lock File Path** and **Reveal Lock File in Finder**. Workroom does not delete the lock file for you, because it cannot tell a running Git from an abandoned lock.

## Pull request

**Pull Request** shows the pull request for the workroom's branch, and its CI checks. It reads them with the GitHub CLI, so it needs `gh` 2.57.0 or newer, signed in. If `gh` is missing, too old or signed out, the section says **GitHub CLI not found**, **GitHub CLI too old** or **GitHub CLI not signed in**, with the fix. Run `gh auth login` to sign in.

When the branch has a pull request:

- The header shows its number as a badge. Click the badge to open it in your browser. The badge turns red when checks are failing.
- A summary row and one row per check show the CI result. Click a check to open it on GitHub.
- A draft pull request has a **Ready for Review** button.
- The merge button merges the pull request into its base branch on GitHub, after you confirm. Its drop-down chooses the method: **Create a merge commit**, **Squash and merge** or **Rebase and merge**. Your choice is remembered.
- The header's **Pull request actions** menu has **Go to Pull Request**, **Ready for Review** or **Convert to Draft**, **Close Pull Request** and **Reopen Pull Request**. **Go to Pull Request**, and **Ready for Review** or **Convert to Draft**, are also in the **Room** menu.

With no pull request the section says **No pull request**. Workroom does not open pull requests itself. Create one with `gh pr create` in a terminal, or on GitHub. See [Review and ship](../guides/review-and-ship.md).

### CI freshness

Workroom reuses a CI result for up to five minutes when the repository and commit are unchanged. Selecting a workroom still reloads its pull request details and individual checks. A different commit gets its own CI result.

To check CI again right away, click the refresh button in the **Changes** header (**Refresh workroom status**).

## Files

**Files** shows the workroom's working tree as a list you can expand. A click on a file opens it read-only in the main pane, in a preview tab. Click again quickly to keep it open. <kbd>⌘</kbd>-click opens it in your editor. Markdown files open as a rendered preview, with a switch to the source. A `mermaid` code block is drawn as a diagram in the preview. A diagram Workroom cannot draw shows its source instead. A diagram is drawn in your theme's colours, so a theme change recolours it at once. Files are shown with syntax highlighting.

The refresh button in the header reloads the tree. A very large tree is cut off, with a line that says how many more there are.
