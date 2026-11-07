//! Foreground-process introspection: what command is running in a pty, and where.
//!
//! This exists for the OSC 2 (title) and OSC 7 (cwd) resynthesis a reattaching client needs. When
//! a full-screen program is running, the shell's own title reports stopped long ago, so the daemon
//! has to answer "what is this pane running, and in which directory?" from the OS instead. The
//! process tree that ending a session walks is the `wr-exec` crate's.
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

#[cfg(target_os = "macos")]
mod platform {
    use super::name_from_argv;

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
}

#[cfg(target_os = "linux")]
mod platform {
    use super::{basename, is_interpreter, name_from_argv};
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
}

#[cfg(test)]
mod tests;
