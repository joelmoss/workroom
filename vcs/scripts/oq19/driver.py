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

A BUSY phase with no action module fails loudly: an unimplemented scenario must never be recorded as if it
had done its work (that would mislabel idle time as BUSY).
"""

import argparse
import importlib
import json
import os
import pty
import select
import signal
import subprocess
import sys
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


class Context:
    """What a scenario action may use."""

    def __init__(self, session, scale, compressed, out):
        self.session, self.scale, self.compressed, self.out = session, scale, compressed, out

    def sleep(self, seconds):
        time.sleep(seconds)


def load_actions(scenario_id):
    """Action callables per phase name, from scenarios/s_<id>.py (`ACTIONS = {phase: fn(ctx, seconds)}`)."""
    try:
        return importlib.import_module("scenarios.s_%s" % scenario_id).ACTIONS
    except ModuleNotFoundError:
        return {}


def run(args):
    scenario = labels.BY_ID[args.scenario]
    os.makedirs(args.out, exist_ok=True)
    trace, roots = os.path.join(args.out, "trace.jsonl"), os.path.join(args.out, "roots.json")
    actions = load_actions(args.scenario)
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

    ctx = Context(session, args.scale, args.compressed, args.out)
    truth = []
    try:
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
        session.close()
        time.sleep(args.interval)  # a sample after the session has gone
        sampler.send_signal(signal.SIGTERM)
        sampler.wait(timeout=30)

    with open(os.path.join(args.out, "truth.jsonl"), "w") as f:
        for row in truth:
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
                   "sampler": footer, "pty_events": len(pty_log)}, f, indent=2)
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
