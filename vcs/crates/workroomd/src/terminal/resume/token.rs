//! A session's resume token (ADR 0082): who may have one, making a new one, and keeping one out
//! of the processes that must not report for it.

use std::ffi::OsString;

use super::TOKEN_VARIABLE;

/// The daemon's user, whose processes alone may report, or `None` when it runs as root or setuid:
/// such a daemon accepts no reports (ADR 0082).
pub(super) fn daemon_user() -> Option<u32> {
    let euid = crate::util::euid();
    // SAFETY: getuid takes nothing and cannot fail.
    let uid = unsafe { libc::getuid() };
    (euid != 0 && euid == uid).then_some(euid)
}

/// Whether this daemon accepts reports at all (`daemon_user`): a root one gives no session a
/// token, so no session of its resumes either, and a remote pane's gone session stays ended
/// (#826).
pub(crate) fn daemon_accepts_reports() -> bool {
    daemon_user().is_some()
}

/// Why a new session gets no token (`new_token`).
enum NoToken {
    /// The daemon accepts no reports (`daemon_user`).
    Root,
    /// The system's randomness failed.
    Randomness,
}

/// A new random token for an interactive session's `TOKEN_VARIABLE`, or why there is none: that
/// session then gets no token, never a predictable one.
fn new_token() -> Result<String, NoToken> {
    daemon_user().ok_or(NoToken::Root)?;
    crate::util::random_hex(16).ok_or(NoToken::Randomness)
}

/// Gives a new session's environment its own token, or none, in place of any it was forwarded:
/// a token from the pane an attach client was typed in belongs to that pane (ADR 0082). None for
/// a session that isn't `interactive`, or whose app turned resume off (`resumes`, #827).
pub(crate) fn give_token(
    environment: &mut Vec<(OsString, OsString)>,
    interactive: bool,
    resumes: bool,
) {
    environment.retain(|(key, _)| key != TOKEN_VARIABLE);
    if !interactive || !resumes {
        return;
    }
    match new_token() {
        Ok(token) => environment.push((TOKEN_VARIABLE.into(), token.into())),
        Err(NoToken::Root) => {
            // Said once: every shell of a root daemon is refused the same way.
            static SAID: std::sync::Once = std::sync::Once::new();
            SAID.call_once(|| {
                crate::note!(
                    "resume: this daemon runs as root, so no session accepts reports (root)"
                )
            });
        }
        Err(NoToken::Randomness) => {
            crate::note!("resume: no token for a new session: the system's randomness failed")
        }
    }
}

/// Keeps a pane's resume token out of a process the daemon starts that isn't a session's shell
/// (`workroom exec`, the daemon itself, an attach client's fallback shell): a token in the
/// environment it was handed belongs to another pane, and nothing it runs may report for it
/// (ADR 0082).
pub(crate) fn scrub(command: &mut std::process::Command) {
    command.env_remove(TOKEN_VARIABLE);
}
