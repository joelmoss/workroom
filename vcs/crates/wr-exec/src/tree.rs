//! The process tree: every descendant of a set of roots, each recorded with its start time so a
//! later signal can tell it from an unrelated process that inherited its pid.

/// A process found by the descendant walk, and enough to recognise it again later.
///
/// The start time is what makes a pid safe to signal after a delay. Pids are recycled, and the
/// termination path waits up to half a second between its hangup and its SIGKILL sweep — long
/// enough on a busy machine for a descendant to exit and its number to be handed to something
/// unrelated. `kill(pid, 0)` cannot tell those apart; a start time can, because the replacement
/// necessarily started later than the process we recorded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Descendant {
    pub pid: i32,
    /// Platform-specific units — seconds since the epoch on macOS, clock ticks since boot on
    /// Linux. Never compared across platforms, only against itself, so the unit does not matter;
    /// what matters is that it changes when the pid is reused. Zero means unknown.
    pub started: u64,
}

impl Descendant {
    /// Whether this exact process is still running — not merely whether something holds its pid.
    ///
    /// An unknown start time falls back to bare existence. That is the old behaviour, and it is the
    /// right fallback: failing to signal a real descendant leaves a process running forever, which
    /// is worse than the small risk this is guarding.
    pub fn is_running(&self) -> bool {
        // SAFETY: `kill` takes no pointers, and signal 0 delivers nothing.
        if self.pid <= 0 || unsafe { libc::kill(self.pid, 0) } != 0 {
            return false;
        }
        match (self.started, platform::start_time(self.pid)) {
            (0, _) | (_, None) => true,
            (recorded, Some(current)) => recorded == current,
        }
    }
}

/// Every transitive descendant of `roots`, found by walking parent-pid links.
///
/// Killing a pty's shell is not enough on its own. A child that calls `setsid()` leaves both the
/// pty's foreground process group and the shell's session, becoming the leader of a session
/// nothing is tracking — so `killpg` on the shell's group never reaches it, and neither does
/// matching on `getsid`. The parent link is the one relation it cannot escape, which is why this
/// walks that and not group or session membership. `SessionPTY.swift`'s `descendantProcessIDs`
/// exists for the same reason; the finding that put it there predates this port and the behaviour
/// must not be lost with the daemon.
///
/// Returns an empty vector when the process table cannot be read, rather than erroring: the caller
/// still signals the roots, which is exactly what it did before this existed.
pub fn descendants(roots: &[i32]) -> Vec<Descendant> {
    use std::collections::{HashMap, HashSet};

    let roots: HashSet<i32> = roots.iter().copied().filter(|pid| *pid > 0).collect();
    if roots.is_empty() {
        return Vec::new();
    }

    let mut children: HashMap<i32, Vec<i32>> = HashMap::new();
    let mut started: HashMap<i32, u64> = HashMap::new();
    for link in platform::parent_links() {
        if link.pid > 0 {
            children.entry(link.parent).or_default().push(link.pid);
            started.insert(link.pid, link.started);
        }
    }

    // Breadth is irrelevant here, only reachability, so this is a plain worklist. `insert`
    // returning false is what stops a cycle — which cannot happen in a real process tree, but a
    // torn read of a live table can produce one and an infinite loop in the kill path is not an
    // acceptable way to find that out.
    let mut found: HashSet<i32> = HashSet::new();
    let mut frontier: Vec<i32> = roots.iter().copied().collect();
    while let Some(parent) = frontier.pop() {
        for child in children.get(&parent).into_iter().flatten() {
            if !roots.contains(child) && found.insert(*child) {
                frontier.push(*child);
            }
        }
    }
    found
        .into_iter()
        .map(|pid| Descendant {
            pid,
            started: started.get(&pid).copied().unwrap_or(0),
        })
        .collect()
}

/// Every process still in session `sid`, the one a pty's child led, recorded as `descendants`
/// records them so a later signal cannot reach a reused pid.
///
/// The complement of `descendants` for a run session (#522): a launcher that forks its server into
/// a process group of its own and then exits leaves the server re-parented, out of every walk from
/// the session's child, but still in its session, which only `setsid` leaves. Empty for this
/// process's own session, so a sweep can never reach the daemon.
pub fn session_members(sid: i32) -> Vec<Descendant> {
    // SAFETY: `getsid` takes no pointers; 0 is this process.
    if sid <= 1 || sid == unsafe { libc::getsid(0) } {
        return Vec::new();
    }
    platform::parent_links()
        .into_iter()
        // SAFETY: as above.
        .filter(|link| link.pid > 1 && unsafe { libc::getsid(link.pid) } == sid)
        .map(|link| Descendant {
            pid: link.pid,
            started: link.started,
        })
        .collect()
}

/// One row of the process table: who it is, who started it, and when it started.
struct ProcessLink {
    pid: i32,
    parent: i32,
    started: u64,
}

#[cfg(target_os = "macos")]
mod platform {
    use super::ProcessLink;

    /// `(pid, parent pid)` for every process this user can see.
    ///
    /// `proc_listallpids` + one `proc_pidinfo` each, rather than the single `KERN_PROC_ALL` sysctl
    /// the Swift original uses, because that sysctl hands back an array of `kinfo_proc` — a large
    /// struct the libc crate does not define for Apple targets, so consuming it would mean
    /// hand-writing a kernel-fixed layout. These three symbols are all typed in libc, and the cost
    /// is a few hundred cheap syscalls once, on the kill path.
    pub(super) fn parent_links() -> Vec<ProcessLink> {
        let pids = all_pids();
        let mut links = Vec::with_capacity(pids.len());
        for pid in pids {
            // A process that exited between the listing and this call yields None. Skipping it is
            // correct — it is already gone.
            if let Some(info) = bsdinfo(pid) {
                links.push(ProcessLink {
                    pid,
                    parent: info.pbi_ppid as i32,
                    started: info.pbi_start_tvsec,
                });
            }
        }
        links
    }

    /// When this pid's current occupant started, for recognising pid reuse.
    pub(super) fn start_time(pid: i32) -> Option<u64> {
        bsdinfo(pid).map(|info| info.pbi_start_tvsec)
    }

    fn bsdinfo(pid: i32) -> Option<libc::proc_bsdinfo> {
        // SAFETY: `proc_bsdinfo` is plain old data, for which all zeroes is a valid value.
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
        // SAFETY: the buffer is `info` itself and `size` is its exact size.
        let written = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                &mut info as *mut _ as *mut libc::c_void,
                size,
            )
        };
        (written == size).then_some(info)
    }

    pub(super) fn all_pids() -> Vec<i32> {
        // Both calls return a count of pids, not bytes, though the buffer's size is passed in bytes;
        // a zero-size call says how many the table holds now. Processes can start between that and
        // the read, so ask for extra room and retry if the buffer came back exactly full — "full"
        // is indistinguishable from "truncated".
        for _ in 0..3 {
            // SAFETY: a null buffer of size 0 is the documented way to ask for the size.
            let needed = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
            if needed <= 0 {
                return Vec::new();
            }
            let stride = std::mem::size_of::<libc::c_int>();
            let capacity = needed as usize + 64;
            let mut buffer = vec![0 as libc::c_int; capacity];
            // SAFETY: the size passed is `buffer`'s length in bytes, so the call cannot write past it.
            let written = unsafe {
                libc::proc_listallpids(
                    buffer.as_mut_ptr() as *mut libc::c_void,
                    (capacity * stride) as libc::c_int,
                )
            };
            if written <= 0 {
                return Vec::new();
            }
            let count = written as usize;
            if count < capacity {
                buffer.truncate(count);
                return buffer.into_iter().filter(|pid| *pid > 0).collect();
            }
        }
        Vec::new()
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::ProcessLink;
    use std::fs;

    /// `(pid, parent pid)` for every process this user can see, from `/proc/<pid>/stat` field 4.
    ///
    /// Field 2 is the executable name in parentheses and may itself contain spaces AND
    /// parentheses, so the fields after it can only be found from the LAST `)` in the line.
    /// Splitting the whole line on whitespace — the obvious reading of the proc(5) table — parses
    /// a process named `my prog` into the wrong columns entirely.
    pub(super) fn parent_links() -> Vec<ProcessLink> {
        let Ok(entries) = fs::read_dir("/proc") else {
            return Vec::new();
        };
        let mut links = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(pid) = name.to_str().and_then(|n| n.parse::<i32>().ok()) else {
                continue;
            };
            // Unreadable or already gone: skip it, the same as a process that exited mid-scan.
            if let Some((parent, started)) = stat_fields(pid) {
                links.push(ProcessLink {
                    pid,
                    parent,
                    started,
                });
            }
        }
        links
    }

    /// When this pid's current occupant started, for recognising pid reuse.
    pub(super) fn start_time(pid: i32) -> Option<u64> {
        stat_fields(pid).map(|(_, started)| started)
    }

    /// `(ppid, starttime)` from `/proc/<pid>/stat`.
    ///
    /// Field 2 is the executable name in parentheses and may itself contain spaces AND
    /// parentheses, so the fields after it can only be found from the LAST `)` in the line.
    /// Splitting the whole line on whitespace — the obvious reading of the proc(5) table — parses
    /// a process named `my prog` into the wrong columns entirely.
    ///
    /// After that `)` the fields are state, ppid, pgrp, session, tty_nr, tpgid, flags, minflt,
    /// cminflt, majflt, cmajflt, utime, stime, cutime, cstime, priority, nice, num_threads,
    /// itrealvalue, starttime — so ppid is index 1 and starttime index 19.
    fn stat_fields(pid: i32) -> Option<(i32, u64)> {
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let after_comm = &stat[stat.rfind(')')? + 1..];
        let fields: Vec<&str> = after_comm.split_whitespace().collect();
        let parent = fields.get(1)?.parse::<i32>().ok()?;
        // A kernel too old to carry starttime, or a truncated read: unknown rather than wrong.
        let started = fields
            .get(19)
            .and_then(|f| f.parse::<u64>().ok())
            .unwrap_or(0);
        Some((parent, started))
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests;
