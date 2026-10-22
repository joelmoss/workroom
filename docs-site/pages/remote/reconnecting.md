---
title: Reconnecting
description: What happens to a remote workroom's terminals when your Mac sleeps, your network changes or the host restarts.
nightly: true
---

A remote workroom's terminals run on its host, so they keep running when your Mac loses its connection. When the connection comes back, Workroom attaches each pane to its session again, with no action from you. This page covers when that happens and what you see.

## What survives

- Your terminal sessions, and the programs in them, run on the host. A dev server or a coding agent keeps going while your Mac sleeps, while you are offline and after you quit Workroom.
- When a pane reattaches, it shows the session as it is now. You do not start a new terminal.

## When your Mac wakes or changes network

When your Mac wakes from sleep, or moves to another network (Wi-Fi to a hotspot, a VPN turning on or off, a network coming back after dropping), Workroom checks each boxd and exe.dev host. It waits up to 2 seconds for the host's Workroom daemon to answer.

- A host that answers keeps its connections. Its panes do not blink.
- A host that does not answer has its connection dropped, and its panes attach again at once. Without this check, a pane would wait up to a minute for ssh to notice that its connection died.

A pane that was waiting out a delay before its next try also attaches at once.

Docker and Apple containers are not checked. A container is on your Mac, so no network change breaks its connection.

## When a host is unreachable

If a pane's connection drops, for example because the host is offline or restarting, the pane keeps trying. It tries again after 1 second, then 2, 4, and so on, up to every 30 seconds. It keeps trying for as long as it takes, because a rebooting cloud host can be gone for minutes. It stops only when you close the pane or the tab.

While it tries, the pane shows:

```text
Can't reach this terminal's host right now. Workroom will keep trying, and your session will be restored when it connects.
```

While a pane connects, it shows `workroom: waiting for this terminal's host...` until the connection is in.

When it connects, the pane comes back to its last screen, and your session carries on.

### When the host refuses

Some failures are not worth retrying, such as a host key that changed or an ssh key the host refuses. After five of these within 30 seconds of an attach, the pane stops and leaves ssh's own message on screen. Fix what it says, then close the pane and open a new one.

## Ctrl-C while it reconnects

Pressing <kbd>⌃C</kbd> in a pane that is reconnecting does not stop the reconnect. Workroom treats it as meant for the program you were typing to. The pane keeps trying, as its message says.

This applies to the reconnect that Workroom started by itself, for a session that already exists on the host. A new pane's first attach, and one you started yourself, stops on <kbd>⌃C</kbd> as `ssh` normally does.

## When the host restarts

If the host restarts, the programs running in your terminals end with it. The daemon on the host starts again by itself, and Workroom reattaches your panes once the host is back.

A terminal whose program ended with the host shows its last screen with a bottom row that reads `This terminal ended when its host restarted. Close it to start again.` If no screen was kept, it prints `workroom: This terminal has ended. Close it to start again.` Close that tab and open a new one. Workroom does not replace it with a new shell for you on a remote workroom, so you can read what was on screen when it ended.

A container that isn't running, and an asleep boxd machine, start again when you open their workroom.

## Other things you might see

- A tab's status, such as a coding agent waiting for you, shows `May be out of date: reconnecting…` while its host's connection is down. It updates once the host answers.
- In the **Ports** list of a container workroom, `Not connected. A forward reconnects when it is used.` or `No daemon is connected.` shows while the connection is down. See [Port forwarding](port-forwarding.md).

See [Troubleshooting](../help/troubleshooting.md) if a pane does not come back.
