---
title: Port forwarding
description: Reach a dev server running in a container workroom from your Mac's browser, and publish a port on boxd or exe.dev.
nightly: true
---

A dev server running in a remote workroom listens on its host, where your Mac's browser can't reach it. For a Docker or Apple container workroom, Workroom forwards ports to `localhost` on your Mac and lists them in the **Ports** list. For boxd and exe.dev, you publish the port with the provider.

## Ports in container workrooms

Workroom forwards a container workroom's ports to your Mac, and shows each one in the **Ports** list in the inspector's **Details** pane. Open the pane with <kbd>⌥⌘I</kbd>. Each row reads like `localhost:5173 → container 5173`, with a copy button and a button to stop forwarding.

A forward answers on `localhost`, on both `127.0.0.1` and `::1`. Only your Mac can reach it.

### Declare ports in devcontainer.json

Declare the ports in your repository's dev container file, `.devcontainer/devcontainer.json` or `.devcontainer.json`. It is the same file that VS Code, Codespaces and DevPod read, so a repository that has one needs nothing new.

```json
{
  "forwardPorts": [5173, 3000],
  "portsAttributes": {
    "5173": { "label": "Web" },
    "3000": { "label": "API", "requireLocalPort": true }
  }
}
```

Comments and trailing commas are allowed in the file.

- **`forwardPorts`**: each number is forwarded.
- **`portsAttributes`**: for a single port, `label` is the name shown on its row, and `requireLocalPort` refuses the forward instead of moving it to another port when your Mac already uses that number.

Only these fields are read. A `"host:port"` entry, port ranges and patterns, `appPort`, and the container definition itself (`image`, `build`, `features`) are ignored, because a container workroom runs Workroom's own image.

The forwards are made when you open the workroom, from the workroom's own copy of the file. At most 32 ports are forwarded from one file. When the file declares more, the Ports list says that only the first 32 are forwarded.

### Which port number you get

Each port keeps its own number on your Mac when that number is free, so port 5173 is `http://localhost:5173`. When something on your Mac already uses the number, the port gets a free number instead, and the Ports list shows which one.

With `"requireLocalPort": true`, the port is not forwarded at all in that case, and the list says why.

A forward holds its port on your Mac until you stop forwarding it or quit Workroom, even after you switch to another workroom. A server you start on your Mac later on the same port, such as the project's own dev server or Postgres, then can't take it, or is hidden behind the forward. Stop the forward in the Ports list first.

### Add a port by hand

To forward a port the file doesn't list:

1. In the **Ports** list, click the **+** button.
2. Type the port number in **New port number…**, and press <kbd>↩</kbd>.

A number outside 1 to 65535 is refused with `Enter a port between 1 and 65535.` Press <kbd>⎋</kbd> to cancel.

### Stop forwarding

Click the **x** button on a row, which is titled **Stop forwarding port** and the port's number. A port you stop stays stopped until you relaunch Workroom.

### After a relaunch

Forwards are not saved. When you open the workroom after relaunching Workroom, the ports in `devcontainer.json` are forwarded again, and each one gets the same port number back when it is free. A port you added by hand is not remembered, so add it again.

If the connection to the container drops, the Ports list says `Not connected. A forward reconnects when it is used.` or `No daemon is connected.` See [Reconnecting](reconnecting.md).

## boxd and exe.dev

A boxd or exe.dev workroom has no Ports list, and Workroom does not forward its ports. Publish a port with the provider instead:

- On boxd, run `boxd machine proxy add`. The port is public on the internet.
- On exe.dev, a server on a port from 3000 to 9999 is already at `https://<vm>.exe.xyz:<port>/`, for anyone with access to the VM. Run `ssh exe.dev share port <vm> <port>` to serve that port at `https://<vm>.exe.xyz/` instead. It stays private until you run `ssh exe.dev share set-public <vm>`.

A workroom on your Mac needs neither. Its servers already listen on your Mac.

See [boxd](boxd.md) and [exe.dev](exe-dev.md).
