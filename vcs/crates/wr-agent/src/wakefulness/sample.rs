//! One tick of what the wakefulness classifier may look at, and how Linux is read for it.
//!
//! The shapes here are the OQ19 sampler's trace rows (`vcs/scripts/oq19/sampler.py`), because the
//! golden fixtures the classifier is contracted against are recorded in exactly that format: the
//! replay deserializes them straight into [`Sample`], and the live sampler below fills the same
//! struct from `/proc`. One representation, so the port cannot drift from the thing it was measured
//! as.
//!
//! Everything but the `/proc` reader compiles on every platform, so the golden replay test runs on
//! a developer's Mac and not only in CI.

/// One process, as `/proc/<pid>/stat` and `/proc/<pid>/wchan` report it.
///
/// Deserializes from the trace's positional row
/// `[pid, ppid, sid, pgrp, comm, exe, state, ticks, nice, wchan]`; `sid`, `pgrp`, `exe` and `nice`
/// are recorded but no frozen-policy signal reads them, so they are dropped on the way in.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
#[serde(from = "ProcRow")]
pub struct Proc {
    pub pid: i32,
    pub ppid: i32,
    pub comm: String,
    /// `R`, `S`, `D`, `Z`, ... — `D` counts as CPU, `Z` is never a candidate.
    pub state: String,
    /// `utime + stime`, in clock ticks.
    pub ticks: i64,
    pub wchan: String,
}

/// `[pid, ppid, sid, pgrp, comm, exe, state, ticks, nice, wchan]`. A tuple rather than a named
/// struct so the positions nothing reads do not read as dead fields.
type ProcRow = (
    i32,
    i32,
    i32,
    i32,
    String,
    Option<String>,
    String,
    i64,
    i32,
    String,
);

impl From<ProcRow> for Proc {
    fn from(r: ProcRow) -> Self {
        Self {
            pid: r.0,
            ppid: r.1,
            comm: r.4,
            state: r.6,
            ticks: r.7,
            wchan: r.9,
        }
    }
}

/// One TCP socket and the pids holding it.
///
/// The trace row is `[state, local, peer, recvq, sendq, procs, lastsnd, lastrcv, lastack]`. The
/// frozen policy has `age: null` — an ESTAB socket counts at *any* age — so the three `last*`
/// millisecond fields are parsed off the row and discarded rather than carried as a number nothing
/// compares. That is also why the live reader can use `/proc/net/tcp` instead of forking `ss`,
/// which the measurement charged at ~0.75% of a core per Hz against a 0.5% budget.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
#[serde(from = "SocketRow")]
pub struct Socket {
    pub state: String,
    pub pids: Vec<i32>,
}

/// `[state, local, peer, recvq, sendq, procs, lastsnd, lastrcv, lastack]`.
type SocketRow = (
    String,
    String,
    String,
    Option<i64>,
    Option<i64>,
    Vec<(String, i32)>,
    Option<i64>,
    Option<i64>,
    Option<i64>,
);

impl From<SocketRow> for Socket {
    fn from(r: SocketRow) -> Self {
        Self {
            state: r.0,
            pids: r.5.into_iter().map(|(_, pid)| pid).collect(),
        }
    }
}

/// One tick. `t` is `CLOCK_MONOTONIC` seconds, never `/proc/uptime`: a hibernate advances both on
/// the provider measured, but uptime is meaningless on a derived machine.
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub struct Sample {
    pub t: f64,
    /// Session-leader pids. A leader is never itself a candidate.
    #[serde(default)]
    pub roots: Vec<i32>,
    #[serde(default)]
    pub procs: Vec<Proc>,
    /// `None` when sockets were not read this tick (the sampler's `ss_every`, or a failed read).
    #[serde(default)]
    pub sockets: Option<Vec<Socket>>,
    #[serde(default)]
    pub net_rx: u64,
    #[serde(default)]
    pub net_tx: u64,
}

/// `/proc/<pid>/stat`, far enough to reach `stime`.
///
/// `comm` is arbitrary bytes between the FIRST `(` and the LAST `)`: a self-renaming TUI (Claude
/// Code rewrites its own process name) can put spaces and `)` in there, so splitting on whitespace,
/// or on the first `)`, reads the wrong fields. `process::stat_fields` splits the same way.
pub fn parse_stat(text: &str) -> Option<Proc> {
    let lp = text.find('(')?;
    let rp = text.rfind(')')?;
    let pid = text.get(..lp)?.trim().parse().ok()?;
    let comm = text.get(lp + 1..rp)?.to_string();
    let rest: Vec<&str> = text.get(rp + 2..)?.split_whitespace().collect();
    let field = |i: usize| rest.get(i).and_then(|f| f.parse::<i64>().ok());
    Some(Proc {
        pid,
        ppid: field(1)? as i32,
        comm,
        state: (*rest.first()?).to_string(),
        ticks: field(11)? + field(12)?,
        wchan: String::new(),
    })
}

/// `/proc/net/dev` -> non-loopback `(rx, tx)` totals: what a provider's network-idle timer sees.
pub fn parse_net_dev(text: &str) -> (u64, u64) {
    let (mut rx, mut tx) = (0u64, 0u64);
    for line in text.lines().skip(2) {
        let Some((name, data)) = line.split_once(':') else {
            continue;
        };
        if name.trim() == "lo" {
            continue;
        }
        let f: Vec<&str> = data.split_whitespace().collect();
        if let (Some(Ok(r)), Some(Ok(t))) = (
            f.first().map(|v| v.parse::<u64>()),
            f.get(8).map(|v| v.parse::<u64>()),
        ) {
            rx += r;
            tx += t;
        }
    }
    (rx, tx)
}

/// Inodes of the ESTAB sockets in one `/proc/net/tcp`-shaped table (state `01`).
pub fn parse_net_tcp_estab(text: &str) -> Vec<u64> {
    let mut out = Vec::new();
    for line in text.lines().skip(1) {
        let f: Vec<&str> = line.split_whitespace().collect();
        // sl local rem st tx:rx tr:when retrnsmt uid timeout inode
        if f.get(3) != Some(&"01") {
            continue;
        }
        if let Some(Ok(inode)) = f.get(9).map(|v| v.parse::<u64>()) {
            out.push(inode);
        }
    }
    out
}

/// `CLOCK_MONOTONIC` seconds. The only clock the classifier uses.
pub fn monotonic() -> f64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid, writable `timespec` for the duration of the call.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as f64 + ts.tv_nsec as f64 / 1e9
}

/// Clock ticks per second. 100 everywhere the measurement ran; `analyze.py` hardcodes it, so the
/// replay does too and only the live sampler asks the system.
pub fn clk_tck() -> f64 {
    // SAFETY: `sysconf` takes an int and returns a long; no pointers involved.
    let v = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if v > 0 {
        v as f64
    } else {
        100.0
    }
}

#[cfg(target_os = "linux")]
pub use linux::sample;

#[cfg(target_os = "linux")]
mod linux {
    use super::{monotonic, parse_net_dev, parse_net_tcp_estab, parse_stat, Proc, Sample, Socket};
    use std::collections::HashSet;
    use std::fs;

    /// Reads one tick. `skip_fd_walk` is the exclusion list's name set: a process excluded by name
    /// can never own a counting socket, so its `/proc/<pid>/fd` is not walked — and no fd is walked
    /// at all when the box holds no established connection.
    ///
    /// **Cost.** Two reads per process per second (`stat` and `wchan`), which is what the winning
    /// signal set costs; the plan's gate is 0.5% of one core. Measured in a Linux container on
    /// 2026-09-21: 0.46% on a quiet box, 1.76% with 500 processes. The per-process walk is the term
    /// that grows, exactly as the Python measurement found, and shrinking it means reading `wchan`
    /// only for candidates — which needs the classifier's exclusion pass to run inside the sampler.
    /// Worth doing if a real box's process count ever puts an idle agent over the gate.
    pub fn sample(roots: Vec<i32>, skip_fd_walk: &[&str]) -> Sample {
        let t = monotonic();
        let mut procs = Vec::new();
        if let Ok(entries) = fs::read_dir("/proc") {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let Some(pid) = name.to_str().and_then(|n| n.parse::<i32>().ok()) else {
                    continue;
                };
                // Exited between the listing and the read: skipped, never guessed at.
                let Some(mut proc) = fs::read_to_string(format!("/proc/{pid}/stat"))
                    .ok()
                    .and_then(|s| parse_stat(&s))
                else {
                    continue;
                };
                proc.wchan = fs::read_to_string(format!("/proc/{pid}/wchan"))
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                procs.push(proc);
            }
        }
        let (net_rx, net_tx) =
            parse_net_dev(&fs::read_to_string("/proc/net/dev").unwrap_or_default());
        let sockets = Some(estab_sockets(&procs, skip_fd_walk));
        Sample {
            t,
            roots,
            procs,
            sockets,
            net_rx,
            net_tx,
        }
    }

    /// One `Socket` per (process, ESTAB socket) pair, which is all the frozen policy asks of the
    /// signal: does any candidate own an established connection.
    fn estab_sockets(procs: &[Proc], skip: &[&str]) -> Vec<Socket> {
        let mut estab: HashSet<u64> = HashSet::new();
        for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
            estab.extend(parse_net_tcp_estab(
                &fs::read_to_string(table).unwrap_or_default(),
            ));
        }
        if estab.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        for proc in procs {
            if skip.contains(&proc.comm.as_str()) {
                continue;
            }
            let Ok(fds) = fs::read_dir(format!("/proc/{}/fd", proc.pid)) else {
                continue; // another uid's process, or it exited: unreadable is not a BUSY vote
            };
            for fd in fds.flatten() {
                let Ok(target) = fs::read_link(fd.path()) else {
                    continue;
                };
                let Some(inode) = target
                    .to_str()
                    .and_then(|s| s.strip_prefix("socket:["))
                    .and_then(|s| s.strip_suffix(']'))
                    .and_then(|s| s.parse::<u64>().ok())
                else {
                    continue;
                };
                if estab.contains(&inode) {
                    out.push(Socket {
                        state: "ESTAB".into(),
                        pids: vec![proc.pid],
                    });
                    break; // one row is enough: the vote is presence, not a count
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stat_with_spaces_and_parens_in_comm() {
        // A self-renaming agent: `comm` is `claude (main) (busy)`, containing both spaces and `)`.
        let text = "4242 (claude (main) (busy)) S 4200 4242 4242 34816 4242 4194304 \
             1 2 3 4 700 300 0 0 20 0 1 0 999 0 0";
        let p = parse_stat(text).expect("parses");
        assert_eq!(p.pid, 4242);
        assert_eq!(p.comm, "claude (main) (busy)");
        assert_eq!(p.state, "S");
        assert_eq!(p.ppid, 4200);
        assert_eq!(p.ticks, 1000); // utime 700 + stime 300
    }

    #[test]
    fn stat_plain() {
        let text = "7 (bash) S 1 7 7 34816 7 4194304 0 0 0 0 11 22 0 0 20 0 1 0 55 0 0";
        let p = parse_stat(text).expect("parses");
        assert_eq!(
            (p.pid, p.comm.as_str(), p.ppid, p.ticks),
            (7, "bash", 1, 33)
        );
    }

    #[test]
    fn stat_rejects_garbage_rather_than_guessing() {
        assert!(parse_stat("").is_none());
        assert!(parse_stat("1 no-parens S 0").is_none());
        assert!(parse_stat("1 (sh)").is_none());
    }

    #[test]
    fn net_dev_sums_every_interface_but_loopback() {
        let text = "Inter-|   Receive                    |  Transmit\n \
             face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets\n    \
             lo:  1000       9    0    0    0     0          0         0     2000       9\n  \
             eth0:  1660      12    0    0    0     0          0         0      421       8\n";
        assert_eq!(parse_net_dev(text), (1660, 421));
    }

    #[test]
    fn net_tcp_keeps_only_established_rows() {
        let text = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   \
             0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0 0\n   \
             1: 0100007F:CE50 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 67890 1 0 0\n";
        assert_eq!(parse_net_tcp_estab(text), vec![67890]);
    }

    #[test]
    fn a_trace_row_deserializes_into_a_sample() {
        let row = r#"{"type":"s","t":389975.38,"tick":198,"roots":[7],"net_rx":1660,"net_tx":421,
            "procs":[[7,1,7,7,"bash","/usr/bin/bash","S",0,0,"do_wait"]],
            "sockets":[["ESTAB","a:1","b:2",0,0,[["agent",22]],195321,195321,195321]]}"#;
        let s: Sample = serde_json::from_str(row).expect("deserializes");
        assert_eq!(s.roots, vec![7]);
        assert_eq!(s.procs[0].comm, "bash");
        assert_eq!(s.procs[0].wchan, "do_wait");
        assert_eq!(s.sockets.as_ref().unwrap()[0].pids, vec![22]);
    }
}
