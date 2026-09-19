#!/usr/bin/env python3
"""OQ19 sampler: reads the box, process, network and socket signals on a fixed cadence into a JSONL trace.

Runs INSIDE the measurement image (Linux). Python 3 stdlib only. Every timestamp is CLOCK_MONOTONIC seconds
(`time.monotonic()`), the same clock the driver stamps its truth log with, and never `/proc/uptime`, which
the design doc records as meaningless on a derived machine.

Trace: line 1 is a `header`, then one `s` (sample) line per tick, then a `footer` carrying the sampler's own
CPU cost (gate: <= 0.5% of one core, including the `ss` children). A tick that could not be taken on time is
NOT dropped: `late` records how far behind it ran, and a gap is scored by the staleness rule (D10), never
filtered out.

The sampler records everything it can see and applies NO exclusion list: exclusions (boundary.md) are applied
by the analysis, so the policies can be re-run against a different list without re-recording.
"""

import argparse
import json
import os
import resource
import signal
import subprocess
import sys
import time

import procfs

CGROUP = "/sys/fs/cgroup"
GROUPS = ("box", "procs", "sockets")  # box: O(1) reads; procs: O(processes); sockets: one `ss` fork per tick


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


class Sampler:
    def __init__(self, args):
        self.args = args
        self.stop = False
        self.on_sample = None  # live.py's hook: the classifier sees each sample as it is written
        self.exe_cache = {}  # pid -> (starttime, exe): readlink once per process, not once per tick
        self.clk_tck = os.sysconf("SC_CLK_TCK")
        self.groups = tuple(g for g in args.signals.split(",") if g)
        unknown = set(self.groups) - set(GROUPS)
        if unknown:
            sys.exit("unknown signal group(s): %s (choose from %s)" % (",".join(sorted(unknown)), ",".join(GROUPS)))

    @staticmethod
    def cpu_used():
        """Sampler CPU seconds so far, its `ss` children included (they are part of what it costs)."""
        a, b = resource.getrusage(resource.RUSAGE_SELF), resource.getrusage(resource.RUSAGE_CHILDREN)
        return a.ru_utime + a.ru_stime + b.ru_utime + b.ru_stime

    def exe_of(self, pid, starttime):
        cached = self.exe_cache.get(pid)
        if cached and cached[0] == starttime:
            return cached[1]
        try:
            exe = os.readlink("/proc/%d/exe" % pid)
        except OSError:
            exe = None
        self.exe_cache[pid] = (starttime, exe)
        return exe

    def processes(self):
        """Every process in the cgroup: (pid, ppid, sid, pgrp, comm, exe, state, ticks, nice, wchan)."""
        text = read(os.path.join(CGROUP, "cgroup.procs"))
        pids = procfs.parse_cgroup_procs(text) if text is not None else []
        rows = []
        for pid in pids:
            st = procfs.parse_stat(read("/proc/%d/stat" % pid) or "")
            if st is None:
                continue  # exited between listing and reading
            wchan = (read("/proc/%d/wchan" % pid) or "").strip()
            rows.append([pid, st["ppid"], st["sid"], st["pgrp"], st["comm"],
                         self.exe_of(pid, st["starttime"]), st["state"], procfs.cpu_ticks(st),
                         st["nice"], wchan])
        return rows

    def sockets(self):
        try:
            out = subprocess.run(["ss", "-tinp"], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return None
        return [[s["state"], s["local"], s["peer"], s["recvq"], s["sendq"], s["procs"],
                 s["lastsnd"], s["lastrcv"], s["lastack"]] for s in procfs.parse_ss_tinp(out)]

    def sample(self, tick):
        t = time.monotonic()
        cpu = stat = net = None
        if "box" in self.groups:
            cpu = procfs.parse_cgroup_cpu_stat(read(os.path.join(CGROUP, "cpu.stat")) or "")
            stat = procfs.parse_proc_stat_cpu(read("/proc/stat") or "")
            net = procfs.net_bytes(procfs.parse_net_dev(read("/proc/net/dev") or ""))
        roots = []
        rf = self.args.roots_file
        if rf:
            try:
                roots = json.loads(read(rf) or "[]")
            except ValueError:
                roots = []
        row = {"type": "s", "t": t, "tick": tick, "roots": roots}
        if "box" in self.groups:
            row.update({
                "cg_cpu_usec": cpu.get("usage_usec"),
                "cg_throttled_usec": cpu.get("throttled_usec"),  # a --cpus quota throttles the sampler too
                "pids_current": read(os.path.join(CGROUP, "pids.current")),
                "sys_cpu": stat, "load1": procfs.parse_loadavg(read("/proc/loadavg") or ""),
                "net_rx": net[0], "net_tx": net[1],
            })
        if "procs" in self.groups:
            row["procs"] = self.processes()
        if "sockets" in self.groups and self.args.ss_every and tick % self.args.ss_every == 0:
            row["sockets"] = self.sockets()
        row["dt_read"] = time.monotonic() - t
        return row

    def run(self):
        signal.signal(signal.SIGTERM, lambda *_: setattr(self, "stop", True))
        signal.signal(signal.SIGINT, lambda *_: setattr(self, "stop", True))
        try:
            os.nice(-5)  # boundary.md: needs CAP_SYS_NICE, which Docker drops by default (run.sh adds it)
            nice_ok = True
        except OSError:
            nice_ok = False
        interval = self.args.interval
        start = time.monotonic()
        with open(self.args.out, "w") as out:
            out.write(json.dumps({
                "type": "header", "interval": interval, "clk_tck": self.clk_tck, "pid": os.getpid(),
                "start": start, "nice_ok": nice_ok, "ss_every": self.args.ss_every, "signals": self.groups,
                "python": sys.version.split()[0], "ncpu": os.cpu_count(),
                "cgroup_cpu_stat": os.path.exists(os.path.join(CGROUP, "cpu.stat")),
            }) + "\n")
            tick, late_total, late_max = 0, 0, 0.0
            warm = None  # (wall, cpu) after the first sample: cost is measured from here, excluding startup
            while not self.stop:
                due = start + tick * interval
                now = time.monotonic()
                if now < due:
                    time.sleep(due - now)
                    if self.stop:
                        break
                else:
                    late = now - due
                    late_total += 1 if late > interval else 0
                    late_max = max(late_max, late)
                row = self.sample(tick)
                out.write(json.dumps(row, separators=(",", ":")) + "\n")
                out.flush()
                if self.on_sample:
                    self.on_sample(row)
                tick += 1
                if warm is None:
                    warm = (time.monotonic(), self.cpu_used())
                if self.args.duration and time.monotonic() - start >= self.args.duration:
                    break
                # If a sample overran whole intervals, skip ahead rather than bursting to catch up: the
                # missed ticks are visible as a gap in `tick`, which the staleness rule scores.
                behind = int((time.monotonic() - start) / interval) - tick
                if behind > 0:
                    tick += behind
            wall = time.monotonic() - start
            cpu_s = self.cpu_used()
            steady = None
            if warm and time.monotonic() > warm[0]:
                steady = (cpu_s - warm[1]) / (time.monotonic() - warm[0])
            out.write(json.dumps({
                "type": "footer", "wall_s": wall, "cpu_s": cpu_s, "cpu_fraction": cpu_s / wall if wall else None,
                "cpu_fraction_steady": steady, "samples": tick, "overran_ticks": late_total,
                "max_late_s": late_max, "maxrss_kb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            }) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--duration", type=float, default=0, help="seconds; 0 = until SIGTERM")
    ap.add_argument("--roots-file", default=None, help="JSON list of session-leader pids, re-read each tick")
    ap.add_argument("--ss-every", type=int, default=1, help="run `ss -tinp` every N ticks (0 = never)")
    ap.add_argument("--signals", default=",".join(GROUPS),
                    help="comma list of signal groups to read (default all): " + ", ".join(GROUPS))
    Sampler(ap.parse_args()).run()


if __name__ == "__main__":
    main()
