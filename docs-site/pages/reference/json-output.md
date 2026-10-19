---
title: JSON output
description: The --json contract of the workroom CLI, with its result envelope, streaming events, exit codes and error kinds.
---

Add `--json` to a `workroom` command to get output a program can read. The macOS app drives the CLI this way. You can too.

## What you get

With `--json`, a command prints exactly one JSON object on stdout, then exits with a [stable exit code](#exit-codes). Progress from setup and teardown scripts streams on stderr as one JSON object per line (NDJSON), so stdout stays a single object. Errors are an object too.

In `--json` mode a command never prompts. `workroom delete` needs `--confirm NAME`, and anything that would ask a question fails instead.

Commands that run in `--json` mode: `create`, `list` (with `--warnings none|fast|full`), `delete`, `version`. On Nightly, `base set`, `base clear`, `trust`, `trust status` and `untrust` run in `--json` mode too. The app also uses two hidden commands, `add-project` and `delete-project`.

## The result envelope

A successful command prints `ok: true`, the schema and CLI versions, the command name, and the command's own fields:

```json
{ "ok": true, "schema_version": 1, "cli_version": "v2.1.0",
  "command": "create", "name": "swift-meadow", "path": "/Users/you/workrooms/swift-meadow",
  "vcs": "git", "project": "/Users/you/dev/myapp" }
```

A failed command prints `ok: false` and an `error` object. `kind` is the stable machine code and `message` is for people, so branch on `kind`, never on `message`:

```json
{ "ok": false, "schema_version": 1, "cli_version": "v2.1.0",
  "command": "create", "error": { "kind": "WorkspaceExists", "message": "git worktree already exists: …" } }
```

`command` is left out when the failure happened before a command was known.

The schema is versioned with `schema_version`, currently `1`. Adding a field is not a change of version, so ignore keys you don't know. Only a breaking change bumps it.

### Fields by command

- `create` returns `name`, `path`, `vcs` and `project`. On Nightly it adds a `warning` string when the new workroom starts from out-of-date refs or from a fallback base.
- `delete` returns `name`.
- `list` returns `projects`, `workrooms_dir` and `config_path`. Each project has `path`, `vcs` and `workrooms`, and each workroom has `name`, `path`, `vcs_name` and `warnings`. A workroom or project on another host also has a `host` object. On Nightly, `list` adds `base_branch` at the top level for the global default, and to each project that sets its own. Without a setting the field is absent.
- On Nightly, `base set` and `base clear` return `{"project": …, "base_branch": …}`, or `{"global": true, "base_branch": …}` with `--global`.

The `warnings` on a workroom have a `kind` and a `message`. The kinds are `DirectoryMissing`, `VCSWorkroomMissing` and, for a remote workroom whose host its provider destroyed, `HostDestroyed`. A remote workroom never gets the first two.

### A create that fails after the workroom exists

Creating a workroom is not transactional. When the setup script fails, the workroom already exists, so the error envelope carries a `created` object with its `name`, `path`, `vcs` and `project`:

```json
{ "ok": false, "schema_version": 1, "cli_version": "v2.1.0", "command": "create",
  "created": { "name": "calm-river", "path": "/Users/you/workrooms/calm-river",
               "project": "/Users/you/dev/myapp", "vcs": "git" },
  "error": { "kind": "SetupScriptFailed", "message": "setup script failed: … returned a non-zero exit code" } }
```

## Streaming events on stderr

Each line on stderr is one JSON object with a `type`. Read it line by line while the command runs.

A `log` event is one line of a script's output. `phase` is `setup` or `teardown`:

```json
{ "type": "log", "phase": "setup", "text": "npm install…" }
```

`create --json` also prints a `created` event the moment the workroom exists, before the setup script runs. `setup` says whether there is a setup script to run:

```json
{ "type": "created", "name": "swift-meadow", "path": "/Users/you/workrooms/swift-meadow", "project": "/Users/you/dev/myapp", "vcs": "git", "setup": true }
```

### Step events {nightly}

On Nightly, `create --json` also reports its steps, in order: `fetch` (fetch the base branch), `worktree` (`git worktree add`) and `script` (the setup script). `state` is `running`, `done`, `warning`, `skipped` or `failed`. `detail` carries the warning text, the reason a step was skipped, or the failure message, and is left out when there is none:

```json
{ "type": "step", "id": "fetch", "state": "warning", "detail": "Could not fetch origin. …" }
```

Each `log` event then carries a `step`, the step that last started. It is left out before any step has started. The `fetch` and `worktree` logs hold each `$ git …` command line and its output. The `created` event gains a `warning` field, which is an empty string when there is no warning.

## Exit codes

Branch on the exit code when you don't need the details.

| Code | Meaning |
| ---- | ------- |
| `0` | Success. |
| `1` | Internal error, or a failed `git` command. Any error Workroom doesn't recognise lands here, including an invalid `--warnings` value. |
| `2` | Usage or validation, such as a `--confirm` value that doesn't match. |
| `3` | A precondition or not-found: unsupported VCS, already exists, invalid name, run from inside a workroom. |
| `4` | Cancelled, or nothing to do. |
| `5` | A setup or teardown script failed. |
| `6` | The config file could not be read, written or parsed. |

`workroom trust status` has its own answers: `0` when every script is approved or ignored by git, `1` when one is not, and `2` when it can't tell.

## Error kinds

| `kind` | Exit | Meaning |
| ------ | ---- | ------- |
| `InWorkroom` | 3 | The command ran from inside an existing workroom. |
| `UnsupportedVCS` | 3 | No Git repository was found. |
| `NotADirectory` | 3 | The path exists but is not a directory. |
| `InvalidName` | 3 | The workroom name failed validation. |
| `DirExists` | 3 | The target directory already exists. |
| `WorkspaceExists` | 3 | The Git worktree already exists. |
| `WorkspaceNotFound` | 3 | The Git worktree to delete doesn't exist. |
| `ConfirmationMismatch` | 2 | `--confirm` didn't match the workroom's name. |
| `UnsafeDeletePath` | 2 | Workroom refused to delete an unsafe or reserved path. |
| `Cancelled` | 4 | The user aborted, or there was nothing to do. |
| `SetupScriptFailed` | 5 | The setup script returned non-zero. |
| `TeardownScriptFailed` | 5 | The teardown script returned non-zero. |
| `ConfigReadFailed` | 6 | The config file could not be read or parsed. |
| `ConfigWriteFailed` | 6 | The config file could not be written. |
| `VCSCommandFailed` | 1 | An underlying `git` command failed. |
| `RemoteProjectUnsupported` | 3 | `add-project` was given a remote path such as `host:path` or `ssh://…`. |
| `RemoteWorkroomUnsupported` | 3 | `delete` or `delete-project` was asked to act on a remote workroom. |
| `InternalError` | 1 | Anything else. |

These kinds exist on Nightly only:

| `kind` | Exit | Meaning |
| ------ | ---- | ------- |
| `BaseBranchNotFound` | 3 | A base branch exists neither on its remote nor locally, or the fetch that checks the remote failed. |
| `ScriptNotTrusted` | 3 | A setup or teardown script this Mac has not approved. |
| `ProjectNotFound` | 3 | The project is not registered. |
| `WorkroomNotFound` | 3 | The workroom is not registered. |
| `WorkroomExists` | 3 | A workroom of that name is already registered. |
| `InvalidHostDescriptor` | 2 | A host descriptor must be a JSON object. |

### The ScriptNotTrusted envelope {nightly}

A `ScriptNotTrusted` error envelope has a `script` object, so a program can show the script and ask. `text` is the script to show, which is lossy for bytes that aren't UTF-8. `bytes` is its exact contents in base64, which is what to approve:

```json
{ "ok": false, "schema_version": 1, "cli_version": "v2.1.0", "command": "create",
  "error": { "kind": "ScriptNotTrusted", "message": "script is not trusted on this Mac: …" },
  "script": { "name": "workroom_setup", "origin": "root", "sha256": "0ce619c6…", "text": "#!/bin/sh\n…",
              "bytes": "IyEvYmluL3No…", "trusted": false, "exempt": false } }
```

See [workroom trust](../cli/workroom-trust.md) for how approval works.
