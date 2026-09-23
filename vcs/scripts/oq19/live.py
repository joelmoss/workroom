#!/usr/bin/env python3
"""The classifier running ONLINE (plan F7, the closed loop): the sampler plus the chosen policy in one process,
standing in for the wakefulness thread of the agent. Runs INSIDE the measurement image, next to the scenario.

  live.py --out trace.jsonl --interval S --config '{"policy": "P4", ...}' --window SECONDS
          --counters counters.json --verdicts verdicts.jsonl --verdict-file verdict

What it adds to the plain sampler, and why it exists: a replayed policy costs the box nothing, so replay cannot
show that the classifier's OWN activity (this process, its `ss` forks, the shim reading its verdict) keeps the
box busy. Here that activity is real, so the closed-loop idle test (scenario 16 and friends) can.

The policy code is not re-implemented: the features come from `analyze.tick_features` and the vote from
`analyze.vote`, the functions the replay was scored with. The only inputs the classifier cannot get from /proc
are the pty counters and the agent-owned operation count, which in production the agent owns; the harness driver
publishes them in `counters.json` (a few times a second), and this process turns them into the same three
numbers the replay derives from `pty.jsonl` and `lifecycle.jsonl`.

Outputs: the trace (same format as the sampler's, so it can be replayed), `verdicts.jsonl` (one line per tick:
time, verdict, raw vote) and `verdict` (the latest verdict, which the shim reads).
"""

import argparse
import bisect
import json
import os
import sys
import time

import analyze
import sampler as sampler_mod
from labels import BUSY, IDLE


class Classifier:
    def __init__(self, cfg, window_s, counters_path, verdicts_path, verdict_file, interval, sampler_pid):
        self.cfg, self.window_s, self.interval, self.pid = cfg, window_s, interval, sampler_pid
        self.counters_path, self.verdict_file = counters_path, verdict_file
        self.log = open(verdicts_path, "w")
        self.prev = None
        self.hist_t, self.hist_out = [], []
        self.net = analyze.RateWindow(analyze.NET_WINDOW_S)
        self.last_ctr, self.misses = {}, 0
        self.selfcall = os.path.join(os.path.dirname(counters_path), "selfcall")  # touched by the shim's hooks
        self.prev_starts = 0
        self.last_busy = None

    def close(self):
        self.log.close()

    def own_call_recent(self):
        """True while the shim's last assert/release call is inside the net window: that traffic is ours. Found on
        the boxd run, where the release's own HTTPS call re-voted BUSY and the timers flapped every 34 s."""
        try:
            return time.time() - os.stat(self.selfcall).st_mtime < analyze.NET_WINDOW_S + 1.0
        except OSError:
            return False

    def counters(self):
        """The agent's counters; on a failed read, the LAST GOOD values (at most one tick stale). A read that came
        back empty once put a 0 into the pty history and, one window later, made the rate look like thousands of
        bytes per second. `misses` is logged with every verdict so a run that leaned on this is visible."""
        try:
            with open(self.counters_path) as f:
                self.last_ctr = json.load(f)
        except (OSError, ValueError):
            self.misses += 1
        return self.last_ctr

    def pty_rate(self, t, out_cum):
        """Bytes/s over the last PTY_WINDOW_S, from this process's own history of the cumulative counter."""
        self.hist_t.append(t)
        self.hist_out.append(out_cum)
        i = bisect.bisect_right(self.hist_t, t - analyze.PTY_WINDOW_S) - 1
        base = self.hist_out[i] if i >= 0 else 0
        keep = max(0, i - 1)  # drop history older than the window
        del self.hist_t[:keep], self.hist_out[:keep]
        return (out_cum - base) / analyze.PTY_WINDOW_S

    def feed(self, s):
        ctr = self.counters()
        t = s["t"]
        last_in = ctr.get("last_in")
        starts = ctr.get("starts", 0)
        lifecycle = ctr.get("open", 0) > 0 or starts > self.prev_starts
        self.prev_starts = starts
        net = self.net.feed(t, s["net_rx"] + s["net_tx"])
        masked = self.own_call_recent()  # F7: the shim's provider call is our traffic, not the workroom's
        f = analyze.tick_features(s, self.prev, self.interval, self.pid, self.cfg.exclusions,
                                  self.pty_rate(t, ctr.get("out", 0)),
                                  (t - last_in) if last_in is not None else float("inf"), lifecycle,
                                  0.0 if masked else net, os.getppid())
        vote = analyze.vote(self.cfg, f)
        if vote:
            self.last_busy = t
        held = self.last_busy is not None and t - self.last_busy < self.window_s
        verdict = BUSY if (vote or held) else IDLE
        self.log.write(json.dumps({"t": t, "verdict": verdict, "vote": bool(vote), "misses": self.misses,
                                   "masked": masked}) + "\n")
        self.log.flush()
        tmp = self.verdict_file + ".tmp"
        with open(tmp, "w") as out:
            out.write(verdict + "\n")
        os.replace(tmp, self.verdict_file)  # the shim never reads half a line
        self.prev = s


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--roots-file", default=None)
    ap.add_argument("--ss-every", type=int, default=1)
    ap.add_argument("--signals", default=",".join(sampler_mod.GROUPS))
    ap.add_argument("--duration", type=float, default=0)
    ap.add_argument("--config", required=True, help="JSON of an analyze.Config")
    ap.add_argument("--window", type=float, required=True, help="hysteresis window, seconds")
    ap.add_argument("--counters", required=True)
    ap.add_argument("--verdicts", required=True)
    ap.add_argument("--verdict-file", required=True)
    args = ap.parse_args()
    cfg = analyze.Config(**json.loads(args.config))
    if cfg.interval != args.interval:
        sys.exit("the config's interval (%s) must be the sampling interval (%s): a live run is never downsampled"
                 % (cfg.interval, args.interval))
    s = sampler_mod.Sampler(args)
    clf = Classifier(cfg, args.window, args.counters, args.verdicts, args.verdict_file, args.interval, os.getpid())
    s.on_sample = clf.feed
    try:
        s.run()
    finally:
        clf.close()


if __name__ == "__main__":
    main()
