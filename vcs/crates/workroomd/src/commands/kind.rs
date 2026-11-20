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
//! 7 no daemon could be reached, 8 a wait timed out.

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
    /// No daemon to ask: none is listening, none is named, or it predates the terminal API.
    DaemonUnreachable,
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
    /// A request, or what it sends, over the terminal API's limit.
    TooLarge,
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
    Kind::WaitTimeout,
    Kind::AgentBusy,
    Kind::NotAnAgent,
    Kind::SessionEnded,
    Kind::AlternateScreen,
    Kind::NoShellIntegration,
    Kind::TooLarge,
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
            Kind::WaitTimeout => ("WaitTimeout", 8),
            // #360: past a target, bad input and the two new codes, "anything else is 1".
            Kind::AgentBusy => ("AgentBusy", 1),
            Kind::NotAnAgent => ("NotAnAgent", 1),
            Kind::SessionEnded => ("SessionEnded", 1),
            Kind::AlternateScreen => ("AlternateScreen", 1),
            Kind::NoShellIntegration => ("NoShellIntegration", 1),
            Kind::TooLarge => ("TooLarge", 2),
            Kind::RefusedSelf => ("RefusedSelf", 1),
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
}

impl CliError {
    pub(crate) fn new(kind: Kind, message: impl Into<String>) -> CliError {
        CliError {
            kind,
            message: message.into(),
            matches: Vec::new(),
        }
    }

    /// An unclassified failure, which a usage error is too.
    pub(crate) fn internal(message: impl Into<String>) -> CliError {
        CliError::new(Kind::InternalError, message)
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
                "WaitTimeout",
                "AgentBusy",
                "NotAnAgent",
                "SessionEnded",
                "AlternateScreen",
                "NoShellIntegration",
                "TooLarge",
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

    /// #360's exit codes: a missing or ambiguous target is 3, as the CLI's other not-found errors
    /// are, and the two new codes are the daemon being out of reach and a wait timing out.
    #[test]
    fn the_terminal_apis_kinds() {
        for (kind, code, exit) in [
            (Kind::TargetAmbiguous, "TargetAmbiguous", 3),
            (Kind::TargetNotFound, "TargetNotFound", 3),
            (Kind::DaemonUnreachable, "DaemonUnreachable", 7),
            (Kind::WaitTimeout, "WaitTimeout", 8),
            (Kind::TooLarge, "TooLarge", 2),
            (Kind::InvalidRequest, "InvalidRequest", 2),
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
