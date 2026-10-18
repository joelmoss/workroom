//! `wr-agent run-script`: a remote workroom's setup or teardown script, run on its host the way the
//! Mac's CLI runs one locally (`internal/script`), so the two behave the same
//! (`docs/designs/scripts-on-every-workroom.md`).
//!
//! The environment is the host user's login shell's, read the way the app reads the Mac user's
//! (`ShellEnvironment.probe`): one `<shell> -lic` printing `env -0` between two markers, bounded,
//! with `WORKROOM_SHELL_PROBE=1` set so an rc file can skip slow work. Any failure falls back to
//! this process's own environment, and says so. The script runs in a process group of its own, its
//! output going straight to this process's stdout and stderr, so the app reads it as it is printed.
//! A wall clock, or a SIGTERM, SIGHUP or SIGINT to this process, ends the whole tree the way the
//! exec service ends a command (`vcs::descendants`, then the group, SIGKILL two seconds later).
use std::collections::BTreeMap;
use std::io::Read;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{Command, ExitCode, ExitStatus, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::flag;

/// Shells whose `-lic` means login and interactive; anything else gets a login `/bin/sh -lc`, as
/// `ShellEnvironment.posixShells` does on the Mac.
const POSIX_SHELLS: [&str; 5] = ["zsh", "bash", "sh", "dash", "ksh"];
/// The PATH the probe shell starts from, so a login shell composes its own as it would in a terminal.
const PROBE_SPAWN_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";
/// Longer than the Mac's 3 s: a host has no cached environment to fall back on, and a fresh VM's
/// first login (cold disk, nvm or conda in the rc files) can take more. A script runs once, so the
/// wait costs little.
const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_PROBE_BYTES: usize = 1024 * 1024;
/// The probe shell's own state, and our marker, which must not reach the script.
const DENYLIST: [&str; 5] = ["PWD", "OLDPWD", "SHLVL", "_", "WORKROOM_SHELL_PROBE"];
/// Set after the probed environment, so no rc file can revoke them.
const OVERRIDES: [(&str, &str); 2] = [("GIT_TERMINAL_PROMPT", "0"), ("GIT_OPTIONAL_LOCKS", "0")];
/// Unioned into every PATH, so a probe that returns less than a plain shell can't make it worse.
const FLOOR_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
/// The exit status of a script stopped by the wall clock, as coreutils' `timeout` uses.
pub const TIMED_OUT: u8 = 124;
/// What a script that could not be started exits with, as a shell reports one.
pub const NOT_STARTED: u8 = 126;
const KILL_GRACE: Duration = Duration::from_secs(2);

/// The signal that asked this process to stop, 0 until one does.
static SIGNALLED: AtomicI32 = AtomicI32::new(0);

extern "C" fn record_signal(signal: libc::c_int) {
    SIGNALLED.store(signal, Ordering::SeqCst);
}

/// `wr-agent run-script --dir <dir> --timeout <secs> [--env NAME=VALUE]... -- <script>`.
pub fn run_run_script(args: &[String]) -> ExitCode {
    let split = args.iter().position(|a| a == "--");
    let options = &args[..split.unwrap_or(args.len())];
    let script = split.and_then(|i| args.get(i + 1));
    let timeout = flag(options, "--timeout").and_then(|t| t.parse::<u64>().ok());
    let (Some(dir), Some(timeout), Some(script)) = (flag(options, "--dir"), timeout, script) else {
        eprintln!(
            "error: run-script needs --dir <dir> --timeout <secs> [--env NAME=VALUE]... -- <script>"
        );
        return ExitCode::FAILURE;
    };
    let extra = env_flags(options);
    install_signal_handlers();
    let shell = std::env::var("SHELL").unwrap_or_default();
    let env = match probe(&shell, PROBE_TIMEOUT) {
        Ok(probed) => merge(probed, &floor_path()),
        Err(reason) => {
            eprintln!(
                "wr-agent run-script: couldn't read the login shell's environment ({reason}); using the agent's own"
            );
            fallback()
        }
    };
    ExitCode::from(run(
        Path::new(script),
        Path::new(&dir),
        env,
        &extra,
        Duration::from_secs(timeout),
    ))
}

/// Every `--env NAME=VALUE` in `options`, in order.
fn env_flags(options: &[String]) -> Vec<(String, String)> {
    options
        .windows(2)
        .filter(|pair| pair[0] == "--env")
        .filter_map(|pair| pair[1].split_once('='))
        .map(|(name, value)| (name.to_string(), value.to_string()))
        .collect()
}

fn install_signal_handlers() {
    for signal in [libc::SIGTERM, libc::SIGHUP, libc::SIGINT] {
        // SAFETY: the handler only stores into an atomic, which is async-signal-safe.
        unsafe { libc::signal(signal, record_signal as *const () as libc::sighandler_t) };
    }
}

/// Runs `script` in `dir` with `env` and `extra` on top, and returns its exit status: the script's
/// own, 128 plus the signal that ended it, `TIMED_OUT`, or `NOT_STARTED`.
pub fn run(
    script: &Path,
    dir: &Path,
    env: BTreeMap<String, String>,
    extra: &[(String, String)],
    timeout: Duration,
) -> u8 {
    let mut command = Command::new(script);
    command
        .current_dir(dir)
        .env_clear()
        .envs(&env)
        .envs(extra.iter().map(|(name, value)| (name, value)))
        .stdin(Stdio::null())
        .process_group(0);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            eprintln!(
                "wr-agent run-script: {} could not be started: {error}",
                script.display()
            );
            return NOT_STARTED;
        }
    };
    let pid = child.id() as i32;
    let start = Instant::now();
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            return exit_status(status);
        }
        let signalled = SIGNALLED.load(Ordering::SeqCst);
        if signalled != 0 || start.elapsed() >= timeout {
            end_tree(&mut child, pid);
            if signalled != 0 {
                return 128u8.saturating_add(signalled as u8);
            }
            eprintln!(
                "wr-agent run-script: {} timed out after {} s",
                script.display(),
                timeout.as_secs()
            );
            return TIMED_OUT;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// SIGTERM to the group, with its tree recorded first so a `setsid` escaper is still reached; then,
/// after the grace, SIGKILL to what was recorded and to the group (`vcs.rs`'s exec does the same).
fn end_tree(child: &mut std::process::Child, pid: i32) {
    let recorded = crate::vcs::descendants(pid);
    // SAFETY: `kill` takes no pointers; `-pid` is the group the child leads.
    unsafe { libc::kill(-pid, libc::SIGTERM) };
    // The whole grace, even once the leader has gone: its group may still be cleaning up.
    std::thread::sleep(KILL_GRACE);
    crate::vcs::kill_recorded(&recorded);
    // SAFETY: as above.
    unsafe { libc::kill(-pid, libc::SIGKILL) };
    let killed_at = Instant::now();
    while killed_at.elapsed() < crate::vcs::REAP_GRACE {
        if !matches!(child.try_wait(), Ok(None)) {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn exit_status(status: ExitStatus) -> u8 {
    match (status.code(), status.signal()) {
        (Some(code), _) => code as u8,
        (None, Some(signal)) => 128u8.saturating_add(signal as u8),
        (None, None) => 1,
    }
}

/// The shell to probe with and its flag: `shell` when it is a POSIX shell, else `/bin/sh`.
fn probe_invocation(shell: &str) -> (&str, &'static str) {
    let name = shell.rsplit('/').next().unwrap_or_default();
    if !shell.is_empty() && POSIX_SHELLS.contains(&name) {
        (shell, "-lic")
    } else {
        ("/bin/sh", "-lc")
    }
}

/// The login shell's environment, or why it couldn't be read.
pub fn probe(shell: &str, timeout: Duration) -> Result<BTreeMap<String, String>, &'static str> {
    let marker = marker();
    let (program, shell_flag) = probe_invocation(shell);
    let line = format!("printf '%s' '{marker}'; env -0; printf '%s' '{marker}'");
    let mut command = Command::new(program);
    command
        .arg(shell_flag)
        .arg(line)
        // Home, never the workroom: an interactive rc can read directory-local tool config.
        .current_dir(std::env::var_os("HOME").unwrap_or_else(|| "/".into()))
        .env("PATH", PROBE_SPAWN_PATH)
        .env("WORKROOM_SHELL_PROBE", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);
    let Ok(mut child) = command.spawn() else {
        return Err("spawnFailed");
    };
    let pid = child.id() as i32;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let output = Arc::new(Mutex::new(Vec::new()));
    let reader = {
        let output = Arc::clone(&output);
        std::thread::spawn(move || {
            let mut chunk = [0u8; 8192];
            while let Ok(read) = stdout.read(&mut chunk) {
                if read == 0 {
                    break;
                }
                let mut kept = output.lock().unwrap_or_else(|e| e.into_inner());
                let room = MAX_PROBE_BYTES.saturating_sub(kept.len());
                kept.extend_from_slice(&chunk[..read.min(room)]);
            }
        })
    };
    let start = Instant::now();
    let status = loop {
        if let Ok(Some(status)) = child.try_wait() {
            break status;
        }
        if start.elapsed() >= timeout {
            // SAFETY: `kill` takes no pointers; `-pid` is the probe's own group.
            unsafe { libc::kill(-pid, libc::SIGKILL) };
            let _ = child.wait();
            return Err("timedOut");
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    // A background job the rc started can hold the pipe open after the shell exits.
    let drained_by = Instant::now() + Duration::from_secs(1);
    while !reader.is_finished() && Instant::now() < drained_by {
        std::thread::sleep(Duration::from_millis(10));
    }
    if !status.success() {
        return Err("nonZeroExit");
    }
    let output = std::mem::take(&mut *output.lock().unwrap_or_else(|e| e.into_inner()));
    let parsed = parse_probe_output(&output, &marker).ok_or("noMarkers")?;
    if !parsed.contains_key("PATH") {
        return Err("noPath");
    }
    Ok(parsed)
}

/// A marker no rc file prints by accident: 32 random hex digits.
fn marker() -> String {
    let mut bytes = [0u8; 16];
    let _ = ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The `env -0` payload between the first marker and the next one, split into variables. Anchored
/// on the first pair, as `ShellEnvironment.parseProbeOutput` is: rc noise arrives on both sides.
pub fn parse_probe_output(data: &[u8], marker: &str) -> Option<BTreeMap<String, String>> {
    let marker = marker.as_bytes();
    let open = find(data, marker, 0)? + marker.len();
    let close = find(data, marker, open)?;
    let mut parsed = BTreeMap::new();
    for entry in data[open..close].split(|&b| b == 0) {
        let Ok(text) = std::str::from_utf8(entry) else {
            continue;
        };
        if let Some((name, value)) = text.split_once('=') {
            parsed.insert(name.to_string(), value.to_string());
        }
    }
    (!parsed.is_empty()).then_some(parsed)
}

fn find(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    haystack
        .get(from..)?
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|at| at + from)
}

/// The probed environment, less the probe's own state, with the overrides on top and PATH unioned
/// with `floor`.
pub fn merge(mut probed: BTreeMap<String, String>, floor: &str) -> BTreeMap<String, String> {
    let path = union_path(probed.get("PATH").map(String::as_str).unwrap_or(""), floor);
    for name in DENYLIST {
        probed.remove(name);
    }
    for (name, value) in OVERRIDES {
        probed.insert(name.to_string(), value.to_string());
    }
    probed.insert("PATH".to_string(), path);
    probed
}

/// This process's own environment, for a probe that failed, with the floor's PATH and the overrides.
fn fallback() -> BTreeMap<String, String> {
    let own = std::env::vars_os()
        .filter_map(|(name, value)| Some((name.into_string().ok()?, value.into_string().ok()?)))
        .collect();
    merge(own, &floor_path())
}

/// This process's PATH, then the standard directories.
fn floor_path() -> String {
    union_path(&std::env::var("PATH").unwrap_or_default(), FLOOR_PATH)
}

fn union_path(first: &str, second: &str) -> String {
    let mut seen = std::collections::HashSet::new();
    first
        .split(':')
        .chain(second.split(':'))
        .filter(|entry| !entry.is_empty() && seen.insert(*entry))
        .collect::<Vec<_>>()
        .join(":")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let root =
            std::env::temp_dir().join(format!("wr-run-script-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::canonicalize(&root).unwrap()
    }

    fn script(dir: &Path, name: &str, body: &str, mode: u32) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, body).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        path
    }

    fn plain_env() -> BTreeMap<String, String> {
        BTreeMap::from([("PATH".to_string(), FLOOR_PATH.to_string())])
    }

    #[test]
    fn the_payload_is_read_between_the_first_pair_of_markers() {
        let data = b"noiseMARKA=1\0B=x=y\0MARKtrailingMARKjunk";
        let parsed = parse_probe_output(data, "MARK").unwrap();
        assert_eq!(parsed.get("A").map(String::as_str), Some("1"));
        assert_eq!(parsed.get("B").map(String::as_str), Some("x=y"));
        assert!(parse_probe_output(b"no markers here", "MARK").is_none());
        assert!(parse_probe_output(b"MARK only one", "MARK").is_none());
    }

    #[test]
    fn merging_drops_the_probes_state_and_puts_the_overrides_on_top() {
        let probed = BTreeMap::from([
            ("PATH".to_string(), "/home/u/bin:/usr/bin".to_string()),
            ("WORKROOM_SHELL_PROBE".to_string(), "1".to_string()),
            ("SHLVL".to_string(), "2".to_string()),
            ("GIT_TERMINAL_PROMPT".to_string(), "1".to_string()),
            ("EDITOR".to_string(), "vim".to_string()),
        ]);
        let merged = merge(probed, "/usr/bin:/bin");
        assert_eq!(merged["PATH"], "/home/u/bin:/usr/bin:/bin");
        assert!(!merged.contains_key("WORKROOM_SHELL_PROBE"));
        assert!(!merged.contains_key("SHLVL"));
        assert_eq!(merged["GIT_TERMINAL_PROMPT"], "0");
        assert_eq!(merged["GIT_OPTIONAL_LOCKS"], "0");
        assert_eq!(merged["EDITOR"], "vim");
    }

    #[test]
    fn a_posix_shell_is_probed_login_and_interactive_and_anything_else_through_sh() {
        assert_eq!(probe_invocation("/usr/bin/zsh"), ("/usr/bin/zsh", "-lic"));
        assert_eq!(probe_invocation("/bin/bash"), ("/bin/bash", "-lic"));
        assert_eq!(probe_invocation("/usr/bin/fish"), ("/bin/sh", "-lc"));
        assert_eq!(probe_invocation(""), ("/bin/sh", "-lc"));
    }

    /// A fake POSIX shell (named `bash`) that exports a variable and runs the probe's line, as a
    /// login shell reading its profile would.
    #[test]
    fn the_probe_reads_what_the_login_shell_exports() {
        let dir = scratch("probe");
        let shell = script(
            &dir,
            "bash",
            "#!/bin/sh\nexport FROM_PROFILE=yes\necho \"probe=$WORKROOM_SHELL_PROBE\" >&2\nexec /bin/sh -c \"$2\"\n",
            0o755,
        );
        let env = probe(shell.to_str().unwrap(), PROBE_TIMEOUT).unwrap();
        assert_eq!(env.get("FROM_PROFILE").map(String::as_str), Some("yes"));
        assert_eq!(
            env.get("WORKROOM_SHELL_PROBE").map(String::as_str),
            Some("1")
        );
    }

    #[test]
    fn a_probe_that_hangs_gives_up() {
        let dir = scratch("probe-hang");
        let shell = script(&dir, "zsh", "#!/bin/sh\nsleep 30\n", 0o755);
        let started = Instant::now();
        assert_eq!(
            probe(shell.to_str().unwrap(), Duration::from_millis(300)),
            Err("timedOut")
        );
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_shell_that_execs_something_else_gives_no_environment() {
        let dir = scratch("probe-exec");
        let shell = script(&dir, "zsh", "#!/bin/sh\nexec true\n", 0o755);
        assert_eq!(
            probe(shell.to_str().unwrap(), PROBE_TIMEOUT),
            Err("noMarkers")
        );
    }

    #[test]
    fn the_scripts_exit_status_is_passed_through() {
        let dir = scratch("status");
        let path = script(&dir, "workroom_setup", "#!/bin/sh\nexit 3\n", 0o755);
        assert_eq!(
            run(&path, &dir, plain_env(), &[], Duration::from_secs(10)),
            3
        );
        let ok = script(&dir, "ok", "#!/bin/sh\nexit 0\n", 0o755);
        assert_eq!(run(&ok, &dir, plain_env(), &[], Duration::from_secs(10)), 0);
    }

    #[test]
    fn the_script_runs_in_its_directory_with_the_variables_it_was_given() {
        let dir = scratch("env");
        let out = dir.join("out");
        let body = format!(
            "#!/bin/sh\n{{ pwd; echo \"$WORKROOM_NAME\"; echo \"${{WORKROOM_SHELL_PROBE:-unset}}\"; }} > {}\n",
            out.display()
        );
        let path = script(&dir, "workroom_setup", &body, 0o755);
        let extra = vec![("WORKROOM_NAME".to_string(), "jade-crest".to_string())];
        assert_eq!(
            run(&path, &dir, plain_env(), &extra, Duration::from_secs(10)),
            0
        );
        let written = std::fs::read_to_string(out).unwrap();
        let lines: Vec<&str> = written.lines().collect();
        assert_eq!(lines, [dir.to_str().unwrap(), "jade-crest", "unset"]);
    }

    #[test]
    fn a_script_that_cannot_start_is_not_started() {
        let dir = scratch("noexec");
        let path = script(&dir, "workroom_teardown", "#!/bin/sh\nexit 0\n", 0o644);
        assert_eq!(
            run(&path, &dir, plain_env(), &[], Duration::from_secs(10)),
            NOT_STARTED
        );
    }

    /// The wall clock ends the whole tree, including a grandchild that left the process group.
    #[test]
    fn the_wall_clock_kills_the_tree_including_a_setsid_escaper() {
        let dir = scratch("timeout");
        let pidfile = dir.join("escaper.pid");
        let body = format!(
            "#!/bin/sh\nperl -MPOSIX -e 'POSIX::setsid(); open(my $f, \">\", \"{}\"); print $f $$; close($f); sleep 60' &\nsleep 60\n",
            pidfile.display()
        );
        let path = script(&dir, "workroom_setup", &body, 0o755);
        let started = Instant::now();
        assert_eq!(
            run(&path, &dir, plain_env(), &[], Duration::from_secs(1)),
            TIMED_OUT
        );
        assert!(started.elapsed() < Duration::from_secs(10));
        let pid: i32 = std::fs::read_to_string(&pidfile)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        // An orphan is reaped by init a moment after its SIGKILL, so give that a second.
        let gone_by = Instant::now() + Duration::from_secs(1);
        // SAFETY: signal 0 only checks that the pid exists.
        while unsafe { libc::kill(pid, 0) } == 0 && Instant::now() < gone_by {
            std::thread::sleep(Duration::from_millis(20));
        }
        // SAFETY: as above.
        let alive = unsafe { libc::kill(pid, 0) } == 0;
        assert!(!alive, "the setsid grandchild {pid} survived the timeout");
    }
}
