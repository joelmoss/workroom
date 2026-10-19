---
title: Updates and release channels
description: How the Workroom app updates itself, how to follow stable or pre-release builds, and how Nightly works alongside it.
---

The Workroom app updates itself. This page explains how updates reach you, how to choose between stable and pre-release builds, and how the separate Nightly app and the `workroom` command-line tool are updated.

## How the app updates

Workroom checks for updates in the background and tells you when one is ready. The app is signed and notarized by Apple, and it is updated with Sparkle.

- **Workroom ▸ Check for Updates…** checks right now. It is also in **Settings ▸ About** as **Check for Updates…**.
- **Settings ▸ About ▸ Automatically check for updates** turns the background checks on or off.
- When an update is waiting, an **Update** button appears in the title bar. Click it to install the update. While it downloads, the button reads **Updating…**.

**Settings ▸ About** also has **View release notes**, which opens the releases page on GitHub. See also [Release notes](../help/release-notes.md).

### Updating keeps your terminals {nightly}

Next to the **Update** button, a short note scrolls past: Safe to update, workroom terminals keep running. Run commands and the Quick Terminal stop. Terminals in your workrooms keep their sessions across the update. A run command stops when you quit, and the Quick Terminal has no session to keep.

## Release channels

The Workroom app follows one of two channels. Choose it in **Settings ▸ About ▸ Release channel**:

- **Stable** is the default. You get finished releases only.
- **Pre-release** adds betas and release candidates. You get whichever is newer, a pre-release or a stable release.

The choice applies to the next update check. Workroom does not run a check when you change it. The Nightly app does not show the setting, because its channel is fixed.

## Nightly

Nightly is not a channel you switch to. It is a separate app, **Workroom Nightly**, built every day from the latest work on the main branch. It has its own name and its own violet icon, and it runs alongside your regular Workroom. A Nightly build can have features that are not in a stable release yet. The docs mark them with a Nightly badge.

To get it, download `workroom-macos-app_nightly.dmg` from the [releases page](https://github.com/joelmoss/workroom/releases) on GitHub, on the release named `nightly`. Workroom Nightly updates itself from its own feed, so it only ever moves to a newer Nightly build.

Nightly builds are numbered like `2.2.0-nightly.1234`, where the last number counts commits, so a later build always has a higher number.

### The Nightly command-line tool

Nightly also has its own command-line tool, `workroom-nightly`. It installs next to `workroom` and does not replace it. It updates itself within Nightly.

```sh
curl -fsSL https://raw.githubusercontent.com/joelmoss/workroom/master/install.sh | WORKROOM_CHANNEL=nightly sh
```

## Update the command-line tool

The `workroom` command-line tool has its own `workroom update`:

```sh
workroom update                # install the latest build on your channel
workroom update --check        # only report whether an update is available
workroom update --channel pre  # switch to the pre channel and install its latest build
```

`--channel` accepts `stable` or `pre` and remembers your choice for later runs. Switching to a lower channel installs that channel's current build, even when that is an older version. It tells you when it does. Downloads are checked against the release's `checksums.txt` before the old binary is replaced. See [`workroom update`](../cli/workroom-update.md).

`workroom update --channel nightly` is refused. Install `workroom-nightly` as above instead.

A `workroom` that is bundled inside the macOS app is managed by the app. Use **Check for Updates…** there. A build made from source cannot update itself. To put the command on your `PATH` from the app, choose **Workroom ▸ Install ‘workroom’ Command in PATH…**.
