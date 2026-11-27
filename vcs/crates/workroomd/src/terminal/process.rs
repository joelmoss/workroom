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

/// A process's arguments, `argv[0]` first, as it was started (`KERN_PROCARGS2` on macOS,
/// `/proc/<pid>/cmdline` on Linux), empty arguments left out. `None` when they can't be read: the
/// process is gone, or belongs to another user.
pub fn arguments(pid: i32) -> Option<Vec<String>> {
    if pid <= 0 {
        return None;
    }
    platform::arguments(pid)
}

/// A process's controlling terminal: its device's path (`/dev/ttys003`, `/dev/pts/3`) and number,
/// which an open of that path must match. `None` when it has none, or it can't be read: the
/// process is gone, or belongs to another user. Workroom's Claude Code hook writes its report
/// there (#828), since the hook itself runs with no controlling terminal.
pub fn terminal_device(pid: i32) -> Option<(std::path::PathBuf, u64)> {
    if pid <= 0 {
        return None;
    }
    platform::terminal_device(pid)
}

/// A process's current working directory, for OSC 7.
pub fn working_directory(pid: i32) -> Option<String> {
    if pid <= 0 {
        return None;
    }
    platform::working_directory(pid)
}

/// Picks the user-meaningful name out of a full argv: the basename of [`program_from_argv`]'s
/// answer. Shared by both platforms because the interpreter problem is identical on each: the
/// kernel rewrites a shebang invocation so argv[0] is the runtime, and the script the user actually
/// typed is argv[1].
fn name_from_argv(argv: &[String], is_file: &dyn Fn(&str) -> bool) -> Option<String> {
    basename(program_from_argv(argv, is_file)?).map(str::to_string)
}

/// The program a full argv runs, as given: an interpreter's script, else `argv[0]`.
///
/// An interpreter's script is its first argument past its own flags, and only when that names a
/// file (`is_file`, which resolves a relative path against the process's own folder). Never the
/// argument after a flag that takes a program inline (`sh -c`, `bash -lc`, `python -c`/`-m`,
/// `node -e`/`--eval`/`-p`, `perl -e`): `sh -c "ls ~/bin/codex"` runs `sh`, not `codex`. And never
/// a word that is no file, such as a flag's value (`python -W ignore`): the interpreter is then
/// its own answer, as a bare REPL is.
fn program_from_argv<'a>(argv: &'a [String], is_file: &dyn Fn(&str) -> bool) -> Option<&'a str> {
    let first = argv.first()?;
    let name = basename(first)?;
    if !is_interpreter(name) {
        return Some(first);
    }
    for argument in argv.iter().skip(1) {
        if argument.starts_with('-') && argument.len() > 1 {
            if takes_code(name, argument) {
                break;
            }
            continue;
        }
        if is_file(argument) {
            return Some(argument);
        }
        break;
    }
    Some(first)
}

/// Whether `flag`, given to the interpreter `interpreter`, takes a program inline: the next
/// argument is code, not a script's path.
fn takes_code(interpreter: &str, flag: &str) -> bool {
    if let Some(long) = flag.strip_prefix("--") {
        return matches!(long, "eval" | "print" | "command");
    }
    let letters = &flag[1..];
    let family = interpreter.trim_end_matches(|c: char| c.is_ascii_digit() || c == '.');
    let any = |set: &[char]| letters.chars().any(|letter| set.contains(&letter));
    match family {
        "sh" | "bash" | "zsh" | "fish" | "dash" => any(&['c']),
        "python" => any(&['c', 'm']),
        "node" | "deno" | "bun" => any(&['e', 'p']),
        "ruby" | "perl" => any(&['e', 'E']),
        _ => false,
    }
}

/// Whether `path`, an argument of process `pid`, names a file: a relative one is the process's,
/// resolved against its working directory, never this process's.
fn names_a_file(pid: i32, path: &str) -> bool {
    let path = Path::new(path);
    if path.is_absolute() {
        return path.is_file();
    }
    working_directory(pid).is_some_and(|cwd| Path::new(&cwd).join(path).is_file())
}

/// The program process `pid` runs, as its arguments name it: an interpreter's script, else its
/// `argv[0]` ([`program_from_argv`]). A path as it was given, which may be relative.
pub fn program(pid: i32) -> Option<String> {
    let argv = arguments(pid)?;
    program_from_argv(&argv, &|path| names_a_file(pid, path)).map(str::to_string)
}

/// Who a live process is: its pid with its start time, which together name it even after the pid
/// is reused, its parent, and the user it runs as. What the Program Resume Protocol's owner check
/// walks (`crate::terminal::resume`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Identity {
    pub pid: u32,
    /// When it started, in the platform's own unit: comparable between processes, and fixed for
    /// a process's life.
    pub start: u64,
    pub parent: u32,
    pub uid: u32,
}

/// `pid`'s identity, `None` when it is gone, a zombie, or can't be read.
pub fn identity(pid: u32) -> Option<Identity> {
    if pid == 0 || pid > i32::MAX as u32 {
        return None;
    }
    platform::identity(pid)
}

/// An executable file by device and inode: the same file however a path names it (a symlink,
/// Homebrew's `bin`, `/bin` merged into `/usr/bin`). What a resume compares to tell that `exec`
/// replaced a session's shell (`crate::terminal::resume`, #825).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Image {
    device: u64,
    inode: u64,
}

impl Image {
    fn of(metadata: &std::fs::Metadata) -> Image {
        use std::os::unix::fs::MetadataExt;
        Image {
            device: metadata.dev(),
            inode: metadata.ino(),
        }
    }
}

/// The file at `path`, links followed. `None` for a relative path, which names no one file, or
/// one that can't be read.
pub fn image_of(path: &Path) -> Option<Image> {
    if !path.is_absolute() {
        return None;
    }
    std::fs::metadata(path)
        .ok()
        .map(|metadata| Image::of(&metadata))
}

/// The file process `pid` runs now, which `exec` changes and nothing else does: `/proc/<pid>/exe`
/// on Linux, `proc_pidpath` on macOS. `None` when it is gone or can't be read.
pub fn image(pid: u32) -> Option<Image> {
    if pid == 0 || pid > i32::MAX as u32 {
        return None;
    }
    platform::image(pid)
}

#[cfg(target_os = "macos")]
mod platform {
    use super::name_from_argv;

    /// `KERN_PROCARGS2`, the exec-time argv snapshot. Layout: `argc` (i32), the exec path
    /// (NUL-terminated), NUL padding, then `argc` NUL-terminated argv strings.
    pub(super) fn executable_name(pid: i32) -> Option<String> {
        name_from_argv(&arguments(pid)?, &|path| super::names_a_file(pid, path))
    }

    pub(super) fn arguments(pid: i32) -> Option<Vec<String>> {
        let buffer = procargs2(pid)?;
        split_procargs(&buffer).map(|(argv, _)| argv)
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

    /// The BSD info's controlling terminal (`e_tdev`), named by `devname`, which looks the device
    /// up in `/dev`.
    pub(super) fn terminal_device(pid: i32) -> Option<(std::path::PathBuf, u64)> {
        // SAFETY: `proc_bsdinfo` is plain C data, for which all zeroes is a valid value.
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of_val(&info) as libc::c_int;
        // SAFETY: `info` is `size` bytes and that is the size passed.
        let read = unsafe {
            libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size)
        };
        // NODEV, all ones, is no terminal.
        if read != size || info.e_tdev == u32::MAX {
            return None;
        }
        let device = info.e_tdev as libc::dev_t;
        // SAFETY: `devname` takes plain values and returns a pointer to its own static buffer, or
        // null; it is read at once, before anything else could call it.
        let name = unsafe { libc::devname(device, libc::S_IFCHR) };
        if name.is_null() {
            return None;
        }
        // SAFETY: a non-null `devname` result is a NUL-terminated string.
        let name = unsafe { std::ffi::CStr::from_ptr(name) }.to_str().ok()?;
        if name.is_empty() || name.starts_with('?') || name.contains("..") {
            return None;
        }
        Some((
            std::path::Path::new("/dev").join(name),
            u64::from(info.e_tdev),
        ))
    }

    /// The BSD info's parent and user, and the start time from its resource usage
    /// (`ri_proc_start_abstime`, mach absolute time). As herdr-core reads them
    /// (`platform/unix_resume.rs`, Apache-2.0; see `crate::terminal::resume`).
    pub(super) fn identity(pid: u32) -> Option<super::Identity> {
        const SZOMB: u32 = 5;
        let raw = pid as i32;
        // SAFETY: `proc_bsdinfo` is plain C data, for which all zeroes is a valid value.
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of_val(&info) as libc::c_int;
        // SAFETY: `info` is `size` bytes and that is the size passed, so the kernel cannot write
        // past it.
        let read = unsafe {
            libc::proc_pidinfo(raw, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size)
        };
        if read != size || info.pbi_status == SZOMB {
            return None;
        }
        // SAFETY: `rusage_info_v0` is plain C data, for which all zeroes is a valid value.
        let mut usage: libc::rusage_info_v0 = unsafe { std::mem::zeroed() };
        // SAFETY: `RUSAGE_INFO_V0` asks for exactly a `rusage_info_v0`, which `usage` is.
        if unsafe { libc::proc_pid_rusage(raw, libc::RUSAGE_INFO_V0, (&raw mut usage).cast()) } != 0
        {
            return None;
        }
        Some(super::Identity {
            pid,
            start: usage.ri_proc_start_abstime,
            parent: info.pbi_ppid,
            uid: info.pbi_uid,
        })
    }

    /// The path `proc_pidpath` gives for the process's executable, stat'd.
    pub(super) fn image(pid: u32) -> Option<super::Image> {
        let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        // SAFETY: `buffer` is the size passed, so the kernel cannot write past it.
        let written = unsafe {
            libc::proc_pidpath(pid as i32, buffer.as_mut_ptr().cast(), buffer.len() as u32)
        };
        use std::os::unix::ffi::OsStrExt;
        let written = usize::try_from(written).ok().filter(|n| *n > 0)?;
        buffer.truncate(written);
        super::image_of(std::path::Path::new(std::ffi::OsStr::from_bytes(&buffer)))
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::{basename, is_interpreter, name_from_argv, names_a_file};
    use std::fs;

    /// Prefers `/proc/<pid>/exe`, which a process cannot rewrite, and only consults `cmdline` when
    /// `exe` names an interpreter. See the module doc for the measurements behind that order — the
    /// obvious port (`cmdline`, the shape-match for `KERN_PROCARGS2`) is the wrong one.
    pub(super) fn executable_name(pid: i32) -> Option<String> {
        let argv = cmdline(pid);
        let is_file = |path: &str| names_a_file(pid, path);
        if let Some(exe) = fs::read_link(format!("/proc/{pid}/exe"))
            .ok()
            .and_then(|p| p.to_str().map(str::to_string))
            && let Some(name) = basename(&exe)
        {
            if !is_interpreter(name) {
                return Some(name.to_string());
            }
            // An interpreter: the script the user typed is in argv, not in `exe`.
            if let Some(from_argv) = name_from_argv(&argv, &is_file) {
                return Some(from_argv);
            }
            return Some(name.to_string());
        }
        // No `exe` (a zombie, or a process we cannot read): argv is all that is left, with its
        // self-renaming caveat, which still beats reporting nothing.
        name_from_argv(&argv, &is_file)
    }

    fn cmdline(pid: i32) -> Vec<String> {
        arguments(pid).unwrap_or_default()
    }

    pub(super) fn arguments(pid: i32) -> Option<Vec<String>> {
        fs::read(format!("/proc/{pid}/cmdline")).ok().map(|raw| {
            raw.split(|b| *b == 0)
                .filter(|s| !s.is_empty())
                .map(|s| String::from_utf8_lossy(s).into_owned())
                .collect()
        })
    }

    pub(super) fn environment_value(pid: i32, key: &str) -> Option<String> {
        let raw = fs::read(format!("/proc/{pid}/environ")).ok()?;
        super::value_in_environment(raw.split(|b| *b == 0), key)
    }

    /// `stat`'s `tty_nr`, then the path of the open file of the process's (stdin, stdout or
    /// stderr) that is that device, else `/dev/pts/<minor>` for a pseudo-terminal; either checked
    /// to be that device.
    pub(super) fn terminal_device(pid: i32) -> Option<(std::path::PathBuf, u64)> {
        use std::os::unix::fs::{FileTypeExt, MetadataExt};
        let stat = fs::read(format!("/proc/{pid}/stat")).ok()?;
        let at = stat.iter().rposition(|b| *b == b')')?;
        let fields = std::str::from_utf8(&stat[at + 1..]).ok()?;
        // state, ppid, pgrp, session, tty_nr.
        let device: u64 = fields.split_ascii_whitespace().nth(4)?.parse().ok()?;
        if device == 0 {
            return None;
        }
        let is_device = |path: &std::path::Path| {
            fs::metadata(path)
                .is_ok_and(|meta| meta.file_type().is_char_device() && meta.rdev() == device)
        };
        let major = (device >> 8) & 0xfff;
        let minor = (device & 0xff) | ((device >> 12) & 0xfff00);
        (0..3)
            .filter_map(|fd| fs::read_link(format!("/proc/{pid}/fd/{fd}")).ok())
            .chain((136..=143).contains(&major).then(|| {
                std::path::PathBuf::from(format!("/dev/pts/{}", (major - 136) * 256 + minor))
            }))
            .find(|path| path.starts_with("/dev/") && is_device(path))
            .map(|path| (path, device))
    }

    pub(super) fn working_directory(pid: i32) -> Option<String> {
        fs::read_link(format!("/proc/{pid}/cwd"))
            .ok()
            .and_then(|p| p.to_str().map(str::to_string))
    }

    /// The parent and start time (clock ticks since boot) from `stat`, past the command name,
    /// which can hold spaces and parentheses, and the real user from `status`, both read through
    /// one open of `/proc/<pid>` so a reused pid can't mix two processes. The user is the effective
    /// one, the second `Uid:` field, as macOS's `pbi_uid` is. As herdr-core reads them
    /// (`platform/unix_resume.rs`, Apache-2.0; see `crate::terminal::resume`).
    pub(super) fn identity(pid: u32) -> Option<super::Identity> {
        use std::os::fd::AsRawFd;
        let process = fs::File::open(format!("/proc/{pid}")).ok()?;
        let dir = std::path::PathBuf::from(format!("/proc/self/fd/{}", process.as_raw_fd()));
        let stat = fs::read(dir.join("stat")).ok()?;
        let at = stat.iter().rposition(|b| *b == b')')?;
        let fields = std::str::from_utf8(&stat[at + 1..]).ok()?;
        let mut fields = fields.split_ascii_whitespace();
        if matches!(fields.next(), Some("Z" | "X")) {
            return None;
        }
        let parent = fields.next()?.parse().ok()?;
        let start = fields.nth(17)?.parse().ok()?;
        let status = fs::read(dir.join("status")).ok()?;
        let uid = status
            .split(|b| *b == b'\n')
            .find_map(|line| line.strip_prefix(b"Uid:"))
            .and_then(|s| std::str::from_utf8(s).ok())
            .and_then(|s| s.split_ascii_whitespace().nth(1))?
            .parse()
            .ok()?;
        Some(super::Identity {
            pid,
            start,
            parent,
            uid,
        })
    }

    /// `/proc/<pid>/exe` stat'd, which reaches the file the process runs even once it has been
    /// deleted or replaced on disk.
    pub(super) fn image(pid: u32) -> Option<super::Image> {
        fs::metadata(format!("/proc/{pid}/exe"))
            .ok()
            .map(|metadata| super::Image::of(&metadata))
    }
}

#[cfg(test)]
mod tests;
