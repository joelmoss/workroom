//! A session for a remote pane attached from the Mac (ADR 0074, `AttachRequest::host_environment`).
//!
//! Its client is the Mac's own `workroomd attach`, whose environment is the Mac's: its `PATH`,
//! `HOME` and `SHELL` mean nothing here. So the client sends only the terminal type, colour support,
//! terminal program, locale and the session's metadata (`wr_protocol::terminal::
//! is_host_attach_variable`, held to again here), and the daemon builds the rest from the ssh login
//! the connection's `relay` runs in, which sent its environment in the `Peer` frame
//! (`login_environment`): its `PATH`, `HOME`, `SHELL`, `USER`, ssh variables and the rest, as sshd
//! and the system's account services (a directory service's too) gave them. Only a connection
//! with no `Peer` environment falls back to the daemon's own environment and the host user's
//! account entry, which a static lookup can get wrong. The shell is started as a login shell
//! (`shell::invocation`), so its profile runs as an ssh login's did.

use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use wr_protocol::terminal::is_host_attach_variable;

/// The terminal type a Mac pane asks for, used only when the bootstrap's terminfo is here.
const GHOSTTY_TERM: &str = "xterm-ghostty";
/// The terminal type without it.
const FALLBACK_TERM: &str = "xterm-256color";
/// Ghostty's shell integration features, as the pane's ssh login had them.
const SHELL_FEATURES: &str = "cursor,sudo,title";
/// The most a `Peer` frame's login environment may hold, encoded. `relay` leaves out what would
/// not fit, the account's own variables last, and the daemon takes no environment from a bigger
/// frame. Well under the frame cap, so the frame always encodes.
pub(crate) const MAX_PEER_ENVIRONMENT: usize = 64 * 1024;

/// The variables `relay` sends first, so a full budget leaves out something else.
const LOGIN_FIRST: [&str; 7] = [
    "HOME",
    "SHELL",
    "USER",
    "LOGNAME",
    "PATH",
    "SSH_CONNECTION",
    "SSH_CLIENT",
];

/// Whether a variable of an ssh login may reach a host session through the `Peer` frame: anything
/// but the login's terminal (the Mac's replaces it: `TERM`, `COLORTERM`, `TERM_PROGRAM*`,
/// `TERMINFO`, `GHOSTTY_*`), its ssh terminal (`SSH_TTY`: a session has none), the session's
/// metadata (`WORKROOM_SESSION_*`, the client's alone), and what each process sets for itself
/// (`PWD`, `OLDPWD`, `SHLVL`, `_`). Held to by `relay` and again by the daemon.
pub(crate) fn is_login_variable(name: &[u8]) -> bool {
    !name.is_empty()
        && !name.contains(&b'=')
        && !matches!(
            name,
            b"TERM"
                | b"COLORTERM"
                | b"TERM_PROGRAM"
                | b"TERM_PROGRAM_VERSION"
                | b"TERMINFO"
                | b"SSH_TTY"
                | b"PWD"
                | b"OLDPWD"
                | b"SHLVL"
                | b"_"
        )
        && !name.starts_with(b"GHOSTTY_")
        && !name.starts_with(b"WORKROOM_SESSION_")
}

/// The `Peer` frame's payload for an ssh login whose environment is `environment`: its login
/// variables as NUL-terminated `KEY=VALUE` entries, within `MAX_PEER_ENVIRONMENT`. None when there
/// are none.
pub(crate) fn encode_login_environment(
    environment: impl IntoIterator<Item = (OsString, OsString)>,
) -> Option<Vec<u8>> {
    let mut entries: Vec<(OsString, OsString)> = environment
        .into_iter()
        .filter(|(key, _)| is_login_variable(key.as_bytes()))
        .collect();
    // Stable, so the rest keep their order.
    entries.sort_by_key(|(key, _)| !LOGIN_FIRST.iter().any(|first| key == *first));
    let mut payload = Vec::new();
    for (key, value) in entries {
        let size = key.len() + 1 + value.len() + 1;
        if payload.len() + size > MAX_PEER_ENVIRONMENT {
            continue;
        }
        payload.extend_from_slice(key.as_bytes());
        payload.push(b'=');
        payload.extend_from_slice(value.as_bytes());
        payload.push(0);
    }
    (!payload.is_empty()).then_some(payload)
}

/// The login environment a `Peer` frame's payload carries, held to `is_login_variable`. None for a
/// payload over `MAX_PEER_ENVIRONMENT` or one with no login variables in it, which leaves the
/// connection's sessions to the account entry.
pub(crate) fn login_environment(payload: &[u8]) -> Option<Vec<(OsString, OsString)>> {
    if payload.len() > MAX_PEER_ENVIRONMENT {
        return None;
    }
    let environment: Vec<(OsString, OsString)> = payload
        .split(|byte| *byte == 0)
        .filter_map(|entry| {
            let split = entry.iter().position(|byte| *byte == b'=')?;
            let key = &entry[..split];
            is_login_variable(key).then(|| {
                (
                    OsStr::from_bytes(key).to_os_string(),
                    OsStr::from_bytes(&entry[split + 1..]).to_os_string(),
                )
            })
        })
        .collect();
    (!environment.is_empty()).then_some(environment)
}

/// What a host session is built from, besides its client's variables.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostOrigin {
    /// The daemon's own environment.
    pub environment: Vec<(OsString, OsString)>,
    /// The host user's login shell; empty when the account names none.
    pub shell: String,
    pub home: PathBuf,
    pub user: String,
}

impl HostOrigin {
    /// This process's environment and its effective user's account entry.
    fn current() -> HostOrigin {
        // SAFETY: geteuid takes nothing and cannot fail.
        let uid = unsafe { libc::geteuid() };
        let account = crate::host::account::lookup(&uid.to_string()).ok();
        HostOrigin {
            environment: std::env::vars_os().collect(),
            shell: account
                .as_ref()
                .map(|a| a.shell.clone())
                .unwrap_or_default(),
            home: account
                .as_ref()
                .map(|a| a.home.clone())
                .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
                .unwrap_or_else(|| PathBuf::from("/")),
            user: account.map(|a| a.name).unwrap_or_default(),
        }
    }
}

/// Where host sessions come from, held by the store (`session::Hooks`): the bootstrap's Ghostty
/// resources beside the daemon's socket (`keep_resources`), and, in tests, a fixed origin in place
/// of this process's own.
#[derive(Default)]
pub struct HostSource {
    resources: OnceLock<PathBuf>,
    fixed: OnceLock<HostOrigin>,
}

impl HostSource {
    /// Ghostty's resources for this daemon's sessions: `<socket's folder>/ghostty`, where the
    /// bootstrap puts them (`DaemonInstall.resources`).
    pub fn keep_resources(&self, dir: PathBuf) {
        let _ = self.resources.set(dir);
    }

    /// Builds host sessions from `origin` instead of this process's environment and account.
    #[cfg(any(test, feature = "test-support"))]
    pub fn fix(&self, origin: HostOrigin) {
        let _ = self.fixed.set(origin);
    }

    /// The session for a host-environment attach whose client sent `client`, on a connection whose
    /// relay sent `login`, its ssh login's environment (`login_environment`), if any.
    pub fn session(
        &self,
        client: &[(OsString, OsString)],
        login: Option<&[(OsString, OsString)]>,
    ) -> HostSession {
        let origin = self
            .fixed
            .get()
            .cloned()
            .unwrap_or_else(HostOrigin::current);
        build(
            client,
            login,
            &origin,
            self.resources.get().map(PathBuf::as_path),
        )
    }
}

/// What a host session runs with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostSession {
    /// The shell's environment, before `shell::invocation` adds the integration's variables.
    pub environment: Vec<(OsString, OsString)>,
    pub shell: String,
    /// Ghostty's resources for the shell integration, or empty for none.
    pub resources: String,
}

/// Variables the daemon's own environment must not hand a host session, when no ssh login's came:
/// the client's terminal replaces its terminal's, the session's metadata is the client's, and its
/// ssh variables are those of whatever login started it, not this connection's.
fn replaced(name: &OsStr) -> bool {
    let bytes = name.as_bytes();
    is_host_attach_variable(name)
        || bytes.starts_with(b"GHOSTTY_")
        || matches!(
            bytes,
            b"TERMINFO" | b"SSH_TTY" | b"SSH_CONNECTION" | b"SSH_CLIENT"
        )
        || matches!(bytes, b"HOME" | b"SHELL" | b"USER" | b"LOGNAME")
}

fn build(
    client: &[(OsString, OsString)],
    login: Option<&[(OsString, OsString)]>,
    origin: &HostOrigin,
    resources: Option<&Path>,
) -> HostSession {
    // The ssh login's, when its relay sent it: held to the login variables again, whatever built
    // it. Otherwise the daemon's own, less what an attach replaces.
    let mut environment: Vec<(OsString, OsString)> = match login {
        Some(login) => login
            .iter()
            .filter(|(key, _)| is_login_variable(key.as_bytes()))
            .cloned()
            .collect(),
        None => origin
            .environment
            .iter()
            .filter(|(key, _)| !replaced(key))
            .cloned()
            .collect(),
    };
    // The login's own `HOME`, `SHELL`, `USER` and `LOGNAME` win over the account entry, which a
    // static lookup gets wrong for a directory service's users; the entry fills in what it lacks.
    let from_login = |name: &str| {
        login?
            .iter()
            .find(|(key, value)| key == name && !value.is_empty())
            .map(|(_, value)| value.clone())
    };
    let shell = from_login("SHELL")
        .map(|shell| shell.to_string_lossy().into_owned())
        .or_else(|| (!origin.shell.is_empty()).then(|| origin.shell.clone()))
        .unwrap_or_else(|| crate::terminal::shell::POSIX_SHELL.to_string());
    let home = from_login("HOME").unwrap_or_else(|| origin.home.clone().into_os_string());
    let user = from_login("USER")
        .or_else(|| (!origin.user.is_empty()).then(|| OsString::from(&origin.user)));
    let logname = from_login("LOGNAME").or_else(|| user.clone());
    let mut set = |key: &str, value: OsString| {
        environment.retain(|(existing, _)| existing != key);
        environment.push((OsString::from(key), value));
    };
    set("HOME", home);
    set("SHELL", OsString::from(&shell));
    if let Some(user) = user {
        set("USER", user);
    }
    if let Some(logname) = logname {
        set("LOGNAME", logname);
    }
    for (key, value) in client {
        // The session's metadata is read from the request, never handed to its shell.
        if is_host_attach_variable(key) && !key.as_bytes().starts_with(b"WORKROOM_SESSION_") {
            set(&key.to_string_lossy(), value.clone());
        }
    }

    let asks_for_ghostty = client
        .iter()
        .any(|(key, value)| key == "TERM" && value == GHOSTTY_TERM);
    let terminfo = resources
        .map(|dir| dir.join("terminfo"))
        .filter(|terminfo| is_readable(&terminfo.join("x").join(GHOSTTY_TERM)));
    let mut session_resources = String::new();
    if asks_for_ghostty {
        match (terminfo, resources) {
            (Some(terminfo), Some(resources)) => {
                set("TERMINFO", terminfo.into_os_string());
                set("GHOSTTY_SHELL_FEATURES", OsString::from(SHELL_FEATURES));
                session_resources = resources.to_string_lossy().into_owned();
            }
            _ => set("TERM", OsString::from(FALLBACK_TERM)),
        }
    }
    HostSession {
        environment,
        shell,
        resources: session_resources,
    }
}

/// Whether this process can read `path`, as the attach script's `test -r` asked.
fn is_readable(path: &Path) -> bool {
    std::fs::File::open(path).is_ok()
}
