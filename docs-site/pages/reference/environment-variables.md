---
title: Environment variables
description: The environment variables Workroom sets for your setup and teardown scripts, and the ones you can set to change how Workroom and its installer behave.
---

This page lists every environment variable Workroom sets for scripts, and every one you can set yourself.

## Variables your scripts receive

Workroom sets these for both the setup script and the teardown script. The script's working directory is the workroom directory. Workroom sets them for you, so don't set them yourself.

| Variable | Value |
| -------- | ----- |
| `WORKROOM_NAME` | The name of the workroom being created or deleted. |
| `WORKROOM_PATH` | The absolute path of the workroom directory. |
| `WORKROOM_ROOT_PATH` | The absolute path of the root, the project the workroom belongs to. Scripts run inside the workroom, so use this to reach files in the root. |
| `WORKROOM_PARENT_DIR` | A deprecated alias for `WORKROOM_ROOT_PATH`, still set so existing scripts keep working. Use `WORKROOM_ROOT_PATH` in new scripts. |
| `WORKROOM_HOST` | Where the script runs: `local` on your Mac, or the kind of host for a remote workroom: `boxd`, `exedev`, `docker`, `apple` or `ssh`. Nightly only. |

Scripts also receive the rest of the environment your login shell sets up in the workroom, such as anything you export in your dotfiles and the tool versions the workroom pins. See [Prepare a project](../guides/prepare-a-project.md) for writing the scripts.

### On a remote host

A script for a remote workroom runs on its host, and the environment differs from a local one:

- `WORKROOM_ROOT_PATH` and `WORKROOM_PARENT_DIR` are not set, because there is no root on the host. Guard any use of them:

  ```sh
  if [ -n "${WORKROOM_ROOT_PATH:-}" ]; then
    cp "$WORKROOM_ROOT_PATH/.env" .env
  fi
  ```

  Under `set -u`, an unguarded `$WORKROOM_ROOT_PATH` fails the script, and so fails the create.
- The rest of the environment is what the host user's login shell sets up in the workroom, never your Mac's. Your Mac's environment, secrets included, stays on your Mac.

In Nightly, the app's Git commands on every kind of remote host also use that host user's login
environment. The daemon reads it once and keeps it until it restarts. A login profile that fails or
takes longer than 10 seconds falls back to the daemon's own environment, and the daemon logs why.

See [Work on a remote host](../guides/work-on-a-remote-host.md).

## Variables you can set

### `WORKROOM_SHELL_PROBE`

Workroom sets this to `1` while it reads your login shell's environment, so your shell startup file can skip slow work. The macOS app reads your environment each time it creates or deletes a workroom. Workroom reads it again in the workroom just before a setup or teardown script runs, on your Mac and on a remote host. The remote daemon also reads the login environment once for the app's Git commands. It is not passed on to your script.

In your `.zshrc`:

```sh
[ -n "$WORKROOM_SHELL_PROBE" ] || eval "$(something-slow init)"
```

Don't skip your version manager this way: your script needs it to pick the workroom's tool versions.

The read just before a script waits 10 seconds for the shell. If the shell doesn't finish or fails, the script still runs, with the environment Workroom already had, and its output says why. A `.zshrc` that ends with `exec tmux`, or waits for input, makes the shell fail. See [Troubleshooting](../help/troubleshooting.md#my-setup-script-cant-find-a-tool-or-is-slow-to-start).

### `WORKROOM_CONFIG`

The path of the config file to use in place of `~/.config/workroom/config.json`. Nightly only. Workroom doesn't need it for normal use. A Dev build of the app sets it so it keeps its own config. See [config.json](config-json.md).

### `EDITOR`

When `workroom create` finishes in a terminal and `EDITOR` is set, it offers to open the new workroom in that editor. `--no-editor` and `--json` turn the offer off.

## Variables for the installer

`install.sh` reads these. The Windows installer `install.ps1` reads `VERSION` and `WORKROOM_CHANNEL` too.

| Variable | Effect |
| -------- | ------ |
| `WORKROOM_INSTALL_PATH` | The folder to install the CLI into. The default is `~/.local/bin`. `install.sh` only. |
| `VERSION` | Install this release, such as `v2.1.0`, in place of the latest. It overrides `WORKROOM_CHANNEL`. |
| `WORKROOM_CHANNEL` | `stable` (the default), `pre` or `nightly`. `nightly` installs a separate `workroom-nightly` binary. |

```sh
curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | WORKROOM_CHANNEL=nightly sh
```

See [Install](../get-started/install.md) and [Updates and channels](../app/updates-and-channels.md).
