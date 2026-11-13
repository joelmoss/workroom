//! A session for a remote pane attached from the Mac (ADR 0074, `AttachRequest::host_environment`).
//!
//! Its client is the Mac's own `workroomd attach`, whose environment is the Mac's: its `PATH`,
//! `HOME` and `SHELL` mean nothing here. So the client sends only the terminal type, colour support,
//! terminal program, locale and the session's metadata (`wr_protocol::terminal::
//! is_host_attach_variable`, held to again here), and the daemon builds the rest, as an ssh login
//! would have: its own environment, the host user's account entry (shell, `HOME`, `USER`,
//! `LOGNAME`), and the ssh variables `relay` passed on for this connection. The shell is started
//! as a login shell (`shell::invocation`), so its profile sets `PATH`.

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
/// The ssh variables `relay` passes on (the `Peer` frame), and the only ones a connection may set.
pub(crate) const PEER_VARIABLES: [&str; 2] = ["SSH_CONNECTION", "SSH_CLIENT"];

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
    /// relay passed `peer`.
    pub fn session(
        &self,
        client: &[(OsString, OsString)],
        peer: &[(OsString, OsString)],
    ) -> HostSession {
        let origin = self
            .fixed
            .get()
            .cloned()
            .unwrap_or_else(HostOrigin::current);
        build(
            client,
            peer,
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

/// Variables the daemon's own environment must not hand a host session: the client's terminal
/// replaces its terminal's, the session's metadata is the client's, and its ssh variables are those
/// of whatever login started it, not this connection's.
fn replaced(name: &OsStr) -> bool {
    let bytes = name.as_bytes();
    is_host_attach_variable(name)
        || bytes.starts_with(b"GHOSTTY_")
        || matches!(
            bytes,
            b"TERMINFO" | b"SSH_TTY" | b"SSH_CONNECTION" | b"SSH_CLIENT" | b"SSH_AUTH_SOCK"
        )
        || matches!(bytes, b"HOME" | b"SHELL" | b"USER" | b"LOGNAME")
}

fn build(
    client: &[(OsString, OsString)],
    peer: &[(OsString, OsString)],
    origin: &HostOrigin,
    resources: Option<&Path>,
) -> HostSession {
    let shell = if origin.shell.is_empty() {
        crate::terminal::shell::POSIX_SHELL.to_string()
    } else {
        origin.shell.clone()
    };
    let mut environment: Vec<(OsString, OsString)> = origin
        .environment
        .iter()
        .filter(|(key, _)| !replaced(key))
        .cloned()
        .collect();
    let mut set = |key: &str, value: OsString| {
        environment.retain(|(existing, _)| existing != key);
        environment.push((OsString::from(key), value));
    };
    set("HOME", origin.home.clone().into_os_string());
    set("SHELL", OsString::from(&shell));
    if !origin.user.is_empty() {
        set("USER", OsString::from(&origin.user));
        set("LOGNAME", OsString::from(&origin.user));
    }
    for (key, value) in client {
        // The session's metadata is read from the request, never handed to its shell.
        if is_host_attach_variable(key) && !key.as_bytes().starts_with(b"WORKROOM_SESSION_") {
            set(&key.to_string_lossy(), value.clone());
        }
    }
    for (key, value) in peer {
        if PEER_VARIABLES.iter().any(|name| key == name) {
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
