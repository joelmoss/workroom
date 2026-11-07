//! The host's login environment, and what a git child on this host is given.
//!
//! The login environment is what the host user's login shell sets up in a directory, as a terminal
//! opened there would (#560), read the way the app reads the Mac user's (`ShellEnvironment.probe`):
//! one `<shell> -lic` printing `env -0` between two markers, bounded, with `WORKROOM_SHELL_PROBE=1`
//! set so an rc file can skip slow work. Any failure falls back to this process's own environment,
//! and says so. `run-script` reads it in a trusted script's directory; remote git reads it once, at
//! home, and keeps it (ADR 0063). A run session's shell is chosen by the same rule
//! (`probe_invocation`).
use std::collections::BTreeMap;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::util::lock_or_recover;

/// Shells whose `-lic` means login and interactive; anything else gets a login `/bin/sh -lc`, as
/// `ShellEnvironment.posixShells` does on the Mac. Both, and the CLI's, are tested against
/// `testdata/twins/login_shell.tsv`.
const POSIX_SHELLS: [&str; 5] = ["zsh", "bash", "sh", "dash", "ksh"];
/// The PATH the probe shell starts from, so a login shell composes its own as it would in a terminal.
const PROBE_SPAWN_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";
/// Longer than the Mac's 3 s: a host has no cached environment to fall back on, and a fresh VM's
/// first login (cold disk, nvm or conda in the rc files) can take more. A script runs once, so the
/// wait costs little.
pub(crate) const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_PROBE_BYTES: usize = 1024 * 1024;
/// The probe shell's own state, and our marker, which must not reach the script.
const DENYLIST: [&str; 5] = ["PWD", "OLDPWD", "SHLVL", "_", "WORKROOM_SHELL_PROBE"];
/// Set after the probed environment, so no rc file can revoke them.
const OVERRIDES: [(&str, &str); 2] = [("GIT_TERMINAL_PROMPT", "0"), ("GIT_OPTIONAL_LOCKS", "0")];
/// Unioned into every PATH, so a probe that returns less than a plain shell can't make it worse.
pub(crate) const FLOOR_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

/// Remote requests use this host's login environment, never the Mac's. Read it at the first remote
/// exec and keep it for this daemon's lifetime; concurrent requests share one bounded probe. Local
/// requests still use their supplied environment without reading a login profile.
static HOST_LOGIN_ENVIRONMENT: OnceLock<BTreeMap<String, String>> = OnceLock::new();
/// The serve command chooses this once, before any request threads start. Workroom's remote
/// daemons use `--idle-timeout never`; the Mac's local daemon uses the default idle lifetime and
/// keeps the environment the app supplied when it spawned it.
static READS_LOGIN_ENVIRONMENT: OnceLock<bool> = OnceLock::new();

pub(crate) fn configure_read_environment(remote: bool) {
    let _ = READS_LOGIN_ENVIRONMENT.set(remote);
}

fn cached_login_environment<'a>(
    cache: &'a OnceLock<BTreeMap<String, String>>,
    shell: &str,
    timeout: Duration,
) -> &'a BTreeMap<String, String> {
    cache.get_or_init(|| {
        // Home, never a clone: this runs unattended, for reads of directories nobody has trusted.
        let home = std::env::var_os("HOME").unwrap_or_else(|| "/".into());
        login_environment(shell, Path::new(&home), timeout, |reason| {
            crate::note!(
                "remote git: couldn't read the login shell's environment ({reason}); using the daemon's own"
            );
        })
    })
}

/// The host's login environment, read at home once and kept for this daemon's lifetime.
pub(crate) fn host_login_environment() -> &'static BTreeMap<String, String> {
    let shell = crate::terminal::shell::user_shell(std::env::var_os("SHELL"));
    cached_login_environment(&HOST_LOGIN_ENVIRONMENT, &shell, PROBE_TIMEOUT)
}

/// Read-side git children (diffs and the File service's listing) use the cached profile on a remote
/// daemon, and the app-supplied inherited environment on a local one. Both keep the existing scrub
/// and pins, without changing the daemon's own process environment. Local exec requests still use
/// their explicit client environment; remote exec requests explicitly select the login profile.
pub(crate) fn host_read_environment() -> BTreeMap<String, String> {
    if !READS_LOGIN_ENVIRONMENT.get().copied().unwrap_or(false) {
        return scrubbed_environment(std::env::vars_os())
            .into_iter()
            .collect();
    }
    host_environment(
        host_login_environment()
            .iter()
            .map(|(key, value)| (key.into(), value.into())),
        BTreeMap::new(),
    )
}

/// The git scrub and pins (`wr_vcs_git::diff::SCRUBBED`, `PINS`) over an explicit variable set, so
/// they can be tested without mutating this process's own environment — which other tests' child
/// processes inherit.
pub(crate) fn scrubbed_environment(
    vars: impl Iterator<Item = (std::ffi::OsString, std::ffi::OsString)>,
) -> Vec<(String, String)> {
    let mut env: BTreeMap<String, String> = vars
        .filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?)))
        .collect();
    env.retain(|key, _| !wr_vcs_git::diff::SCRUBBED.contains(&key.as_str()));
    for (key, value) in wr_vcs_git::diff::PINS {
        env.insert(key.into(), value.into());
    }
    env.into_iter().collect()
}

/// The child environment for a remote host: its cached login environment, with the file
/// service's scrub and pins (`scrubbed_environment`, so the two host-side paths agree), no graphical
/// prompt helper, and the request's pins on top.
///
/// ssh is kept from prompting WITHOUT setting `GIT_SSH_COMMAND`, which would outrank a repository's
/// own `core.sshCommand`, the usual home of a deploy key, and so replace the host's ssh for every
/// repository on it. It cannot prompt anyway: `SSH_ASKPASS_REQUIRE=never` rules out a helper, and a
/// supervised daemon has no terminal for one. A `GIT_SSH_COMMAND` the host sets itself is kept and
/// gets `BatchMode`, as the app does locally (`StatusCommandRunner.networkEnvironment`).
///
/// Built from `vars_os`, not `vars`, which panics on one variable that is not UTF-8 and would take
/// the exec thread down before it replied.
pub(crate) fn host_environment(
    own: impl Iterator<Item = (std::ffi::OsString, std::ffi::OsString)>,
    pins: std::collections::BTreeMap<String, String>,
) -> std::collections::BTreeMap<String, String> {
    let mut env: std::collections::BTreeMap<String, String> =
        scrubbed_environment(own).into_iter().collect();
    env.remove("SSH_ASKPASS");
    env.remove("DISPLAY");
    env.extend(pins);
    if let Some(ssh) = env
        .get("GIT_SSH_COMMAND")
        .map(|command| command.trim().to_string())
        .filter(|command| !command.is_empty())
    {
        env.insert("GIT_SSH_COMMAND".into(), format!("{ssh} -o BatchMode=yes"));
    }
    env.insert("SSH_ASKPASS_REQUIRE".into(), "never".into());
    env
}

/// One bounded read of the host's login environment in `dir`, shared by scripts and remote git. The
/// caller owns the fallback message: scripts print to the create/delete log, while the long-lived
/// daemon records it in its own log. No process-wide environment is changed.
pub(crate) fn login_environment(
    shell: &str,
    dir: &Path,
    timeout: Duration,
    on_fallback: impl FnOnce(&str),
) -> BTreeMap<String, String> {
    match probe(shell, dir, timeout) {
        Ok(probed) => merge(probed, &floor_path()),
        Err(reason) => {
            on_fallback(reason);
            fallback()
        }
    }
}

/// The shell to probe with and its flag: `shell` when it is a POSIX shell, else `/bin/sh`.
pub(crate) fn probe_invocation(shell: &str) -> (&str, &'static str) {
    let name = shell.rsplit('/').next().unwrap_or_default();
    if !shell.is_empty() && POSIX_SHELLS.contains(&name) {
        (shell, "-lic")
    } else {
        ("/bin/sh", "-lc")
    }
}

/// The login shell's environment in `dir`, or why it couldn't be read. An interactive rc can read
/// `dir`'s local tool config, so `dir` is a trusted script's or the user's home, never an unread clone.
pub fn probe(
    shell: &str,
    dir: &Path,
    timeout: Duration,
) -> Result<BTreeMap<String, String>, &'static str> {
    let marker = marker();
    let (program, shell_flag) = probe_invocation(shell);
    let line = format!("printf '%s' '{marker}'; env -0; printf '%s' '{marker}'");
    let mut command = Command::new(program);
    command
        .arg(shell_flag)
        .arg(line)
        .current_dir(dir)
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
    let stdout = child.stdout.take().expect("piped stdout");
    let output = Arc::new(Mutex::new(Vec::new()));
    let reader = {
        let output = Arc::clone(&output);
        std::thread::spawn(move || wr_exec::drain_capped(stdout, MAX_PROBE_BYTES, &output))
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
    let output = std::mem::take(&mut *lock_or_recover(&output));
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
mod tests;
