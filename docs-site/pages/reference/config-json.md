---
title: config.json
description: Where Workroom keeps its settings and project list, which keys you can edit by hand, and how the CLI and the app share the file.
---

Workroom keeps its projects, its workrooms and a few settings in one JSON file, shared by the CLI and the macOS app. Most of it is managed for you. This page covers the few keys that are yours to change.

## Where the file is

The file is `~/.config/workroom/config.json`. If it doesn't exist yet, Workroom treats it as empty and creates it the first time it saves something.

On Nightly, set `$WORKROOM_CONFIG` to a file path to use that file instead. See [environment variables](environment-variables.md#workroom_config). `workroom list --json` reports the path it used as `config_path`.

## Keys you can edit

| Key | What it does | Default |
| --- | ------------ | ------- |
| `workrooms_dir` | The folder new workrooms are created in. A leading `~` works. | `~/workrooms` |
| `base_branch` | The branch new workrooms start from, for projects that don't set their own. Nightly only. | origin's default branch |

Changing `workrooms_dir` affects new workrooms only. Each existing workroom keeps the path it was created at.

On Nightly, prefer a command to editing `base_branch`: `workroom base set --global BRANCH` sets it and `workroom base clear --global` removes it. See [workroom base](../cli/workroom-base.md). A project can have its own `base_branch` too, set with `workroom base set BRANCH` inside that project.

The file is plain JSON, so a typo makes it unreadable. Workroom then fails with `ConfigReadFailed` and exit code 6, and changes nothing. Keep a copy before you edit it by hand.

## Keys Workroom manages

Leave these alone.

- `channel` is the release channel the CLI's `workroom update` follows, `stable` or `pre`. Set it with `workroom update --channel`. See [updates and channels](../app/updates-and-channels.md).
- Every other top-level key is a project, named by its absolute path with symlinks resolved. A path reached through a symlink or with a trailing slash maps to the same entry.
- A project entry holds `vcs`, which is `git`, and `workrooms`. Each workroom has a `path`. A project can also have `base_branch`.
- On Nightly, a project or workroom on a remote host has a `host` object. The app owns what is inside it.
- On Nightly, `trusted_scripts` on a project holds the SHA-256 of each setup or teardown script you approved. Don't edit it. An entry there tells Workroom to run that exact script without asking. Use `workroom trust` and `workroom untrust` instead. See [workroom trust](../cli/workroom-trust.md).

Workroom keeps keys it doesn't recognise when it rewrites the file.

## Sharing between the CLI and the app

Both read and write the same file, and every save replaces the whole file at once, so a program reading it never sees half a file.

When Workroom changes the file, it first takes an advisory lock on a file next to it, `config.json.lock`. This stops the CLI and the app from overwriting each other. The operating system releases the lock if the holder crashes. If the lock can't be taken within 30 seconds, Workroom goes ahead without it rather than fail. The lock file can stay on disk and is harmless, so you don't need to delete it.

Your own editor takes no lock. If you edit the file while a create or delete is running, one of the writes can win. Edit it when nothing is running.
