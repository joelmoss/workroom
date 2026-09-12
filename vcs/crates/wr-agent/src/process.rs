//! Foreground-process introspection: what command is running in a pty, and where.
//!
//! This exists for the OSC 2 (title) and OSC 7 (cwd) resynthesis a reattaching client needs. When
//! a full-screen program is running, the shell's own title reports stopped long ago, so the agent
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
    if is_interpreter(name) {
        if let Some(script) = argv.iter().skip(1).find(|a| !a.starts_with('-')) {
            if let Some(script_name) = basename(script) {
                return Some(script_name.to_string());
            }
        }
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
        name_from_argv(&argv)
    }

    fn procargs2(pid: i32) -> Option<Vec<u8>> {
        let mut mib: [libc::c_int; 3] = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
        let mut size: libc::size_t = 0;
        // Size query first: the buffer is variable and can be large for a long argv.
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
        {
            if let Some(name) = basename(&exe) {
                if !is_interpreter(name) {
                    return Some(name.to_string());
                }
                // An interpreter: the script the user typed is in argv, not in `exe`.
                if let Some(from_argv) = name_from_argv(&argv) {
                    return Some(from_argv);
                }
                return Some(name.to_string());
            }
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

    pub(super) fn working_directory(pid: i32) -> Option<String> {
        fs::read_link(format!("/proc/{pid}/cwd"))
            .ok()
            .and_then(|p| p.to_str().map(str::to_string))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_this_process() {
        let pid = std::process::id() as i32;
        // The test binary's own name varies by harness, so assert the shape rather than a literal.
        let name = executable_name(pid).expect("own executable name");
        assert!(!name.is_empty());
        assert!(!name.contains('/'), "must be a basename, got {name:?}");

        let cwd = working_directory(pid).expect("own cwd");
        assert!(cwd.starts_with('/'), "cwd must be absolute, got {cwd:?}");
        assert_eq!(
            std::fs::canonicalize(&cwd).ok(),
            std::env::current_dir()
                .ok()
                .and_then(|p| std::fs::canonicalize(p).ok())
        );
    }

    /// The bug this module exists for, reproduced end to end rather than argued about.
    ///
    /// `exec -a NAME cmd` runs `cmd` with `argv[0]` set to NAME, so `/proc/<pid>/cmdline` reads
    /// NAME while `/proc/<pid>/exe` still points at the real binary. That is the same shape as a
    /// CLI rewriting its own title after launch, and it is exactly the case Phase 0 measured
    /// `cmdline` getting wrong. If this returns "definitely-not-sleep", the implementation has
    /// regressed to the obvious-but-wrong source.
    ///
    /// Linux-only on purpose: on macOS `KERN_PROCARGS2` records the exec-time argv faithfully, so
    /// `exec -a` is a legitimate rename there rather than a lie, and reporting it is correct.
    #[cfg(target_os = "linux")]
    #[test]
    fn prefers_the_real_binary_over_a_rewritten_argv0() {
        use std::process::{Command, Stdio};

        // `exec -a` is a bashism — /bin/sh is dash on Debian/Ubuntu, where it silently fails and
        // the fixture exits before it can be observed. Require bash explicitly, and skip rather
        // than fail where there is none, so this never becomes a flake on a minimal image.
        if !std::path::Path::new("/bin/bash").exists() {
            eprintln!("skipping: /bin/bash not present, and `exec -a` needs it");
            return;
        }

        // Both facts are read in ONE observation, and the loop waits for the REWRITE rather than
        // for the name: reading `cmdline` after the loop instead meant a fixture that had already
        // exited read back as "" — a dead process has an empty cmdline — and the test then blamed
        // the fixture for not rewriting argv[0]. That is what it did on CI, on one matrix leg,
        // while the other passed.
        let observe = || -> Option<(String, Option<String>)> {
            let mut child = Command::new("/bin/bash")
                .args(["-c", "exec -a definitely-not-sleep sleep 30"])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawn");
            let pid = child.id() as i32;
            // `exec` replaces the shell in place, so the pid is stable; give it a moment to land.
            let mut seen = None;
            for _ in 0..50 {
                std::thread::sleep(std::time::Duration::from_millis(20));
                let cmdline =
                    std::fs::read_to_string(format!("/proc/{pid}/cmdline")).unwrap_or_default();
                if cmdline.starts_with("definitely-not-sleep") {
                    seen = Some((cmdline, executable_name(pid)));
                    break;
                }
            }
            let _ = child.kill();
            let _ = child.wait();
            seen
        };

        // A fixture that dies before it can be observed is a flaky FIXTURE, not a failing
        // assertion, so give it a couple of goes before believing it.
        let Some((cmdline, name)) = (0..3).find_map(|_| observe()) else {
            panic!("the `exec -a` fixture never came up; cannot test what argv[0] is preferred");
        };

        assert!(
            cmdline.starts_with("definitely-not-sleep"),
            "the fixture did not rewrite argv[0]; cmdline was {cmdline:?}"
        );
        assert_eq!(
            name.as_deref(),
            Some("sleep"),
            "must report the real binary, not the rewritten argv[0]"
        );
    }

    #[test]
    fn rejects_invalid_pids() {
        assert_eq!(executable_name(0), None);
        assert_eq!(executable_name(-1), None);
        assert_eq!(working_directory(0), None);
    }

    #[test]
    fn prefers_the_script_over_its_interpreter() {
        let argv = vec![
            "/usr/bin/python3".to_string(),
            "/home/u/fakecli".to_string(),
        ];
        assert_eq!(name_from_argv(&argv).as_deref(), Some("fakecli"));
    }

    #[test]
    fn skips_interpreter_flags_when_finding_the_script() {
        let argv = vec![
            "/usr/bin/node".to_string(),
            "--enable-source-maps".to_string(),
            "/opt/claude/cli.js".to_string(),
        ];
        assert_eq!(name_from_argv(&argv).as_deref(), Some("cli.js"));
    }

    #[test]
    fn keeps_a_plain_command_as_itself() {
        let argv = vec!["/opt/homebrew/bin/vim".to_string(), "file.txt".to_string()];
        assert_eq!(name_from_argv(&argv).as_deref(), Some("vim"));
    }

    /// An interpreter with no script (a bare REPL) is its own answer — there is nothing better.
    #[test]
    fn bare_interpreter_reports_itself() {
        let argv = vec!["/usr/bin/python3".to_string()];
        assert_eq!(name_from_argv(&argv).as_deref(), Some("python3"));
    }

    #[test]
    fn versioned_interpreters_are_recognised() {
        assert!(is_interpreter("python3.12"));
        assert!(is_interpreter("python3"));
        assert!(is_interpreter("node"));
        assert!(!is_interpreter("vim"));
        assert!(!is_interpreter("claude"));
    }

    /// The invariant is "never empty", not "matches Swift byte for byte" — see `basename`'s doc.
    #[test]
    fn basename_never_returns_an_empty_name() {
        for path in ["/usr/bin/", "/", "", "vim", "/opt/homebrew/bin/vim", "./x/"] {
            if let Some(name) = basename(path) {
                assert!(!name.is_empty(), "{path:?} produced an empty basename");
            }
        }
        assert_eq!(basename("/"), None);
        assert_eq!(basename("vim"), Some("vim"));
        // Rust normalises the trailing slash rather than yielding nil, which is the more useful
        // answer and still satisfies the invariant above.
        assert_eq!(basename("/usr/bin/"), Some("bin"));
    }
}
