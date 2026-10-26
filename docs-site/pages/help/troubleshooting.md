---
title: Troubleshooting
description: Fixes for the problems people hit most, each listed under the symptom you see.
---

Find the symptom you see, then follow the fix under it.

## The command says "no supported VCS detected in this directory"

`workroom create` and `workroom delete` must run from the root of a Git repository, a folder that contains `.git`. Change into the project, or point at it with `--project DIR`.

## The command says "looks like you are already in a workroom"

You are inside a workroom folder, which has a `.Workroom` marker. Run the command from your project's root instead.

## The workroom was created but its setup failed

Creating a workroom is not all or nothing, so the workroom exists even though the setup script failed. The CLI exits with code 5.

1. Fix `scripts/workroom_setup`.
2. Delete the workroom with `workroom delete NAME`.
3. Create it again.

On Nightly the app shows the failure with **Open Anyway** and **Delete Workroom…**. On a remote workroom the host keeps running until you choose.

## The script is not trusted on this Mac {nightly}

The message is "script is not trusted on this Mac". The setup or teardown script is new, or it changed since you approved it. Read it, then approve it:

1. Answer yes when `workroom create` or `workroom delete` asks in a terminal.
2. Or run `workroom trust` in the project.

In the app, a sheet shows the script. Creating a workroom offers **Approve**, **Continue Without Script…** and **Cancel Creation**; **Review Script…** in the creation pane opens it again. A delete's sheet offers **Approve**, **Delete Anyway** and **Cancel**. To create without the setup script from a terminal, run `workroom create --skip-setup`.

A `--json` or scripted call can't ask, so it exits with code 3. `workroom trust status` exits 2 when it can't tell, for example when the base branch can't be resolved. Fix that first. See [workroom trust](../cli/workroom-trust.md).

## A delete stopped and nothing was removed {nightly}

When the teardown script fails, can't start, runs out of time, or isn't approved, the delete stops and removes nothing. For a remote workroom it also stops when the host can't be reached. The app shows why, with the script's output.

1. Fix the script, then delete again.
2. Or choose **Delete Anyway** in the app, which deletes without running the script.

The CLI's version of **Delete Anyway** is `workroom delete NAME --skip-teardown`. On a project delete the button is **Delete Without Teardowns**, which skips the teardown of every remaining workroom.

## The Git branch is still there after I deleted a workroom

This is on purpose. Workroom never deletes the `workroom/NAME` branch. Remove it yourself with `git branch -D workroom/NAME`.

## The list shows "directory not found" or "git workroom not found"

The workroom's folder, or its Git worktree, was removed outside Workroom. Run `workroom delete NAME` to clean up the entry. Version 2.1.0 words the second as "git workspace not found".

## A project shows a warning triangle in the sidebar

The tooltip says "Project folder not found". Workroom tracks a project by its path, so the folder was moved or deleted. Put it back at the same path, or choose **Delete Project…** from the project's menu and pick **Remove from Workroom only — keep all files**.

## `workroom update` says it can't update

You are on a `dev` build, one built without version information. Install from a release first. See [Install](../get-started/install.md). A `workroom` bundled inside the macOS app is managed by the app: use **Check for Updates…** in the app instead.

## My setup script can't find a tool, or is slow to start

The app reads your login shell's environment to give it to your scripts, so a slow `.zshrc` slows Workroom down. It sets `WORKROOM_SHELL_PROBE=1` while it does. Skip the slow part when it is set:

```sh
[ -n "$WORKROOM_SHELL_PROBE" ] || eval "$(something-slow init)"
```

The app waits 3 seconds. If your shell takes longer, or ends in `exec tmux`, or waits for input, or is `fish` or `nushell`, the app falls back to the system path files. Your script then gets the basics but not what only your dotfiles add. See [Environment variables](../reference/environment-variables.md#workroom_shell_probe).

## Terminals have no shell integration under bash

If your login shell is `/bin/bash`, Apple's bash 3.2, terminals get no shell integration. The inline agent, the tab title reset when a command ends, and working-directory tracking don't work. Homebrew bash 4.4 or newer gets all of them:

```sh
brew install bash
echo "$(brew --prefix)/bin/bash" | sudo tee -a /etc/shells
chsh -s "$(brew --prefix)/bin/bash"
```

Log out and back in so apps you open from the Dock see the new shell, then open a new terminal in Workroom. `echo $BASH_VERSION` should print `5.x`.

## The pull request and CI views are empty

The app gets them from the GitHub CLI. You need [`gh`](https://cli.github.com) 2.57.0 or newer on your `PATH`, signed in. Check with:

```sh
gh --version
gh auth status --active
```

## macOS asks if Workroom can access data from other apps

The prompt reads "Workroom would like to access data from other apps". A program in a terminal, such as a coding agent, read a folder like `~/Library/Application Support`. macOS counts that as Workroom reading it, because the terminal's programs run under Workroom. No setting stops the prompt, so grant Workroom Full Disk Access:

1. Open System Settings, then Privacy & Security, then Full Disk Access.
2. Turn on Workroom.
3. Quit and reopen Workroom.

## A coding agent's voice mode never asks for the microphone {nightly}

Voice input from a program in a Workroom terminal, such as Claude Code's voice mode, needs the microphone. Without the right permission macOS refuses before it asks, so voice fails with no prompt and no error. Current builds of Workroom allow it.

1. Update Workroom.
2. Close every terminal, quit Workroom, wait about 30 seconds, and open it again. Terminals, new ones included, keep running under a helper the previous version started until it exits.
3. If voice still never prompts, open System Settings, then Privacy & Security, then Microphone, and check that Workroom is listed and on.

## A remote workroom's host can't be reached {nightly}

Opening a workroom starts its container again if your Mac stopped it. If Workroom still can't connect, the host may have been removed by its provider. `workroom list` marks such a workroom with the `HostDestroyed` warning.

After your Mac wakes or its network changes, the app checks each boxd, exe.dev and SSH host and reattaches the panes of any that stopped answering. You don't need to do anything.

A delete that can't reach the host stops and removes nothing. Choose **Delete Anyway** to remove the workroom without its teardown script. For an unreachable SSH host, this forgets the entry and names the folder left on the server. See [Reconnecting](../remote/reconnecting.md) and [Delete an SSH workroom](../remote/ssh.md#delete-a-workroom).

## The CLI and the app seem out of sync

Both use `~/.config/workroom/config.json` and take a lock on it while they write. A leftover `config.json.lock` file is harmless, and Workroom works around a lock it can't take after 30 seconds. See [config.json](../reference/config-json.md).
