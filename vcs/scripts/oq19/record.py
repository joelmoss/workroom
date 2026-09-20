#!/usr/bin/env python3
"""Records the OQ19 TUNING set (plan step 2, T4): many scenario runs, a few at a time, into one directory.

  record.py tuning [--root DIR] [--parallel 4] [--only 4b,7] [--reps N] [--scale F] [--dry-run]

What it records (job list is `plan_jobs`, printed by --dry-run with the wall-time estimate):
  * every scenario, detached, full length, TUNING_REPEATS times            (gates.py)
  * the 500-process build variant of scenario 5, 3 times                    (the sampler-cost gate)
  * scenarios 4b, 7, 10 compressed, COMPRESSED_CRITICAL_REPEATS times       (D5)
  * every scenario except 17, attached, full length, once                   (scenario 15; reported, never scored)
  * two SERIAL controls, run alone AFTER everything else, with the same seed as their parallel twin (D7)

Rules that keep the set honest:
  * It runs a SNAPSHOT of the committed harness (`git archive HEAD`), never the working tree, so editing files
    while a multi-hour recording runs cannot change the later runs. The commit is recorded.
  * It refuses to start if labels.py, gates.py or boundary.md differ from the frozen tag.
  * Nothing is discarded. A run that fails check_trace.py or exits non-zero stays in the manifest with its
    status; only an INFRASTRUCTURE failure (the container did not run) is retried, once.
  * Resumable: a job with a `done` line in manifest.jsonl is skipped; a half-written directory is removed.
  * CPU-bound scenarios never run together (plan D7), and at most --parallel runs at once.

Host-side, Python 3 stdlib only. Traces are gitignored.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time

import analyze
import gates
import labels

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
FROZEN_TAG = "oq19-amendment-1"  # was oq19-preregistration-frozen until amendment 1 (gates.py header)
FROZEN_FILES = ("labels.py", "gates.py", "boundary.md")
CPU_BOUND = {"5", "10", "12", "18"}  # saturate or burst a full core; never co-scheduled with each other
NO_ATTACHED = {"17"}                 # 1.7 h each and the attach effect is the same resize: skipped, stated
VARIANT_500_REPEATS = 3
CONTROLS = (("4b", True), ("5", False))  # (scenario, compressed): the serial twin of repeat 0
INFRA_RETRIES = 1


def job_seed(key, salt=""):
    """Deterministic per job, and shared by a control and its parallel twin (same key without the role). The
    hold-out salts it, so no hold-out run replays a tuning run's jitter."""
    return int(hashlib.sha256((salt + key).encode()).hexdigest()[:8], 16)


def job_key(sid, mode, compressed, rep, variant="", interval=1.0):
    every = "" if interval == 1.0 else "-i%g" % interval
    return "%s-%s-%s%s%s-r%d" % (sid, mode, "comp" if compressed else "full", "-" + variant if variant else "",
                                 every, rep)


def job_seconds(job):
    s = labels.BY_ID[job["id"]]
    return sum(labels.seconds(p, job["compressed"]) for p in s.phases) * job["scale"]


def plan_jobs(only=None, reps=None, scale=1.0, interval=1.0):
    comp_reps = reps or gates.COMPRESSED_CRITICAL_REPEATS  # --reps is for testing the scheduler
    reps = reps or gates.TUNING_REPEATS
    ids = [s.id for s in labels.SCENARIOS if not only or s.id in only]

    def job(sid, mode, compressed, rep, variant="", role="parallel"):
        key = job_key(sid, mode, compressed, rep, variant, interval)
        return {"key": key, "id": sid, "mode": mode, "compressed": compressed, "rep": rep, "variant": variant,
                "role": role, "seed": job_seed(key), "scale": scale, "interval": interval}

    jobs = []
    for sid in ids:
        jobs += [job(sid, "detached", False, r) for r in range(reps)]
        if sid not in NO_ATTACHED:
            jobs.append(job(sid, "attached", False, 0))
        if labels.BY_ID[sid].critical:
            jobs += [job(sid, "detached", True, r) for r in range(comp_reps)]
    if not only or "5" in only:
        jobs += [job("5", "detached", False, r, "500proc") for r in range(VARIANT_500_REPEATS)]
    jobs.sort(key=lambda j: -job_seconds(j))  # longest first, so the tail of the recording is short jobs
    controls = []
    for sid, compressed in CONTROLS:
        if not only or sid in only:
            twin = job(sid, "detached", compressed, 0)
            control = dict(twin, key=twin["key"] + "-serial", role="serial-control")
            control["seed"] = twin["seed"]  # same jitter as the parallel twin: only the scheduling differs
            controls.append(control)
    return jobs, controls


def plan_holdout(frozen, scale=1.0, reps=None):
    """The hold-out set (F6): recorded AFTER the parameters are frozen, at the winner's real cadence, every run
    CLOSED LOOP (the real classifier and shim in the box), so the final claim rests on live verdicts with the
    classifier's own activity in the box. Gated scenarios only; 4b, 7 and 10 also compressed."""
    cfg = frozen["config"]
    interval = float(cfg["interval"])
    reps = reps or gates.HOLDOUT_REPEATS_FULL
    comp_reps = reps if reps != gates.HOLDOUT_REPEATS_FULL else gates.HOLDOUT_REPEATS_COMPRESSED_CRITICAL
    jobs = []

    def job(sid, compressed, rep):
        key = job_key(sid, "detached", compressed, rep, "", interval)
        idx = cfg.get("window")
        window = 0.0 if idx is None else (gates.WINDOW_GRID_COMPRESSED_S if compressed else gates.WINDOW_GRID_S)[idx]
        live_cfg = dict(cfg)
        if compressed:  # the policy's grace scales with its window (analyze.effective), so the box runs the scaled one
            live_cfg["grace"] = cfg.get("grace", 0.0) * analyze.COMPRESSION
        return {"key": key, "id": sid, "mode": "detached", "compressed": compressed, "rep": rep, "variant": "",
                "role": "parallel", "seed": job_seed(key, "holdout:"), "scale": scale, "interval": interval,
                "closed_loop": json.dumps({"config": live_cfg, "window_s": window})}

    for s in labels.GATED:
        jobs += [job(s.id, False, r) for r in range(reps)]
        if s.critical:
            jobs += [job(s.id, True, r) for r in range(comp_reps)]
    jobs.sort(key=lambda j: -job_seconds(j))
    return jobs, []


def require_committed(path):
    """The hold-out may only follow a FROZEN configuration: the file has to be committed and unmodified, so the
    parameters provably predate the traces."""
    rel = os.path.relpath(path, REPO)
    if subprocess.run(["git", "-C", REPO, "ls-files", "--error-unmatch", rel], capture_output=True).returncode:
        sys.exit("%s is not committed: freeze and commit the parameters before recording the hold-out" % rel)
    if subprocess.run(["git", "-C", REPO, "diff", "--quiet", "HEAD", "--", rel]).returncode:
        sys.exit("%s has uncommitted changes: the frozen parameters must not move" % rel)


def preflight():
    """Refuse to record against a contract that has changed since it was frozen."""
    for f in FROZEN_FILES:
        rel = "vcs/scripts/oq19/" + f
        changed = subprocess.run(["git", "-C", REPO, "diff", "--quiet", FROZEN_TAG, "--", rel]).returncode
        if changed:
            sys.exit("%s differs from the tag %s: a gate the results embarrass is a finding, not a bug to fix" %
                     (rel, FROZEN_TAG))


def snapshot(root):
    """The committed harness, exactly, in `root/harness`."""
    dest = os.path.join(root, "harness")
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    archive = subprocess.run(["git", "-C", REPO, "archive", "HEAD", "vcs/scripts/oq19"], check=True,
                             capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", dest, "--strip-components=3"], input=archive, check=True)
    return dest


def environment(root, harness):
    def out(*cmd):
        r = subprocess.run(cmd, capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else None
    env = {"commit": out("git", "-C", REPO, "rev-parse", "HEAD"),
           "frozen_tag": out("git", "-C", REPO, "rev-parse", FROZEN_TAG + "^{}"),
           "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
           "host": out("uname", "-a"),
           "docker": out("docker", "version", "--format", "{{.Server.Version}}"),
           "vm_cpus": out("docker", "info", "--format", "{{.NCPU}}"),
           "vm_mem_bytes": out("docker", "info", "--format", "{{.MemTotal}}"),
           "image_id": out("docker", "image", "inspect", "oq19", "--format", "{{.Id}}"),
           "kernel": out("docker", "run", "--rm", "oq19", "uname", "-r"),
           "gates": {k: getattr(gates, k) for k in ("TUNING_REPEATS", "COMPRESSED_CRITICAL_REPEATS")}}
    with open(os.path.join(root, "env.json"), "w") as f:
        json.dump(env, f, indent=2)
    return env


class Recorder:
    def __init__(self, root, harness, parallel, retries=INFRA_RETRIES):
        self.root, self.harness, self.parallel, self.retries = root, harness, parallel, retries
        self.set = "tuning"  # the manifest's `set` column; main() sets it from the CLI
        self.commit = None   # the harness commit each row was recorded with; main() sets it
        self.cv = threading.Condition()
        self.pending, self.running = [], []
        self.manifest = os.path.join(root, "manifest.jsonl")
        self.log_lock = threading.Lock()

    def done_keys(self):
        if not os.path.exists(self.manifest):
            return set()
        with open(self.manifest) as f:
            return {json.loads(line)["key"] for line in f if line.strip()}

    def log(self, msg):
        with self.log_lock:
            print("%s %s" % (time.strftime("%H:%M:%S"), msg), flush=True)

    def eligible(self, job):
        return not (job["id"] in CPU_BOUND and any(r["id"] in CPU_BOUND for r in self.running))

    def take(self):
        with self.cv:
            while True:
                if not self.pending:
                    return None
                if len(self.running) < self.parallel:
                    for i, job in enumerate(self.pending):
                        if self.eligible(job):
                            self.running.append(self.pending.pop(i))
                            return job
                self.cv.wait()

    def release(self, job):
        with self.cv:
            self.running.remove(job)
            self.cv.notify_all()

    def run_one(self, job):
        out = os.path.join(self.root, "runs", job["key"])
        shutil.rmtree(out, ignore_errors=True)
        env = dict(os.environ, OQ19_VARIANT=job["variant"]) if job["variant"] else dict(os.environ)
        cmd = [os.path.join(self.harness, "run.sh"), "scenario", job["id"], "--out", out,
               "--mode", job["mode"], "--jitter-seed", str(job["seed"]), "--scale", str(job["scale"]),
               "--interval", str(job["interval"])]
        if job["compressed"]:
            cmd.append("--compressed")
        if job.get("closed_loop"):
            cmd += ["--closed-loop", job["closed_loop"]]
        status, started, attempts = "infra_fail", time.time(), 0
        while attempts <= self.retries:
            attempts += 1
            r = subprocess.run(cmd, env=env, capture_output=True, text=True)
            if r.returncode == 0 and os.path.exists(os.path.join(out, "meta.json")):
                status = "recorded"
                break
            with open(os.path.join(self.root, "runs", job["key"] + ".err"), "w") as f:
                f.write(r.stdout[-2000:] + r.stderr[-4000:])
            shutil.rmtree(out, ignore_errors=True)
        check = None
        if status == "recorded":
            c = subprocess.run([sys.executable, os.path.join(self.harness, "check_trace.py"), out],
                               capture_output=True, text=True, env=dict(env, PYTHONDONTWRITEBYTECODE="1"))
            check = {"ok": c.returncode == 0, "output": c.stdout.strip()[-1500:]}
        row = dict(job, set=self.set, harness_commit=self.commit, status=status, attempts=attempts, check=check,
                   dir=os.path.relpath(out, self.root), wall_s=round(time.time() - started, 1))
        with self.cv:  # one writer at a time; the manifest is the record of what exists
            with open(self.manifest, "a") as f:
                f.write(json.dumps(row) + "\n")
        self.log("%-32s %s%s (%.0fs)" % (job["key"], status, "" if not check else (" check ok" if check["ok"]
                                                                              else " CHECK FAILED"), row["wall_s"]))

    def worker(self):
        while True:
            job = self.take()
            if job is None:
                return
            try:
                self.run_one(job)
            finally:
                self.release(job)

    def run(self, jobs):
        have = self.done_keys()
        self.pending = [j for j in jobs if j["key"] not in have]
        self.log("%d jobs to run (%d already recorded), %d at a time" % (len(self.pending), len(jobs) - len(self.pending),
                                                                        self.parallel))
        threads = [threading.Thread(target=self.worker) for _ in range(self.parallel)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("set", choices=("tuning", "holdout"))
    ap.add_argument("--frozen", default=os.path.join(HERE, "results", "frozen.json"),
                    help="holdout: the committed winner (`analyze.py tuning --freeze`)")
    ap.add_argument("--root", default=None)
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--only", default="", help="comma-separated scenario ids (a test of the scheduler)")
    ap.add_argument("--reps", type=int, default=None)
    ap.add_argument("--scale", type=float, default=1.0, help="PIPELINE CHECKS ONLY")
    ap.add_argument("--interval", type=float, default=1.0,
                    help="sampling interval; a hold-out is recorded at the winner's real cadence, never downsampled (F7)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    args.root = os.path.abspath(args.root or os.path.join(HERE, "traces", args.set))  # run.sh cd's away: absolute
    only = {x for x in args.only.split(",") if x}
    if args.set == "holdout":
        args.frozen = os.path.abspath(args.frozen)
        if not args.dry_run:
            require_committed(args.frozen)
        with open(args.frozen) as f:
            jobs, controls = plan_holdout(json.load(f), args.scale, args.reps)
        jobs = [j for j in jobs if not only or j["id"] in only]
    else:
        jobs, controls = plan_jobs(only, args.reps, args.scale, args.interval)

    busy = sum(job_seconds(j) for j in jobs + controls)
    print("%d parallel jobs + %d serial controls; %.1f container-hours; about %.1f h wall at %d parallel" %
          (len(jobs), len(controls), busy / 3600, sum(job_seconds(j) for j in jobs) / 3600 / args.parallel +
           sum(job_seconds(j) for j in controls) / 3600, args.parallel))
    if args.dry_run:
        for j in jobs + controls:
            print("  %-34s %6.0fs seed=%d" % (j["key"], job_seconds(j), j["seed"]))
        return

    preflight()
    os.makedirs(os.path.join(args.root, "runs"), exist_ok=True)
    harness = snapshot(args.root)
    env = environment(args.root, harness)
    print("harness snapshot of %s, image %s" % (env["commit"][:8], (env["image_id"] or "?")[:19]))
    rec = Recorder(args.root, harness, args.parallel)
    rec.set = args.set
    rec.commit = env["commit"]  # stamped on every row: a set may be completed by a later, disclosed harness
    rec.run(jobs)
    rec.parallel = 1  # the controls run alone: no neighbours, the D7 comparison
    rec.run(controls)
    rows = [json.loads(l) for l in open(rec.manifest) if l.strip()]
    bad = [r for r in rows if r["status"] != "recorded" or not (r["check"] or {}).get("ok")]
    print("done: %d runs, %d with a failed check or run (kept in the manifest, not discarded)" % (len(rows), len(bad)))


if __name__ == "__main__":
    main()
