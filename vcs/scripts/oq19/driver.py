#!/usr/bin/env python3
"""OQ19 scenario driver: runs one scenario in a pty session next to a sampler and writes the truth log.

Runs INSIDE the measurement image. Python 3 stdlib only.

The phases, their labels and their durations come from labels.py, the pre-registered ground truth, so the
truth log can never disagree with the contract. What the driver contributes is what it actually DID, with
CLOCK_MONOTONIC stamps: nothing here reads a signal.

Output (one directory per run):
  meta.json     what was run: scenario, mode, scale, interval, image facts, the sampler's cost footer
  truth.jsonl   one line per phase: {scenario, phase, label, start, end}
  trace.jsonl   the sampler's signals
  pty.jsonl     {"t", "d": "out"|"in", "n": bytes}: pty output (spinners, streaming) and input recency (S4, S5)

  lifecycle.jsonl  agent-owned operations (S9): {"t", "event": "start"|"end", "name"} (scenario 11)

A scenario other than 1 with no action module fails loudly, and so does a BUSY phase with no action: an
unimplemented scenario must never be recorded as if it had done its work (that would mislabel an empty box
as "vim open" or idle time as BUSY).
"""

import argparse
import contextlib
import fcntl
import importlib
import json
import os
import pty
import select
import signal
import socket
import struct
import subprocess
import sys
import termios
import threading
import time

import labels

HERE = os.path.dirname(os.path.abspath(__file__))


class PtySession:
    """A bash on a pty. The driver reads and discards its output continuously, the way the agent's detached
    reader does (session.rs), and logs the byte counts with monotonic stamps."""

    def __init__(self, log):
        self.log = log
        self.lock = threading.Lock()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm-256color"  # curses, vim and tmux refuse to start without one
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))  # a 0x0 pty breaks TUIs
            os.execvp("bash", ["bash", "--norc", "--noprofile"])
        self.alive = True
        self.thread = threading.Thread(target=self._drain, daemon=True)
        self.thread.start()

    def _drain(self):
        while self.alive:
            r, _, _ = select.select([self.fd], [], [], 0.2)
            if not r:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                break
            if not data:
                break
            with self.lock:
                self.log.append({"t": time.monotonic(), "d": "out", "n": len(data)})

    def send(self, text):
        os.write(self.fd, text.encode())
        with self.lock:
            self.log.append({"t": time.monotonic(), "d": "in", "n": len(text)})

    def close(self):
        self.alive = False
        try:
            os.kill(self.pid, signal.SIGHUP)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def resizer(session, period=30.0):
    """The attached-mode client: a resize every `period` s (TIOCSWINSZ), which makes a full-screen TUI redraw."""
    rows = 24
    while session.alive:
        time.sleep(period)
        rows = 25 if rows == 24 else 24
        try:
            fcntl.ioctl(session.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, 80, 0, 0))
        except OSError:
            return


class Context:
    """What a scenario module may use."""

    def __init__(self, session, sampler, scale, compressed, out):
        self.session, self.sampler, self.scale, self.compressed, self.out = session, sampler, scale, compressed, out
        self.tools = os.path.join(HERE, "scenarios", "tools")
        self.peer = os.environ.get("OQ19_PEER")  # host:port of the peer container, when the scenario needs one
        self.lifecycle = []
        self.extra_truth = []  # extra truth rows a scenario emits (scenario 18's STALE gap)
        self.spawned = []
        self.variant = os.environ.get("OQ19_VARIANT", "")

    def sleep(self, seconds):
        time.sleep(max(0.0, seconds))

    def shell(self, command):
        """Type a command line into the pty shell, as a user would."""
        self.session.send(command + "\n")

    def keys(self, text):
        self.session.send(text)

    def spawn(self, argv, **kw):
        """A background process OUTSIDE the pty session (a system daemon, an agent-owned command)."""
        p = subprocess.Popen(argv, **kw)
        self.spawned.append(p)
        return p

    @contextlib.contextmanager
    def lifecycle_span(self, name):
        """An agent-owned operation in flight (signal S9): start and end are logged by the driver."""
        self.lifecycle.append({"t": time.monotonic(), "event": "start", "name": name})
        try:
            yield
        finally:
            self.lifecycle.append({"t": time.monotonic(), "event": "end", "name": name})

    def peer_send(self, line, wait_ok=True):
        host, port = self.peer.rsplit(":", 1)
        s = socket.create_connection((host, int(port)), timeout=10)
        s.sendall((line + "\n").encode())
        if wait_ok:
            s.recv(16)
        s.close()


def load_module(scenario_id):
    try:
        return importlib.import_module("scenarios.s_%s" % scenario_id)
    except ModuleNotFoundError:
        return None


def run(args):
    scenario = labels.BY_ID[args.scenario]
    os.makedirs(args.out, exist_ok=True)
    trace, roots = os.path.join(args.out, "trace.jsonl"), os.path.join(args.out, "roots.json")
    module = load_module(args.scenario)
    if module is None and scenario.id != "1":
        sys.exit("scenario %s has no action module (scenarios/s_%s.py): refusing to record an empty box as it"
                 % (scenario.id, scenario.id))
    actions = getattr(module, "ACTIONS", {})
    for phase in scenario.phases:
        if phase.label == labels.BUSY and phase.name not in actions:
            sys.exit("scenario %s phase %r is BUSY but has no action: refusing to record it as BUSY"
                     % (scenario.id, phase.name))

    pty_log = []
    session = PtySession(pty_log)
    with open(roots, "w") as f:
        json.dump([session.pid], f)
    sampler = subprocess.Popen([sys.executable, os.path.join(HERE, "sampler.py"), "--out", trace,
                                "--interval", str(args.interval), "--roots-file", roots,
                                "--ss-every", str(args.ss_every)])
    time.sleep(args.interval * 2)  # a couple of samples before the first phase, so the series has a start

    ctx = Context(session, sampler, args.scale, args.compressed, args.out)
    truth = []
    if args.mode == "attached":  # a client is present: it resizes the window now and then, as a GUI does
        threading.Thread(target=resizer, args=(session,), daemon=True).start()
    try:
        if module is not None and hasattr(module, "SETUP"):
            module.SETUP(ctx)
        for phase in scenario.phases:
            seconds = labels.seconds(phase, args.compressed) * args.scale
            start = time.monotonic()
            actions.get(phase.name, lambda c, s: c.sleep(s))(ctx, seconds)
            remaining = seconds - (time.monotonic() - start)
            if remaining > 0:
                time.sleep(remaining)
            truth.append({"scenario": scenario.id, "phase": phase.name, "label": phase.label,
                          "start": start, "end": time.monotonic()})
    finally:
        for p in ctx.spawned:
            p.kill()
        session.close()
        time.sleep(args.interval)  # a sample after the session has gone
        sampler.send_signal(signal.SIGTERM)
        sampler.wait(timeout=30)

    with open(os.path.join(args.out, "truth.jsonl"), "w") as f:
        for row in truth + ctx.extra_truth:
            f.write(json.dumps(row) + "\n")
    with open(os.path.join(args.out, "lifecycle.jsonl"), "w") as f:
        for row in ctx.lifecycle:
            f.write(json.dumps(row) + "\n")
    with open(os.path.join(args.out, "pty.jsonl"), "w") as f:
        for row in pty_log:
            f.write(json.dumps(row) + "\n")
    footer = {}
    with open(trace) as f:
        for line in f:
            if line.startswith('{"type": "footer"'):
                footer = json.loads(line)
    with open(os.path.join(args.out, "meta.json"), "w") as f:
        json.dump({"scenario": scenario.id, "name": scenario.name, "mode": args.mode, "scale": args.scale,
                   "compressed": args.compressed, "interval": args.interval, "ss_every": args.ss_every,
                   "variant": ctx.variant, "sampler": footer, "pty_events": len(pty_log)}, f, indent=2)
    print("ok %s -> %s (sampler cpu %.3f%% of a core)" %
          (scenario.id, args.out, 100 * (footer.get("cpu_fraction") or 0)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--ss-every", type=int, default=1)
    ap.add_argument("--mode", choices=("detached", "attached"), default="detached")
    ap.add_argument("--compressed", action="store_true")
    ap.add_argument("--scale", type=float, default=1.0,
                    help="multiply every phase duration: PIPELINE CHECKS ONLY, never for a scored run")
    run(ap.parse_args())


if __name__ == "__main__":
    main()
