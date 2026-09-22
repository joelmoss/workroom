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

use std::collections::HashSet;

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
    /// Session-leader pids, as the trace format records them. Carried, not read: the classifier
    /// treats a leader like any other process (see `candidates`), and the ten golden fixtures
    /// replay exactly either way.
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

/// `/proc/net/dev` -> `(rx, tx)` totals over the non-loopback interfaces `counted` keeps: what a
/// provider's network-idle timer sees. The live reader passes [`crosses_the_box`]; the predicate is
/// a parameter so the parse stays testable against a capture on any platform.
pub fn parse_net_dev(text: &str, counted: impl Fn(&str) -> bool) -> (u64, u64) {
    let (mut rx, mut tx) = (0u64, 0u64);
    for line in text.lines().skip(2) {
        let Some((name, data)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim();
        if name == "lo" || !counted(name) {
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

/// The interfaces a default route leaves by, IPv4 (`/proc/net/route`) or IPv6
/// (`/proc/net/ipv6_route`): the box's uplink as the kernel itself routes it. IPv4 shows the main
/// table only, so an IPv4 default that lives solely in a policy table is missed; IPv6 lists every
/// table, so a policy-table IPv6 default counts.
pub fn default_route_interfaces(route: &str, ipv6_route: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    for line in route.lines().skip(1) {
        // Iface Destination Gateway Flags RefCnt Use Metric Mask ...
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.get(1) == Some(&"00000000") && f.get(7) == Some(&"00000000") {
            out.insert(f[0].to_string());
        }
    }
    for line in ipv6_route.lines() {
        // dest dest_prefix src src_prefix next_hop metric refcnt use flags iface
        let f: Vec<&str> = line.split_whitespace().collect();
        let is_default =
            f.first().is_some_and(|d| d.bytes().all(|b| b == b'0')) && f.get(1) == Some(&"00");
        if let (true, Some(iface)) = (is_default, f.get(9)) {
            if *iface != "lo" {
                out.insert((*iface).to_string());
            }
        }
    }
    out
}

/// Whether an interface's bytes can have crossed the box's boundary, by the kernel's own
/// classification rather than by name (`docker0`, `br-*`, `podman0`, `cni0`, `virbr0` all look
/// alike to it). Two kinds are internal:
///
/// - an **internal bridge**: a bridge device (`bridge/`) that no default route leaves by, and
/// - a **virtual port of one**: a port (`brport/`) with no backing `device` — the host end of a
///   container's `veth` or a VM's `tap` — whose `master` is an internal bridge.
///
/// Container-to-container chatter is counted on both veths and host-to-container traffic on the
/// bridge too, while traffic that leaves the box also shows up on the uplink, so dropping them
/// loses nothing a provider's idle timer sees. Measured 2026-09-22 in Docker's VM: one
/// `pg_isready` a second between two containers is 1804 B/s on their veths, 3.6x the 500 B/s
/// threshold on its own, and none of it reaches the uplink.
///
/// **A bridge the box routes out by is the uplink, and so is everything on it.** An LXC/Incus
/// system container that bridges its own veth `eth0` into `br0` for nested guests has no NIC with
/// a `device` at all: its default route leaves by `br0`, so `br0` and every port on it — `eth0`
/// included — stay counted. That over-counts (the nested guests' chatter too), which keeps the box
/// awake; dropping them would read only a tunnel's keepalives, which hibernates it under load. A
/// port with a `device` (a NIC enslaved to any bridge) always counts, and so does anything whose
/// classification cannot be read: every miss fails awake. Inside a container `eth0` is neither a
/// bridge nor a port (checked in the OQ19 image), so the signal there is unchanged.
///
/// **No default route at all counts every interface.** Without one there is no way to tell the
/// uplink bridge from an internal one, and a box reaching a LAN service over a connected route (or
/// one whose route files could not be read) must not read idle.
///
/// `sys_net` is `/sys/class/net` and `uplinks` is [`default_route_interfaces`]; both are parameters
/// so the rule that ships is the rule the tests pin.
pub fn crosses_the_box(sys_net: &std::path::Path, uplinks: &HashSet<String>, name: &str) -> bool {
    if uplinks.is_empty() {
        return true;
    }
    // `/proc/net/dev` names are kernel interface names, never `.`/`..` or a path.
    let internal_bridge =
        |bridge: &str| sys_net.join(bridge).join("bridge").exists() && !uplinks.contains(bridge);
    if internal_bridge(name) {
        return false;
    }
    let dir = sys_net.join(name);
    if !dir.join("brport").exists() || dir.join("device").exists() {
        return true;
    }
    // `master` is a symlink to the bridge's own sysfs directory.
    let master = std::fs::read_link(dir.join("master")).ok();
    match master
        .as_deref()
        .and_then(|m| m.file_name())
        .and_then(|m| m.to_str())
    {
        Some(bridge) => !internal_bridge(bridge),
        None => true,
    }
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
    use super::{
        crosses_the_box, default_route_interfaces, monotonic, parse_net_dev, parse_net_tcp_estab,
        parse_stat, Proc, Sample, Socket,
    };
    use std::collections::HashSet;
    use std::fs;
    use std::path::Path;

    /// Reads one tick. `skip_fd_walk` is the exclusion list's name set: a process excluded by name
    /// can never own a counting socket, so its `/proc/<pid>/fd` is not walked — and no fd is walked
    /// at all when the box holds no established connection.
    ///
    /// **Cost.** Two reads per process per second (`stat` and `wchan`), which is what the winning
    /// signal set costs; the plan's gate is 0.5% of one core. Measured in a Linux container on
    /// 2026-09-21, over 120 s of an agent with no clients:
    ///
    /// | processes | no connection | one ESTAB socket held |
    /// |---|---|---|
    /// | ~5 | 0.46% | 0.43% |
    /// | ~505 | 1.76% | 2.55% |
    ///
    /// So: inside the gate on a box with a handful of processes, over it under the 500-process
    /// stress case, which is the shape the Python measurement found too (its per-process walk alone
    /// was 2.5% there). The two terms that grow are this walk and, once the box holds a connection,
    /// the fd walk below. Shrinking the first means reading `wchan` only for candidates, which needs
    /// the classifier's exclusion pass to run inside the sampler; shrinking the second means caching
    /// each process's socket fds across ticks. Worth doing if a real box's process count ever puts
    /// an idle agent over the gate — it is not worth doing on a guess.
    pub fn sample(roots: Vec<i32>, skip_fd_walk: &[&str]) -> Sample {
        let t = monotonic();
        let mut procs = Vec::new();
        if let Ok(entries) = fs::read_dir("/proc") {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let Some(pid) = name.to_str().and_then(|n| n.parse::<i32>().ok()) else {
                    continue;
                };
                // Exited between the listing and the read: skipped, never guessed at. Read as
                // bytes, not as a `String`: `comm` is arbitrary bytes, and a process that named
                // itself with one invalid UTF-8 byte must not vanish from every signal.
                let Some(mut proc) = fs::read(format!("/proc/{pid}/stat"))
                    .ok()
                    .and_then(|s| parse_stat(&String::from_utf8_lossy(&s)))
                else {
                    continue;
                };
                proc.wchan = String::from_utf8_lossy(
                    &fs::read(format!("/proc/{pid}/wchan")).unwrap_or_default(),
                )
                .trim()
                .to_string();
                procs.push(proc);
            }
        }
        // Read per tick, like `/proc/net/dev`: a box that brings a bridge up or moves its default
        // route is classified by the routes it has now.
        let uplinks = default_route_interfaces(
            &fs::read_to_string("/proc/net/route").unwrap_or_default(),
            &fs::read_to_string("/proc/net/ipv6_route").unwrap_or_default(),
        );
        let (net_rx, net_tx) = parse_net_dev(
            &fs::read_to_string("/proc/net/dev").unwrap_or_default(),
            |name| crosses_the_box(Path::new("/sys/class/net"), &uplinks, name),
        );
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

    /// A real `/proc/net/dev`, captured in a Linux container on 2026-09-21. The Python this port
    /// replaces reads the same text as `(49268498, 239156)` — the tunnel pseudo-interfaces a real
    /// box carries are all zero, but they are not `lo` and they must not be skipped.
    #[test]
    fn net_dev_matches_the_python_on_a_real_capture() {
        let text = "\
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
 tunl0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
  gre0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
gretap0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
erspan0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
ip_vti0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
ip6_vti0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
  sit0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
ip6tnl0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
ip6gre0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
  eth0: 49268498    3774    0    0    0     0          0         0   239156    2688    0    0    0     0       0          0
";
        assert_eq!(parse_net_dev(text, |_| true), (49_268_498, 239_156));
    }

    #[test]
    fn net_dev_sums_every_interface_but_loopback() {
        let text = "Inter-|   Receive                    |  Transmit\n \
             face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets\n    \
             lo:  1000       9    0    0    0     0          0         0     2000       9\n  \
             eth0:  1660      12    0    0    0     0          0         0      421       8\n";
        assert_eq!(parse_net_dev(text, |_| true), (1660, 421));
    }

    /// Docker's own VM, captured 2026-09-22 with a two-container app running (trimmed to the rows
    /// that carry bytes). Only `eth0`, `eth1` and `services1` cross the box; the bridge and its
    /// veth ports are what the predicate — `crosses_the_box` classified them — drops.
    #[test]
    fn net_dev_skips_the_interfaces_the_predicate_rejects() {
        let text = "\
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:     140       2    0    0    0     0          0         0      140       2    0    0    0     0       0          0
  eth0: 2806764297 3750852    0    0    0     0          0         0 3743670997 4802266    0    0    0     0       0          0
  eth1: 10672637   73769    0    0    0     0          0         0   300470    1163    0    0    0     0       0          0
services1: 3567478382 2314288    0    0    0     0          0         0 133087979 1921256    0    0    0     0       0          0
br-bdbc7725768f: 38470859  643210    0    0    0     0          0         0 127911359  949280    0    2    0     0       0          0
docker0: 3336549   53067    0    0    0     0          0         0 1155792318   83978    0    2    0     0       0          0
veth1072cbd: 47475799  643210    0    0    0     0          0         0 127912231  949290    0    0    0     0       0          0
veth0ee9903: 25774917  354214    0    0    0     0          0         0 58177989  473605    0    0    0     0       0          0
";
        let internal =
            |name: &str| name == "docker0" || name.starts_with("br-") || name.starts_with("veth");
        assert_eq!(
            parse_net_dev(text, |name| !internal(name)),
            (
                2_806_764_297 + 10_672_637 + 3_567_478_382,
                3_743_670_997 + 300_470 + 133_087_979
            )
        );
    }

    /// The rule that ships, against a fake `/sys/class/net` shaped like the kernel's: a Docker
    /// bridge with a veth on it, a NIC enslaved to a bridge, and an LXC container's own `eth0`
    /// bridged into the `br0` its default route leaves by, with a nested guest's veth beside it.
    #[test]
    fn crosses_the_box_drops_internal_bridges_and_their_virtual_ports_only() {
        let sys_net = std::env::temp_dir().join(format!("wr-sysnet-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&sys_net);
        for (name, entries, master) in [
            ("eth0", &["device"][..], None),
            ("docker0", &["bridge"], None),
            ("veth1", &["brport"], Some("docker0")),
            ("virbr0", &["bridge"], None),
            ("ens5", &["brport", "device"], Some("virbr0")),
            ("br0", &["bridge"], None),
            ("lxc-eth0", &["brport"], Some("br0")),
            ("nested1", &["brport"], Some("br0")),
            ("orphan", &["brport"], None),
            ("tunl0", &[], None),
        ] {
            std::fs::create_dir_all(sys_net.join(name)).unwrap();
            for entry in entries {
                std::fs::create_dir_all(sys_net.join(name).join(entry)).unwrap();
            }
            if let Some(bridge) = master {
                std::os::unix::fs::symlink(
                    format!("../{bridge}"),
                    sys_net.join(name).join("master"),
                )
                .unwrap();
            }
        }
        let uplinks: HashSet<String> = ["br0".to_string()].into();
        let crosses = |name| crosses_the_box(&sys_net, &uplinks, name);
        assert!(crosses("eth0"), "a NIC");
        assert!(!crosses("docker0"), "a bridge no default route leaves by");
        assert!(!crosses("veth1"), "a container's veth on that bridge");
        assert!(crosses("ens5"), "a NIC enslaved to a bridge still counts");
        assert!(
            crosses("br0"),
            "the bridge the default route leaves by is the uplink"
        );
        assert!(crosses("lxc-eth0"), "and a device-less port on it is too");
        assert!(
            crosses("nested1"),
            "everything on the uplink bridge over-counts, awake"
        );
        assert!(
            crosses("orphan"),
            "a port whose bridge cannot be read fails awake"
        );
        assert!(crosses("tunl0"), "a pseudo-interface with no bridge role");
        assert!(crosses("wr-no-such-if"), "unrecognised fails awake");
        let none = HashSet::new();
        assert!(
            crosses_the_box(&sys_net, &none, "docker0")
                && crosses_the_box(&sys_net, &none, "veth1"),
            "with no default route there is no telling an internal bridge from the uplink"
        );
        let _ = std::fs::remove_dir_all(&sys_net);
    }

    /// Docker's own VM (2026-09-22) has no IPv4 default in the main table, only IPv6 defaults by
    /// `eth0` and `eth1`; a plain VM has one IPv4 default. `lo`'s unreachable defaults never count.
    #[test]
    fn default_route_interfaces_reads_both_families() {
        let route = "\
Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
docker0\t0000C80A\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0
eth0\t0041A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0
";
        let ipv6 = "\
00000000000000000000000000000000 00 00000000000000000000000000000000 00 fdc4f303932400000000000000000001 00000400 00000001 00000000 00000003     eth1
00000000000000000000000000000000 00 00000000000000000000000000000000 00 fdc4f303932400000000000000000001 00000400 00000001 00000000 00000003     eth0
00000000000000000000000000000000 00 00000000000000000000000000000000 00 00000000000000000000000000000000 ffffffff 00000001 00000000 00200200       lo
fe800000000000000000000000000000 40 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000001 00000000 00000001  docker0
";
        let expected: HashSet<String> = ["eth0".to_string(), "eth1".to_string()].into();
        assert_eq!(default_route_interfaces(route, ipv6), expected);

        let plain = "\
Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
br0\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0
br0\t0001A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0
";
        let expected: HashSet<String> = ["br0".to_string()].into();
        assert_eq!(default_route_interfaces(plain, ""), expected);
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
