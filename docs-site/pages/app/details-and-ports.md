---
title: Details and ports
description: See where a workroom runs, copy its path, and forward ports from a container workroom to your Mac.
nightly: true
---

The Details pane tells you where the selected workroom runs. For a workroom in a Docker or Apple container, it also lists the ports forwarded to your Mac and lets you add more.

## Open the Details pane

Press <kbd>⌥⌘I</kbd> (**View ▸ Details**), or click **Details** at the top of the activity bar in the inspector. See [The inspector](inspector.md). With no workroom selected, the pane says **Select a workroom to see where it runs.**

## What it shows

- **Running on** shows **This Mac**, or the kind of host a remote workroom runs on. On boxd or exe.dev, click the provider's name to open the machine's page on its dashboard in your browser.
- **Machine Name** appears for a remote workroom that has one. Click its copy button to copy it.
- **Path** is the workroom's folder. For a workroom on a host it reads **Path on its host**, and names the folder on that host. Click the copy button beside it to copy the path.

- **Made From** appears for a container workroom: the `devcontainer.json` it was made from, or the image when it had none. A note under it says when the repository's file has changed since, or has been added or removed, since a change applies only to workrooms created after it. See [Your dev container](../remote/containers.md#when-the-file-changes).

A remote workroom may also show a short note under these.

Copy buttons briefly show **Copied!** just above the button after copying to the clipboard. The same
confirmation appears when you copy a port address, an error report, or a path or branch name from a menu.

## Ports

The **Ports** list appears only for a workroom in a Docker or Apple container. A dev server there listens inside the container, where your Mac's browser cannot reach it. Workroom forwards its ports to your Mac, and each row shows one:

```text
localhost:5173 → container 5173
```

Open the address before the arrow on your Mac to reach the server. If something on your Mac already holds the port, the row shows a different number, such as `localhost:51234 → container 5173`. A port you labelled in `devcontainer.json` shows its label beside the row.

Workroom forwards the ports your project's `devcontainer.json` declares when you open the workroom. See [Port forwarding](../remote/port-forwarding.md) for the file and its fields.

Workrooms on boxd and exe.dev have no Ports list, because those providers publish a host's ports themselves. A workroom on your Mac needs none.

### Forward another port

1. Click the **+** at the right of the **Ports** heading. Its tooltip reads **Forward a port from this workroom's container**.
2. Type the container's port number in **New port number…**.
3. Press <kbd>Return</kbd>.

If the port cannot be forwarded, the row stays and says why. Press <kbd>Esc</kbd>, or leave the field empty, to cancel.

### Copy or stop a forward

Each row has two buttons:

- The copy button copies `localhost:` and the port, for example `localhost:5173`.
- The **x** button, **Stop forwarding port N**, stops the forward.

A port you stop stays stopped until you relaunch Workroom. A forward holds its port on your Mac until you stop it or quit, even after you switch to another workroom. If something on your Mac needs that port, stop the forward first.

Forwards do not carry over a relaunch. The ports your `devcontainer.json` declares are forwarded again, and the ports you added by hand are not.

### When it is not connected

If the list says **No daemon is connected.**, Workroom has no connection to the container's Workroom daemon yet, and the controls will not work. **Not connected. A forward reconnects when it is used.** means a forward you already made will reconnect the next time something uses it.
