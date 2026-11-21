//! The `kind` registry: each error a command can end with, its stable PascalCase code in the
//! `--json` error envelope, and its process exit code (ADR 0013). Callers branch on the code, not
//! the message, so a code never changes once shipped.
//!
//! The Go CLI's registry (`internal/errs/errs.go`) is the source until Go retires (#682); a test
//! holds this table to it, entry by entry. `MacOnly` and `ManagedInstall` are new with the Rust
//! binary (ADR 0078).
//!
//! The terminal API's kinds are new with it too (#360, ADR 0079): the daemon replies with them by
//! code (`terminal::api::kind`), and its commands exit with them.
//!
//! Exit codes: 0 success, 1 internal, 2 usage or validation, 3 a precondition or something not
//! found, 4 cancelled, 5 a setup or teardown script failed, 6 config couldn't be read or written,
//! 7 no daemon could be reached, or the one reached is too old for the request, 8 a wait timed out.

use super::create::CreatePayload;
use super::start::LocalWorkPayload;
use super::trusted_script::ScriptPayload;

/// One failure class a command can end with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    InWorkroom,
    UnsupportedVcs,
    NotADirectory,
    InvalidName,
    DirExists,
    WorkspaceExists,
    WorkspaceNotFound,
    ConfirmationMismatch,
    UnsafeDeletePath,
    Cancelled,
    SetupScriptFailed,
    TeardownScriptFailed,
    ConfigReadFailed,
    ConfigWriteFailed,
    VcsCommandFailed,
    RemoteProjectUnsupported,
    RemoteWorkroomUnsupported,
    ProjectNotFound,
    WorkroomNotFound,
    InvalidHostDescriptor,
    WorkroomExists,
    BaseBranchNotFound,
    ScriptNotTrusted,
    LocalWorkLeftOut,
    StartCommitUnusable,
    CloneFailed,
    DestinationNotEmpty,
    /// A command that reads or writes the Mac's config, run anywhere else (a remote host).
    MacOnly,
    /// `update` in an install something else updates: the app bundle (Sparkle) or a host's
    /// daemon directory (bootstrap).
    ManagedInstall,
    /// A terminal API target that more than one session matches; the error lists them.
    TargetAmbiguous,
    /// A terminal API target that no session matches.
    TargetNotFound,
    /// No daemon to ask: none is named, or none is listening where it was.
    DaemonUnreachable,
    /// A daemon that predates the terminal API (below protocol 12): it needs updating, not
    /// starting.
    DaemonTooOld,
    /// A terminal API wait that ran out of time.
    WaitTimeout,
    /// A prompt to a coding agent that is working.
    AgentBusy,
    /// A prompt to a session with no coding agent in it.
    NotAnAgent,
    /// A session that ended before or while it was asked.
    SessionEnded,
    /// A request a full-screen program on the alternate screen can't take.
    AlternateScreen,
    /// A request that needs the shell's integration marks, in a session without them.
    NoShellIntegration,
    /// A wait for a run to exit with one code (`wait --exit-code`), which it exited with another.
    ExitCodeMismatch,
    /// A wait for output or a command's end that may have missed it: the daemon's hand-off cut
    /// across it, so what came between its two programs may have gone unmatched (the CLI says so
    /// rather than wait on), or a regex wait fell behind its session's output and the daemon
    /// dropped output it never matched.
    WaitInterrupted,
    /// A request, or what it sends, over the terminal API's limit.
    TooLarge,
    /// A daemon at its limit on concurrent work, such as captures of history: it refuses the
    /// request rather than queue it, so a script can retry once some has finished.
    Busy,
    /// Typing into, or closing, the caller's own session without the flag that allows it.
    RefusedSelf,
    /// A terminal API request the daemon can't read: no such method, or parameters it refuses.
    InvalidRequest,
    /// Anything unclassified, a usage error included.
    InternalError,
}

/// Every kind, in the registry's order.
pub(crate) const ALL: &[Kind] = &[
    Kind::InWorkroom,
    Kind::UnsupportedVcs,
    Kind::NotADirectory,
    Kind::InvalidName,
    Kind::DirExists,
    Kind::WorkspaceExists,
    Kind::WorkspaceNotFound,
    Kind::ConfirmationMismatch,
    Kind::UnsafeDeletePath,
    Kind::Cancelled,
    Kind::SetupScriptFailed,
    Kind::TeardownScriptFailed,
    Kind::ConfigReadFailed,
    Kind::ConfigWriteFailed,
    Kind::VcsCommandFailed,
    Kind::RemoteProjectUnsupported,
    Kind::RemoteWorkroomUnsupported,
    Kind::ProjectNotFound,
    Kind::WorkroomNotFound,
    Kind::InvalidHostDescriptor,
    Kind::WorkroomExists,
    Kind::BaseBranchNotFound,
    Kind::ScriptNotTrusted,
    Kind::LocalWorkLeftOut,
    Kind::StartCommitUnusable,
    Kind::CloneFailed,
    Kind::DestinationNotEmpty,
    Kind::MacOnly,
    Kind::ManagedInstall,
    Kind::TargetAmbiguous,
    Kind::TargetNotFound,
    Kind::DaemonUnreachable,
    Kind::DaemonTooOld,
    Kind::WaitTimeout,
    Kind::AgentBusy,
    Kind::NotAnAgent,
    Kind::SessionEnded,
    Kind::AlternateScreen,
    Kind::NoShellIntegration,
    Kind::ExitCodeMismatch,
    Kind::WaitInterrupted,
    Kind::TooLarge,
    Kind::Busy,
    Kind::RefusedSelf,
    Kind::InvalidRequest,
    Kind::InternalError,
];

impl Kind {
    /// The code the error envelope's `kind` carries.
    pub(crate) fn code(self) -> &'static str {
        self.entry().0
    }

    /// The kind `code` names, as the daemon's terminal API replies with it; `InternalError` for a
    /// code this build doesn't know, which a newer daemon may send.
    pub(crate) fn from_code(code: &str) -> Kind {
        ALL.iter()
            .copied()
            .find(|kind| kind.code() == code)
            .unwrap_or(Kind::InternalError)
    }

    /// The process's exit code.
    pub(crate) fn exit_code(self) -> u8 {
        self.entry().1
    }

    fn entry(self) -> (&'static str, u8) {
        match self {
            Kind::InWorkroom => ("InWorkroom", 3),
            Kind::UnsupportedVcs => ("UnsupportedVCS", 3),
            Kind::NotADirectory => ("NotADirectory", 3),
            Kind::InvalidName => ("InvalidName", 3),
            Kind::DirExists => ("DirExists", 3),
            Kind::WorkspaceExists => ("WorkspaceExists", 3),
            Kind::WorkspaceNotFound => ("WorkspaceNotFound", 3),
            Kind::ConfirmationMismatch => ("ConfirmationMismatch", 2),
            Kind::UnsafeDeletePath => ("UnsafeDeletePath", 2),
            Kind::Cancelled => ("Cancelled", 4),
            Kind::SetupScriptFailed => ("SetupScriptFailed", 5),
            Kind::TeardownScriptFailed => ("TeardownScriptFailed", 5),
            Kind::ConfigReadFailed => ("ConfigReadFailed", 6),
            Kind::ConfigWriteFailed => ("ConfigWriteFailed", 6),
            Kind::VcsCommandFailed => ("VCSCommandFailed", 1),
            Kind::RemoteProjectUnsupported => ("RemoteProjectUnsupported", 3),
            Kind::RemoteWorkroomUnsupported => ("RemoteWorkroomUnsupported", 3),
            Kind::ProjectNotFound => ("ProjectNotFound", 3),
            Kind::WorkroomNotFound => ("WorkroomNotFound", 3),
            Kind::InvalidHostDescriptor => ("InvalidHostDescriptor", 2),
            Kind::WorkroomExists => ("WorkroomExists", 3),
            Kind::BaseBranchNotFound => ("BaseBranchNotFound", 3),
            Kind::ScriptNotTrusted => ("ScriptNotTrusted", 3),
            Kind::LocalWorkLeftOut => ("LocalWorkLeftOut", 3),
            Kind::StartCommitUnusable => ("StartCommitUnusable", 3),
            Kind::CloneFailed => ("CloneFailed", 1),
            Kind::DestinationNotEmpty => ("DestinationNotEmpty", 3),
            Kind::MacOnly => ("MacOnly", 3),
            Kind::ManagedInstall => ("ManagedInstall", 3),
            Kind::TargetAmbiguous => ("TargetAmbiguous", 3),
            Kind::TargetNotFound => ("TargetNotFound", 3),
            Kind::DaemonUnreachable => ("DaemonUnreachable", 7),
            Kind::DaemonTooOld => ("DaemonTooOld", 7),
            Kind::WaitTimeout => ("WaitTimeout", 8),
            // A valid request the session can't take now: a precondition, as the CLI's others are.
            Kind::AgentBusy => ("AgentBusy", 3),
            Kind::NotAnAgent => ("NotAnAgent", 3),
            Kind::SessionEnded => ("SessionEnded", 3),
            Kind::AlternateScreen => ("AlternateScreen", 3),
            Kind::NoShellIntegration => ("NoShellIntegration", 3),
            // What was waited for happened, but not as asked: a precondition of the script's.
            Kind::ExitCodeMismatch => ("ExitCodeMismatch", 3),
            // The daemon is there, but the wait couldn't go on as asked: wait again.
            Kind::WaitInterrupted => ("WaitInterrupted", 3),
            Kind::TooLarge => ("TooLarge", 2),
            // A valid request the daemon can't take now: a precondition, as `AgentBusy` is.
            Kind::Busy => ("Busy", 3),
            Kind::RefusedSelf => ("RefusedSelf", 3),
            Kind::InvalidRequest => ("InvalidRequest", 2),
            Kind::InternalError => ("InternalError", 1),
        }
    }
}

/// How a command failed: its kind, and the message a person reads.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct CliError {
    pub(crate) kind: Kind,
    pub(crate) message: String,
    /// The sessions an ambiguous terminal API target matched, as the daemon listed them.
    pub(crate) matches: Vec<serde_json::Value>,
    /// What a terminal API error says beside its message (its `details`), such as the code an
    /// `ExitCodeMismatch` run exited with. Boxed, as most errors have none.
    pub(crate) details: Option<Box<serde_json::Value>>,
    /// The script a `ScriptNotTrusted` refused, as the envelope's `script` carries it for the app
    /// to show and approve.
    pub(crate) script: Option<Box<ScriptPayload>>,
    /// The workroom a create made before it failed (its setup script, say), as the envelope's
    /// `created` carries it, so the app can offer to delete it.
    pub(crate) created: Option<Box<CreatePayload>>,
    /// The work a `LocalWorkLeftOut` create would leave out, for the app to ask where it starts.
    pub(crate) local_work: Option<Box<LocalWorkPayload>>,
    /// The commit a create question was asked about, for the answer to pass back as
    /// `--start-commit` (ADR 0059). Boxed, as the others are, so a `Result` carrying the error
    /// stays small.
    pub(crate) start_commit: Option<Box<str>>,
}

impl CliError {
    pub(crate) fn new(kind: Kind, message: impl Into<String>) -> CliError {
        CliError {
            kind,
            message: message.into(),
            matches: Vec::new(),
            details: None,
            script: None,
            created: None,
            local_work: None,
            start_commit: None,
        }
    }

    /// An unclassified failure, which a usage error is too.
    pub(crate) fn internal(message: impl Into<String>) -> CliError {
        CliError::new(Kind::InternalError, message)
    }

    /// Go's `ErrVCSCommand`, wrapping what failed in git's or the system's words.
    pub(crate) fn vcs_failed(detail: &str) -> CliError {
        CliError::new(
            Kind::VcsCommandFailed,
            format!("version control command failed: {detail}"),
        )
    }

    /// Go's `ErrUnsupportedVCS`: the directory holds no git checkout.
    pub(crate) fn unsupported_vcs() -> CliError {
        CliError::new(
            Kind::UnsupportedVcs,
            "no supported VCS detected in this directory. Workroom requires Git to manage \
             workrooms",
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each `{ErrX, "Code", N},` entry of Go's registry, as (code, exit code).
    fn go_registry() -> Vec<(String, u8)> {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../internal/errs/errs.go"
        );
        let source = std::fs::read_to_string(path).expect("read internal/errs/errs.go");
        let start = source
            .find("var registry = []classification{")
            .expect("registry");
        let body = &source[start..source[start..].find("\n}").map(|end| start + end).unwrap()];
        body.lines()
            .filter_map(|line| {
                let entry = line.trim().strip_prefix('{')?.strip_suffix("},")?;
                let mut fields = entry.split(", ");
                let _sentinel = fields.next()?;
                let code = fields.next()?.trim_matches('"').to_string();
                let exit = fields.next()?.parse().ok()?;
                Some((code, exit))
            })
            .collect()
    }

    #[test]
    fn every_go_kind_has_the_same_code_and_exit_code_here() {
        let go = go_registry();
        assert!(
            go.len() >= 20,
            "read only {} entries from errs.go",
            go.len()
        );
        let ours: Vec<(String, u8)> = ALL
            .iter()
            .map(|kind| (kind.code().to_string(), kind.exit_code()))
            .collect();
        for entry in &go {
            assert!(
                ours.contains(entry),
                "Go's {entry:?} is missing or differs here"
            );
        }
        // Everything here that Go doesn't have is one of the Rust binary's own kinds.
        let extra: Vec<&str> = ours
            .iter()
            .filter(|entry| !go.contains(entry))
            .map(|(code, _)| code.as_str())
            .collect();
        assert_eq!(
            extra,
            [
                "MacOnly",
                "ManagedInstall",
                "TargetAmbiguous",
                "TargetNotFound",
                "DaemonUnreachable",
                "DaemonTooOld",
                "WaitTimeout",
                "AgentBusy",
                "NotAnAgent",
                "SessionEnded",
                "AlternateScreen",
                "NoShellIntegration",
                "ExitCodeMismatch",
                "WaitInterrupted",
                "TooLarge",
                "Busy",
                "RefusedSelf",
                "InvalidRequest",
                "InternalError"
            ]
        );
    }

    #[test]
    fn the_rust_binarys_own_kinds() {
        assert_eq!(Kind::MacOnly.exit_code(), 3);
        assert_eq!(Kind::ManagedInstall.exit_code(), 3);
        // Go's unclassified error: errs.Code's "InternalError", errs.ExitCode's 1.
        assert_eq!(Kind::InternalError.code(), "InternalError");
        assert_eq!(Kind::InternalError.exit_code(), 1);
    }

    /// #360's exit codes: a missing or ambiguous target, and a valid request the session can't
    /// take now, are 3, as the CLI's other not-found and precondition errors are; bad input is 2;
    /// and the new codes are the daemon being out of reach or too old (7) and a wait timing out (8).
    #[test]
    fn the_terminal_apis_kinds() {
        for (kind, code, exit) in [
            (Kind::TargetAmbiguous, "TargetAmbiguous", 3),
            (Kind::TargetNotFound, "TargetNotFound", 3),
            (Kind::AgentBusy, "AgentBusy", 3),
            (Kind::NotAnAgent, "NotAnAgent", 3),
            (Kind::SessionEnded, "SessionEnded", 3),
            (Kind::AlternateScreen, "AlternateScreen", 3),
            (Kind::NoShellIntegration, "NoShellIntegration", 3),
            (Kind::ExitCodeMismatch, "ExitCodeMismatch", 3),
            (Kind::WaitInterrupted, "WaitInterrupted", 3),
            (Kind::RefusedSelf, "RefusedSelf", 3),
            (Kind::Busy, "Busy", 3),
            (Kind::TooLarge, "TooLarge", 2),
            (Kind::InvalidRequest, "InvalidRequest", 2),
            (Kind::DaemonUnreachable, "DaemonUnreachable", 7),
            (Kind::DaemonTooOld, "DaemonTooOld", 7),
            (Kind::WaitTimeout, "WaitTimeout", 8),
        ] {
            assert_eq!((kind.code(), kind.exit_code()), (code, exit));
            assert_eq!(Kind::from_code(code), kind);
        }
        assert_eq!(Kind::from_code("SomethingNewer"), Kind::InternalError);
    }

    /// The daemon's codes are the registry's (`terminal::api::kind`), never a second spelling.
    #[test]
    fn every_code_the_daemon_replies_with_is_registered() {
        use crate::terminal::api::kind;
        for code in [
            kind::TARGET_NOT_FOUND,
            kind::TARGET_AMBIGUOUS,
            kind::INVALID_REQUEST,
            kind::TOO_LARGE,
            kind::SESSION_ENDED,
            kind::WAIT_TIMEOUT,
            kind::WAIT_INTERRUPTED,
            kind::NO_SHELL_INTEGRATION,
            kind::EXIT_CODE_MISMATCH,
            kind::BUSY,
            kind::INTERNAL_ERROR,
        ] {
            assert_eq!(Kind::from_code(code).code(), code);
        }
    }

    #[test]
    fn codes_are_unique() {
        let mut codes: Vec<&str> = ALL.iter().map(|kind| kind.code()).collect();
        codes.sort_unstable();
        let count = codes.len();
        codes.dedup();
        assert_eq!(codes.len(), count);
    }
}
