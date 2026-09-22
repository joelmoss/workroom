"""Parsers for the Linux signals the OQ19 sampler reads. Pure functions over text, so they are tested against
REAL captured output (tests/fixtures/, captured inside the measurement image) without a container.

Every parser returns None (or an empty result) for input it cannot parse instead of guessing: a wrong number
in a trace is worse than a missing one, and the staleness rule (D10) already defines what a missing sample
means.
"""

import os
import re


def parse_stat(text):
    """`/proc/<pid>/stat` -> dict, or None. The `comm` field is arbitrary bytes between the FIRST '(' and the
    LAST ')': a self-renaming TUI (Claude Code rewrites its own process name) can put spaces and ')' in it,
    so splitting on whitespace, or on the first ')', reads the wrong fields."""
    try:
        lp, rp = text.index("("), text.rindex(")")
        pid = int(text[:lp])
        rest = text[rp + 2:].split()
        return {
            "pid": pid, "comm": text[lp + 1:rp], "state": rest[0], "ppid": int(rest[1]),
            "pgrp": int(rest[2]), "sid": int(rest[3]), "tty_nr": int(rest[4]), "tpgid": int(rest[5]),
            "utime": int(rest[11]), "stime": int(rest[12]), "nice": int(rest[16]),
            "threads": int(rest[17]), "starttime": int(rest[19]),
        }
    except (ValueError, IndexError):
        return None


def cpu_ticks(stat):
    """utime + stime in clock ticks (`os.sysconf('SC_CLK_TCK')` per second)."""
    return stat["utime"] + stat["stime"]


def parse_cgroup_cpu_stat(text):
    """cgroup v2 `cpu.stat` -> {key: int}. `usage_usec` is the box-level (whole cgroup) CPU time, and includes
    processes that have exited: the counter a `setsid` escapee cannot hide from."""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            out[parts[0]] = int(parts[1])
    return out


def parse_proc_stat_cpu(text):
    """First (aggregate) line of `/proc/stat` -> (busy_ticks, total_ticks). The fallback box-level CPU where
    there is no per-workroom cgroup (a whole VM). Note: this is the WHOLE machine, not the container."""
    parts = text.split()
    if not parts or parts[0] != "cpu":
        return None
    try:
        v = [int(x) for x in parts[1:9]]  # user nice system idle iowait irq softirq steal
    except ValueError:
        return None
    if len(v) < 8:
        return None
    idle = v[3] + v[4]
    return sum(v) - idle, sum(v)


def parse_loadavg(text):
    try:
        return float(text.split()[0])
    except (ValueError, IndexError):
        return None


def parse_net_dev(text):
    """`/proc/net/dev` -> {iface: (rx_bytes, tx_bytes)}."""
    out = {}
    for line in text.splitlines()[2:]:
        if ":" not in line:
            continue
        name, data = line.split(":", 1)
        f = data.split()
        if len(f) >= 9 and f[0].isdigit() and f[8].isdigit():
            out[name.strip()] = (int(f[0]), int(f[8]))
    return out


def crosses_the_box(name, sys_net="/sys/class/net"):
    """Mirror of wr-agent `crosses_the_box`: False for a bridge device and for a bridge port with no
    backing `device` (a container's veth, a VM's tap), whose bytes are internal chatter counted twice.
    A port with a `device` is a real NIC enslaved to a bridge, and stays counted."""
    d = os.path.join(sys_net, name)
    bridge = os.path.exists(os.path.join(d, "bridge"))
    virtual_port = os.path.exists(os.path.join(d, "brport")) and not os.path.exists(os.path.join(d, "device"))
    return not (bridge or virtual_port)


def net_bytes(net_dev, exclude=("lo",), counted=lambda name: True):
    """Total (rx, tx) over the non-loopback interfaces `counted` keeps: what a provider's network-idle
    timer can see. The live sampler passes `crosses_the_box`; recorded traces predate it (2026-09-22)."""
    every = [(k, v) for k, v in net_dev.items() if k not in exclude]
    keep = [v for k, v in every if counted(k)]
    # Mirror of the Rust fallback: a filter that left nothing with traffic dropped the uplink itself.
    if not any(v[0] or v[1] for v in keep):
        keep = [v for _, v in every]
    return sum(v[0] for v in keep), sum(v[1] for v in keep)


def parse_cgroup_procs(text):
    return [int(x) for x in text.split() if x.isdigit()]


_USERS = re.compile(r'\("([^"]*)",pid=(\d+),fd=(\d+)\)')
_MS = re.compile(r"\b(lastsnd|lastrcv|lastack):(\d+)")


def parse_ss_tinp(text):
    """`ss -tinp` -> list of sockets {state, recvq, sendq, local, peer, procs:[(name, pid)], lastsnd, lastrcv,
    lastack}. The `last*` fields are milliseconds since the last send / receive / ack on that socket, the
    signal that separates an in-flight request from an idle keepalive (plan decision D3, signal S6b). Each
    socket is a header line followed by one tab-indented line of tcp_info."""
    sockets = []
    for line in text.splitlines():
        if not line.strip():
            continue
        if line[0] in " \t":
            if sockets:
                for key, value in _MS.findall(line):
                    sockets[-1][key] = int(value)
            continue
        parts = line.split()
        if parts[0] == "State" or len(parts) < 5:
            continue
        sockets.append({
            "state": parts[0], "recvq": _int(parts[1]), "sendq": _int(parts[2]),
            "local": parts[3], "peer": parts[4],
            "procs": [(n, int(p)) for n, p, _ in _USERS.findall(line)],
            "lastsnd": None, "lastrcv": None, "lastack": None,
        })
    return sockets


def _int(s):
    return int(s) if s.isdigit() else None
