---
title: Prepare a project
description: Make every new workroom ready to work in, with its dependencies installed, its local files copied and its dev server one key away.
---

A new workroom is a clean checkout of your project. This guide sets your project up so that each one
installs its own dependencies, gets the gitignored files it needs, and can start your dev server with
one key. You do it once per project, and every workroom after benefits.

Everything here lives in your repository, so commit it and your whole team gets the same setup.

## Run a setup script

A setup script runs inside every new workroom, right after it is made. It is the place to install
dependencies, create a database for the workroom, or anything else a fresh checkout needs.

1. Create `scripts/workroom_setup` in your project.
2. Make it executable: `chmod +x scripts/workroom_setup`.

```sh
#!/usr/bin/env bash
set -euo pipefail

# Install dependencies for this workroom.
npm install

# Give the workroom its own database, named after it, so it can't clobber another's.
createdb "myapp_${WORKROOM_NAME}"
```

The script runs with the new workroom as its working directory. Workroom runs the workroom's own copy
of the script, so a workroom made from a newer commit runs that commit's version. If the workroom has
no copy, because the script is gitignored say, Workroom runs the root's copy.

The script gets your login shell's environment, so tools you set up in your dotfiles, such as version
managers, are there. It also gets these variables:

| Variable             | Value                                                               |
| -------------------- | ------------------------------------------------------------------- |
| `WORKROOM_NAME`      | The workroom's name, such as `swift-meadow`.                        |
| `WORKROOM_PATH`      | The workroom's folder.                                              |
| `WORKROOM_ROOT_PATH` | Your root checkout's folder. Not set on a remote host.              |
| `WORKROOM_HOST`      | Where the script runs, such as `local` or `boxd`. Nightly only.     |

See [Environment variables](../reference/environment-variables.md) for the full list.

> [!NOTE]
> A failed setup script doesn't undo the workroom. It stays, so you can see what went wrong, and the app
> offers to open it anyway or delete it.

## Undo it with a teardown script

A teardown script runs inside a workroom just before it is deleted. Use it to undo anything the setup
script made outside the workroom's folder. Workroom removes the folder itself.

1. Create `scripts/workroom_teardown` in your project.
2. Make it executable: `chmod +x scripts/workroom_teardown`.

```sh
#!/usr/bin/env bash
set -euo pipefail

# Drop the database the setup script made.
dropdb "myapp_${WORKROOM_NAME}" 2>/dev/null || true
```

Workroom looks for it as it looks for the setup script: the workroom's own copy first, then the root's.

### When a teardown fails {nightly}

If the teardown script fails, the delete stops and nothing is removed, so you can fix the script and try
again. The app shows the script's output and offers **Delete Anyway**, which deletes the workroom without
running it. From the CLI, run `workroom delete <name> --skip-teardown`.

## Approve your scripts {nightly}

Setup and teardown scripts are code from the repository, so Workroom runs one only after you have
approved its exact contents on this Mac. The first create or delete that would run a new script, or one
that changed since you approved it, stops first and shows it to you:

- In the app, a sheet says why it stopped and shows the script with line numbers and colours. The
  button at its top right opens it in a window of its own. Creating a workroom offers **Approve**,
  **Continue Without Script…** (creates the workroom without running it, after asking) and
  **Cancel Creation**. Deleting one offers **Approve**, **Delete Anyway** and **Cancel**. Return
  never approves; click it.
- In a terminal, `workroom create` and `workroom delete` print the script and ask.
  `workroom create --skip-setup` creates without running the setup script.

Skipping a script approves nothing, so the next create asks again. When you include your
uncommitted changes in a new workroom and you've edited the setup script, it's your edited copy that
needs approving, since that's the one that runs.

A container workroom's `devcontainer.json` is approved the same way, in the app, before a create uses
it. See [Approve it first](../remote/containers.md#approve-it-first).

An approval covers the script's own contents only, not what it runs in turn, such as `npm install` and
the `package.json` it reads. A script that git ignores in your root never needs approving, because a
`git pull` can't change it.

To approve your scripts ahead of time, or check them, run these from the project:

```sh
workroom trust          # show each script a create or delete would run next, and approve it
workroom trust status   # exit 0 if every script is approved, 1 if one isn't
workroom untrust        # forget this project's approvals
```

See [`workroom trust`](../cli/workroom-trust.md).

## Copy gitignored files into new workrooms {nightly}

A clean checkout is missing the gitignored files your project needs to run, such as `.env` or
`config/master.key`. List them in a `.worktreeinclude` file at your project's root, in `.gitignore`
syntax, and Workroom copies them from the root into every new workroom before the setup script runs:

```gitignore
.env
.env.local
config/master.key
certs/
```

- Only files that match a pattern and are gitignored in the root are copied. Tracked files never are.
- A file the workroom already has is left alone. Symlinks are never copied; the **Copy local files** step
  names each one it skipped.
- If a file can't be copied, the workroom is still made, and the step ends with a warning naming it.

Orca, Claude Code and the Codex app read the same file, so you can commit it once for every tool your
team uses.

## Set a run command

A run command is what you run most in a workroom, such as `npm run dev` or `bin/rails server`. Once it is
set, <kbd>⌘R</kbd> starts it in any of the project's workrooms, in a tab of its own.

1. Right-click the project in the sidebar and choose **Project Settings…**.
2. Under **Run Command**, enter the command.
3. To start it in every new workroom by itself, turn on **Run automatically when a workroom is
   created**.
4. Click **Save**.

| Action  | Keys                                    |
| ------- | --------------------------------------- |
| Run     | <kbd>⌘R</kbd>                           |
| Restart | <kbd>⌥⌘R</kbd>                          |
| Stop    | <kbd>⇧⌘R</kbd>                          |

## Choose the branch new workrooms start from {nightly}

New workrooms start from the default branch on `origin`, freshly fetched. To start them from another
branch, such as `develop`, set the project's base branch in **Project Settings…**, under **New
Workrooms**. To set a default for every project, use **Settings**, under **New Workrooms**.

From the CLI:

```sh
workroom base set develop                 # this project
workroom base set upstream/main --global  # every project that sets none
workroom base clear                       # back to origin's default branch
```

A plain name such as `develop` is a branch on `origin`. Write `upstream/main` to use another remote,
for example to start from the real project's `main` when you work from a fork. See
[`workroom base`](../cli/workroom-base.md).

When you have commits on that branch you haven't pushed, or changes you haven't committed, Workroom
asks whether the new workroom should include them. See
[Include work you haven't pushed](../app/workrooms.md#include-work-you-havent-pushed).
