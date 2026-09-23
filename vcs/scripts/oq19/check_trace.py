#!/usr/bin/env python3
"""Checks that a recorded run actually DID what its label claims (T3's verification).

The gates score a policy against labels. If a scenario recorded an empty shell where the label says "vim open",
or a job that ended early where the label says BUSY, every score built on it is wrong and nothing downstream
would notice. So each scenario has a sanity assertion drawn from the SAMPLER'S trace and the driver's logs,
not from the driver's own intent:

  check_trace.py <run-dir>           exit 0 if every check passes, 1 with the failures listed
  check_trace.py <run-dir> --as ID   check the run AS scenario ID (a negative control: a trace of the wrong
                                     scenario with the same phase shape must FAIL, or the check is vacuous)

Common checks (all scenarios): the truth log matches labels.py phase for phase and is contiguous; the trace
has a header, a footer and samples across the whole timeline; the sampler ran at nice -5.
"""

import json
import os
import sys

import labels

HERE = os.path.dirname(os.path.abspath(__file__))


def load(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


class Run:
    def __init__(self, d, as_id=None):
        self.dir = d
        self.meta = json.load(open(os.path.join(d, "meta.json")))
        if as_id:
            self.meta["scenario"] = as_id
        self.truth = load(os.path.join(d, "truth.jsonl"))
        trace = load(os.path.join(d, "trace.jsonl"))
        self.header = next((r for r in trace if r["type"] == "header"), None)
        self.footer = next((r for r in trace if r["type"] == "footer"), None)
        self.samples = [r for r in trace if r["type"] == "s"]
        self.pty = load(os.path.join(d, "pty.jsonl"))
        self.lifecycle = load(os.path.join(d, "lifecycle.jsonl"))
        self.scenario = labels.BY_ID[self.meta["scenario"]]
        self.scale = self.meta["scale"]
        self.phases = [t for t in self.truth if t["label"] != labels.STALE]

    def phase(self, name):
        p = [t for t in self.phases if t["phase"] == name]
        return (p[0]["start"], p[0]["end"]) if p else None

    def busy(self):
        return next(((t["start"], t["end"]) for t in self.phases if t["label"] == labels.BUSY), None)

    def idle_window(self):
        """Where the scenario's IDLE-labelled work should be visible: the first phase."""
        return (self.phases[0]["start"], self.phases[0]["end"])

    def within(self, a, b):
        return [s for s in self.samples if a <= s["t"] <= b]

    def comms(self, a, b):
        out = set()
        for s in self.within(a, b):
            for p in s.get("procs", []):
                out.add(p[4])
        return out

    def cpu_rate(self, a, b):
        """Box CPU, in cores, between the first and last sample in [a, b]."""
        w = [s for s in self.within(a, b) if s.get("cg_cpu_usec") is not None]
        if len(w) < 2 or w[-1]["t"] == w[0]["t"]:
            return None
        return (w[-1]["cg_cpu_usec"] - w[0]["cg_cpu_usec"]) / 1e6 / (w[-1]["t"] - w[0]["t"])

    def net_rx_rate(self, a, b):
        w = self.within(a, b)
        if len(w) < 2 or w[-1]["t"] == w[0]["t"]:
            return None
        return (w[-1]["net_rx"] - w[0]["net_rx"]) / (w[-1]["t"] - w[0]["t"])

    def pty_events(self, direction, a, b):
        return [e for e in self.pty if e["d"] == direction and a <= e["t"] <= b]

    def sockets(self, a, b):
        rows = []
        for s in self.within(a, b):
            rows += s.get("sockets") or []
        return rows


def common(r, fail):
    if r.header is None or r.footer is None:
        fail("trace has no header or footer")
        return
    if not r.header.get("nice_ok"):
        fail("the sampler did not get nice -5 (needs --cap-add=SYS_NICE)")
    want = [(p.name, p.label) for p in r.scenario.phases]
    got = [(t["phase"], t["label"]) for t in r.phases]
    if want != got:
        fail("truth phases %s do not match labels.py %s" % (got, want))
        return
    for a, b in zip(r.phases, r.phases[1:]):
        if abs(b["start"] - a["end"]) > 0.05:
            fail("phases %s and %s are not contiguous (%.3f s apart)" % (a["phase"], b["phase"], b["start"] - a["end"]))
    for p, t in zip(r.scenario.phases, r.phases):
        expect = labels.seconds(p, r.meta["compressed"]) * r.scale
        if abs((t["end"] - t["start"]) - expect) > max(1.5, 0.05 * expect):  # slept, so allow scheduling slack
            fail("phase %s lasted %.1f s, expected %.1f s" % (t["phase"], t["end"] - t["start"], expect))
    interval = r.header["interval"]
    start, end = r.phases[0]["start"], r.phases[-1]["end"]
    stale = [t for t in r.truth if t["label"] == labels.STALE]
    ts = [s["t"] for s in r.within(start, end)]
    if not ts or ts[0] - start > 3 * interval or end - ts[-1] > 3 * interval:
        fail("samples do not cover the timeline")
    allowed = 3 * interval
    for a, b in zip(ts, ts[1:]):
        inside_gap = any(a >= g["start"] - interval and b <= g["end"] + 3 * interval for g in stale)
        if b - a > allowed and not inside_gap and r.meta.get("variant") != "500proc":  # there, gaps are the finding
            fail("unexplained sampling gap of %.1f s at t=%.1f" % (b - a, a))
            break


def check(r, fail):
    sid = r.scenario.id
    a0, b0 = r.idle_window()
    busy = r.busy()
    if sid == "1":
        if "bash" not in r.comms(a0, b0):
            fail("no bash in the idle shell")
        if (r.cpu_rate(a0, b0) or 0) > 0.05:
            fail("an idle shell used %.3f cores" % r.cpu_rate(a0, b0))
    elif sid in ("2a", "2b", "2c"):
        want = {"2a": "vim", "2b": "less", "2c": "tmux"}[sid]
        if not any(want in c for c in r.comms(a0, b0)):
            fail("%s is not running during the idle phase (saw %s)" % (want, sorted(r.comms(a0, b0))))
    elif sid in ("3a", "3b"):
        if "2.1.232" not in r.comms(a0, b0):
            fail("the self-renamed agent process (comm 2.1.232) is not running")
        if sid == "3b" and not [s for s in r.sockets(a0, b0) if s[0] == "ESTAB"]:
            fail("3b has no established keepalive connection")
    elif sid in ("4a", "4b"):
        if "2.1.232" not in r.comms(*busy):
            fail("the agent is not running during the turn")
        if not [s for s in r.sockets(*busy) if s[0] == "ESTAB"]:
            fail("no established connection to the peer during the turn")
        length = busy[1] - busy[0]
        early = r.pty_events("out", busy[0] + 0.05 * length, busy[0] + 0.5 * length)
        if sid == "4a" and len(early) < 3 * 0.45 * length:
            fail("4a produced %d pty output events in the first half of the turn: no spinner" % len(early))
        if sid == "4b" and early:
            fail("4b produced %d pty output events while waiting: it must be SILENT" % len(early))
        if (r.cpu_rate(busy[0] + 0.05 * length, busy[0] + 0.5 * length) or 0) > 0.15:
            fail("the waiting agent burned CPU")
    elif sid == "5":
        if r.meta.get("variant") == "500proc":
            if max(len(s["procs"]) for s in r.within(*busy)) < 300:
                fail("the 500-process variant never got past 300 processes")
        elif (r.cpu_rate(*busy) or 0) < 0.5:
            fail("the build used only %s cores" % r.cpu_rate(*busy))
    elif sid == "6":
        if "dd" not in r.comms(*busy):
            fail("no dd during the I/O job")
    elif sid == "7":
        w = r.within(*busy)
        alive = sum(1 for s in w if any(p[4] == "sleep" for p in s["procs"]))
        if not w or alive < 0.9 * len(w):
            fail("the sleeping job was alive in only %d of %d samples" % (alive, len(w)))
        if (r.cpu_rate(*busy) or 0) > 0.05:
            fail("the sleepy job used CPU")
    elif sid == "8":
        py = [p for p in (r.within(a0, b0)[len(r.within(a0, b0)) // 2]["procs"]) if p[4] == "python3"]
        if len(py) < 3:
            fail("expected the driver, the sampler and the http.server as python3 processes, saw %d" % len(py))
    elif sid == "9":
        quiet = r.phase("quiet")
        traffic = r.phase("traffic")
        q, t = r.net_rx_rate(*quiet), r.net_rx_rate(*traffic)
        if t is None or q is None or t <= max(3 * q, 1.0):
            fail("no network traffic in the busy phase (rx %s B/s against quiet %s B/s)" % (t, q))
    elif sid == "10":
        roots = set(sum((s["roots"] for s in r.samples), []))
        w = r.within(*busy)
        gone = all(not any(p[0] in roots for p in s["procs"]) for s in w[1:])
        if not gone:
            fail("the shell is still alive: the job did not outlive it")
        if not any(p[4] == "python3" and p[2] not in roots for s in w for p in s["procs"]):
            fail("no setsid'd python3 job seen")
        if (r.cpu_rate(*busy) or 0) < 0.5:
            fail("the setsid'd job did not burn CPU")
    elif sid == "11":
        starts = [e for e in r.lifecycle if e["event"] == "start"]
        ends = [e for e in r.lifecycle if e["event"] == "end"]
        if len(starts) != 1 or len(ends) != 1:
            fail("expected one exec lifecycle span, saw %d starts and %d ends" % (len(starts), len(ends)))
        elif abs(starts[0]["t"] - busy[0]) > 1.0 or abs(ends[0]["t"] - busy[1]) > 1.0:
            fail("the lifecycle span does not match the BUSY phase")
        if r.pty_events("out", *busy):
            fail("scenario 11 must have no pty activity")
    elif sid == "12":
        rates = []
        w = r.within(*busy)
        for i in range(0, len(w) - 5, 5):
            rates.append(r.cpu_rate(w[i]["t"], w[i + 5]["t"]))
        rates = [x for x in rates if x is not None]
        if not rates or max(rates) < 0.5 or min(rates) > 0.2:
            fail("scenario 12 shows no bursts (windowed CPU %s)" % (["%.2f" % x for x in rates][:12],))
    elif sid == "13":
        if "watch" not in r.comms(a0, b0):
            fail("watch is not running")
    elif sid == "14":
        n = len(r.pty_events("in", *busy))
        if n < (busy[1] - busy[0]) / 2 - 2:
            fail("only %d keystrokes during the typing phase" % n)
    elif sid == "16":
        comms = r.comms(a0, b0)
        for daemon in ("sshd", "cron"):
            if daemon not in comms:
                fail("%s is not running on the noisy box" % daemon)
    elif sid == "17":
        rate = r.cpu_rate(*busy)
        if rate is None or not 0.1 <= rate <= 0.6:
            fail("scenario 17's job should use about 0.3 cores, saw %s" % rate)
    elif sid == "18":
        stale = [t for t in r.truth if t["label"] == labels.STALE]
        if len(stale) != 1:
            fail("scenario 18 needs exactly one STALE gap interval, saw %d" % len(stale))
        else:
            g = stale[0]
            ts = [s["t"] for s in r.samples if g["start"] - 2 <= s["t"] <= g["end"] + 2]
            worst = max((b - a for a, b in zip(ts, ts[1:])), default=0)
            if worst < 0.6 * (g["end"] - g["start"]):
                fail("the sampler was not blind for the gap (longest silence %.1f s of %.1f s)" %
                     (worst, g["end"] - g["start"]))
            if not (g["start"] < busy[0] + 1 and g["end"] > busy[0]):
                fail("the gap does not straddle the start of the work")


def main():
    as_id = sys.argv[sys.argv.index("--as") + 1] if "--as" in sys.argv else None
    r = Run(sys.argv[1], as_id)
    failures = []
    fail = failures.append
    common(r, fail)
    if not failures:
        check(r, fail)
    label = "%s (%s)" % (r.scenario.id, r.scenario.name)
    if failures:
        print("FAIL %s" % label)
        for f in failures:
            print("   - " + f)
        sys.exit(1)
    print("ok   %s" % label)


if __name__ == "__main__":
    main()
