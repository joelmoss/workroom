#!/usr/bin/env python3
"""A synthetic agent TUI, shaped like the thing the design doc worries about (Claude Code): it takes over the
screen (alt screen), rewrites its own process name to a version string, blocks on the terminal at its prompt,
and does its work over the network. A stand-in, NOT the real agent (a recorded gap: plan, "Known gaps").

  agent.py --peer HOST:PORT [--keepalive]

At the prompt it does nothing but block on a tty read: no timer, no redraw. Typed commands:
  go a <wait> <stream>   a turn WITH a spinner (10 Hz redraws) while it waits on the peer
  go b <wait> <stream>   a turn with NO output at all while it waits (blocked in recv): the hardest case
After the wait it prints the peer's streamed tokens, then returns to the prompt.
"""

import argparse
import ctypes
import curses
import select
import socket

ap = argparse.ArgumentParser()
ap.add_argument("--peer", default=None, help="HOST:PORT; needed only for --keepalive and turns")
ap.add_argument("--keepalive", action="store_true")
args = ap.parse_args()
host, port = args.peer.rsplit(":", 1) if args.peer else (None, None)

ctypes.CDLL(None).prctl(15, b"2.1.232", 0, 0, 0)  # PR_SET_NAME: rewrites comm, as Claude Code does


def turn(scr, mode, wait, stream):
    s = socket.create_connection((host, int(port)))
    s.sendall(("SLOW %s %s\n" % (wait, stream)).encode())
    spin, i = "|/-\\", 0
    if mode == "a":
        while not select.select([s], [], [], 0.1)[0]:  # spinner at 10 Hz while waiting
            scr.addstr(2, 0, "thinking " + spin[i % 4])
            scr.refresh()
            i += 1
    else:
        select.select([s], [], [])  # blocked in the kernel: no CPU, no pty output, nothing
    row = 4
    while True:
        data = s.recv(4096)
        if not data:
            break
        scr.addstr(row % 20, 0, data.decode(errors="replace").split("\n")[0][:60])
        scr.refresh()
        row += 1
    s.close()
    scr.addstr(3, 0, "done            ")
    scr.refresh()


def ui(scr):
    scr.addstr(0, 0, "agent> ")
    scr.refresh()
    keep = None
    if args.keepalive:
        keep = socket.create_connection((host, int(port)))
        keep.sendall(b"HOLD\n")
    curses.echo()
    while True:
        line = scr.getstr(0, 7, 60).decode().split()  # blocks on the tty
        if line[:1] == ["go"]:
            turn(scr, line[1], line[2], line[3])
        scr.move(0, 7)
        scr.clrtoeol()
        scr.refresh()


curses.wrapper(ui)
