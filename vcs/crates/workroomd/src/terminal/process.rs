//! Foreground-process introspection: what command is running in a pty, and where.
//!
//! This exists for the OSC 2 (title) and OSC 7 (cwd) resynthesis a reattaching client needs. When
//! a full-screen program is running, the shell's own title reports stopped long ago, so the daemon
//! has to answer "what is this pane running, and in which directory?" from the OS instead.
//!
//! **The two platforms do not agree, and the naive port is wrong.** `SessionPTY.swift` is explicit
//! that `proc_name`/`p_comm` is the wrong source, because some CLIs rewrite their own process
//! title after launch — Claude Code among them, observed reporting its version string ("2.1.232")
//! rather than the command a user typed. macOS has an answer: `KERN_PROCARGS2` returns the
//! *exec-time* argv snapshot, which no later self-renaming can touch.
//!
//! Linux has no such guarantee. Measured (Phase 0 item 1, on a real self-renaming process):
//!
//! | source                  | self-renamed process | interpreted CLI (`fakecli`, a python script) |
//! |-------------------------|----------------------|----------------------------------------------|
//! | `/proc/<pid>/cmdline`   | `2.1.232` — wrong    | `python3` — wrong                            |
//! | `/proc/<pid>/comm`      | `2.1.232` — wrong    | `python3` — wrong (and capped at 15 bytes)   |
//! | `/proc/<pid>/exe`       | correct              | `python3.12` — wrong                          |
//!
//! So `/proc/<pid>/cmdline` is the *syntactic* analogue of `KERN_PROCARGS2` and has the *semantics*
//! of `p_comm` — the exact thing the Swift comment exists to avoid. Linux therefore prefers
//! `/proc/<pid>/exe`, which self-renaming cannot touch, and falls back to the script path in
//! `argv[1]` when `exe` resolves to a known interpreter. Neither platform can do better for an
//! interpreted CLI without guessing, so both stop there rather than inventing an answer.

use std::path::Path;

/// Interpreters whose `argv[0]` (or `/proc/<pid>/exe`) names the runtime rather than the command.
/// Matched on the basename with any trailing version stripped, so `python3.12` and `node` both hit.
const INTERPRETERS: &[&str] = &[
    "python", "python2", "python3", "node", "deno", "bun", "ruby", "perl", "sh", "bash", "zsh",
    "fish", "dash", "env",
];

fn is_interpreter(name: &str) -> bool {
    let trimmed = name.trim_end_matches(|c: char| c.is_ascii_digit() || c == '.');
    INTERPRETERS.contains(&name) || INTERPRETERS.contains(&trimmed)
}

/// The rule that matters is never returning an empty name: a caller's `if let Some(name)` would
/// otherwise pass through and synthesize a blank title, which is what the Swift original guards
/// against by returning nil for a trailing-slash argv0.
///
/// Rust reaches that guarantee by a different route, and the difference is worth stating. Swift
/// slices after the last "/", so `"/usr/bin/"` gives `""` → nil. `Path::file_name` normalises the
/// trailing slash and gives `Some("bin")` — a *better* answer, and still never empty. Both satisfy
/// the invariant; only the useless-input case differs, and Rust's is the more useful of the two.
fn basename(path: &str) -> Option<&str> {
    let name = Path::new(path).file_name()?.to_str()?;
    (!name.is_empty()).then_some(name)
}

/// The command a user would recognise, for a pty's foreground process.
pub fn executable_name(pid: i32) -> Option<String> {
    if pid <= 0 {
        return None;
    }
    platform::executable_name(pid)
}

/// The Claude profile (`CLAUDE_CONFIG_DIR`) a process runs with, for the app to tell which Claude
/// account a pane uses (#480). `Some("")` when it is set empty, `None` when it is unset or the
/// environment cannot be read.
pub fn claude_profile(pid: i32) -> Option<String> {
    if pid <= 0 {
        return None;
    }
    platform::environment_value(pid, "CLAUDE_CONFIG_DIR")
}

/// The value of `key` in a list of `KEY=value` environment entries.
fn value_in_environment<'a>(entries: impl Iterator<Item = &'a [u8]>, key: &str) -> Option<String> {
    entries.into_iter().find_map(|entry| {
        let value = entry.strip_prefix(key.as_bytes())?.strip_prefix(b"=")?;
        Some(String::from_utf8_lossy(value).into_owned())
    })
}

/// A process's current working directory, for OSC 7.
pub fn working_directory(pid: i32) -> Option<String> {
    if pid <= 0 {
        return None;
    }
    platform::working_directory(pid)
}

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

/// Picks the user-meaningful name out of a full argv. Shared by both platforms because the
/// interpreter problem is identical on each: the kernel rewrites a shebang invocation so argv[0]
/// is the runtime, and the script the user actually typed is argv[1].
fn name_from_argv(argv: &[String]) -> Option<String> {
    let first = argv.first()?;
    let name = basename(first)?;
    if is_interpreter(name)
        && let Some(script) = argv.iter().skip(1).find(|a| !a.starts_with('-'))
        && let Some(script_name) = basename(script)
    {
        return Some(script_name.to_string());
    }
    Some(name.to_string())
}

/// One row of the process table: who it is, who started it, and when it started.
pub(crate) struct ProcessLink {
    pub pid: i32,
    pub parent: i32,
    pub started: u64,
}

#[cfg(target_os = "macos")]
mod platform {
    use super::{ProcessLink, name_from_argv};

    /// `KERN_PROCARGS2`, the exec-time argv snapshot. Layout: `argc` (i32), the exec path
    /// (NUL-terminated), NUL padding, then `argc` NUL-terminated argv strings.
    pub(super) fn executable_name(pid: i32) -> Option<String> {
        let buffer = procargs2(pid)?;
        let (argv, _) = split_procargs(&buffer)?;
        name_from_argv(&argv)
    }

    /// The environment follows argv in the same buffer, as NUL-terminated `KEY=value` strings with
    /// no count of its own; whatever trails the last one is padding, which never matches the key.
    pub(super) fn environment_value(pid: i32, key: &str) -> Option<String> {
        let buffer = procargs2(pid)?;
        let (_, environment) = split_procargs(&buffer)?;
        super::value_in_environment(environment.split(|b| *b == 0), key)
    }

    /// argv, and the bytes after it (the environment), from a `KERN_PROCARGS2` buffer.
    fn split_procargs(buffer: &[u8]) -> Option<(Vec<String>, &[u8])> {
        if buffer.len() <= 4 {
            return None;
        }
        let argc = i32::from_ne_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]);
        if argc <= 0 {
            return None;
        }

        let mut offset = 4usize;
        // Skip the exec path, then the NUL padding after it, to land on argv[0].
        while offset < buffer.len() && buffer[offset] != 0 {
            offset += 1;
        }
        while offset < buffer.len() && buffer[offset] == 0 {
            offset += 1;
        }

        let mut argv = Vec::new();
        for _ in 0..argc {
            if offset >= buffer.len() {
                break;
            }
            let start = offset;
            while offset < buffer.len() && buffer[offset] != 0 {
                offset += 1;
            }
            if offset > start {
                argv.push(String::from_utf8_lossy(&buffer[start..offset]).into_owned());
            }
            offset += 1;
        }
        Some((argv, buffer.get(offset..).unwrap_or_default()))
    }

    fn procargs2(pid: i32) -> Option<Vec<u8>> {
        let mut mib: [libc::c_int; 3] = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
        let mut size: libc::size_t = 0;
        // Size query first: the buffer is variable and can be large for a long argv.
        // SAFETY: `mib` holds the 3 names passed, a null old buffer asks only for the size, which
        // goes to the live `size`, and nothing is being set.
        let rc = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                3,
                std::ptr::null_mut(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc != 0 || size <= 4 {
            return None;
        }
        let mut buffer = vec![0u8; size];
        // SAFETY: as above, with `buffer` as the old buffer and `size` its exact length, so the
        // kernel writes at most `size` bytes and stores what it wrote back in `size`.
        let rc = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                3,
                buffer.as_mut_ptr() as *mut libc::c_void,
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc != 0 || size <= 4 {
            return None;
        }
        buffer.truncate(size);
        Some(buffer)
    }

    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. The struct is large and its layout is fixed by the
    /// kernel, so it is read as raw bytes and only the one field that matters is decoded — which
    /// avoids depending on a `proc_vnodepathinfo` binding that the libc crate does not expose on
    /// every version.
    pub(super) fn working_directory(pid: i32) -> Option<String> {
        const PROC_PIDVNODEPATHINFO: libc::c_int = 9;
        // struct proc_vnodepathinfo { struct vnode_info_path pvi_cdir; struct vnode_info_path pvi_rdir; }
        // vnode_info_path = { struct vnode_info vip_vi; char vip_path[MAXPATHLEN]; }
        const MAXPATHLEN: usize = 1024;
        // sizeof(struct vnode_info) is stable at 152 bytes on every arm64/x86_64 macOS.
        const VNODE_INFO_SIZE: usize = 152;
        const VNODE_INFO_PATH_SIZE: usize = VNODE_INFO_SIZE + MAXPATHLEN;
        const BUFFER_SIZE: usize = VNODE_INFO_PATH_SIZE * 2;

        let mut buffer = vec![0u8; BUFFER_SIZE];
        // SAFETY: `buffer` is BUFFER_SIZE bytes and that is the size passed, so the kernel cannot
        // write past it.
        let written = unsafe {
            libc::proc_pidinfo(
                pid,
                PROC_PIDVNODEPATHINFO,
                0,
                buffer.as_mut_ptr() as *mut libc::c_void,
                BUFFER_SIZE as libc::c_int,
            )
        };
        // A short read means the kernel's struct is not the shape assumed above; report nothing
        // rather than decoding from the wrong offset.
        if written != BUFFER_SIZE as libc::c_int {
            return None;
        }
        let path = &buffer[VNODE_INFO_SIZE..VNODE_INFO_SIZE + MAXPATHLEN];
        let end = path.iter().position(|b| *b == 0).unwrap_or(path.len());
        (end > 0).then(|| String::from_utf8_lossy(&path[..end]).into_owned())
    }

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
    use super::{ProcessLink, basename, is_interpreter, name_from_argv};
    use std::fs;

    /// Prefers `/proc/<pid>/exe`, which a process cannot rewrite, and only consults `cmdline` when
    /// `exe` names an interpreter. See the module doc for the measurements behind that order — the
    /// obvious port (`cmdline`, the shape-match for `KERN_PROCARGS2`) is the wrong one.
    pub(super) fn executable_name(pid: i32) -> Option<String> {
        let argv = cmdline(pid);
        if let Some(exe) = fs::read_link(format!("/proc/{pid}/exe"))
            .ok()
            .and_then(|p| p.to_str().map(str::to_string))
            && let Some(name) = basename(&exe)
        {
            if !is_interpreter(name) {
                return Some(name.to_string());
            }
            // An interpreter: the script the user typed is in argv, not in `exe`.
            if let Some(from_argv) = name_from_argv(&argv) {
                return Some(from_argv);
            }
            return Some(name.to_string());
        }
        // No `exe` (a zombie, or a process we cannot read): argv is all that is left, with its
        // self-renaming caveat, which still beats reporting nothing.
        name_from_argv(&argv)
    }

    fn cmdline(pid: i32) -> Vec<String> {
        fs::read(format!("/proc/{pid}/cmdline"))
            .map(|raw| {
                raw.split(|b| *b == 0)
                    .filter(|s| !s.is_empty())
                    .map(|s| String::from_utf8_lossy(s).into_owned())
                    .collect()
            })
            .unwrap_or_default()
    }

    pub(super) fn environment_value(pid: i32, key: &str) -> Option<String> {
        let raw = fs::read(format!("/proc/{pid}/environ")).ok()?;
        super::value_in_environment(raw.split(|b| *b == 0), key)
    }

    pub(super) fn working_directory(pid: i32) -> Option<String> {
        fs::read_link(format!("/proc/{pid}/cwd"))
            .ok()
            .and_then(|p| p.to_str().map(str::to_string))
    }

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

#[cfg(test)]
mod tests;
