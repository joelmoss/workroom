//! The `kind` registry: each error a command can end with, its stable PascalCase code in the
//! `--json` error envelope, and its process exit code (ADR 0013). Callers branch on the code, not
//! the message, so a code never changes once shipped.
//!
//! The retired Go CLI's registry shipped first; a test holds this table to its codes, entry by
//! entry. `MacOnly` and `ManagedInstall` are new with the Rust binary (ADR 0078).
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
    /// A daemon that predates the terminal API (below protocol 12), or what a command asked of it
    /// (`sessions --clients`): it needs updating, not starting.
    DaemonTooOld,
    /// A terminal API wait that ran out of time.
    WaitTimeout,
    /// A prompt to a coding agent that is working.
    AgentBusy,
    /// A prompt to a session with no coding agent in it.
    NotAnAgent,
    /// A run control (`run-control`) for a session that is no run session.
    NotARun,
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
    Kind::NotARun,
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
            Kind::NotARun => ("NotARun", 3),
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

    /// Whether the kind is new with the Rust binary (ADR 0078), which no stable release has yet,
    /// so its row in the docs is marked Nightly while `commands::docs` says that binary is.
    #[cfg(test)]
    pub(crate) fn new_with_the_rust_binary(self) -> bool {
        matches!(self, Kind::MacOnly | Kind::ManagedInstall)
    }

    /// What the docs say the kind means, and which of their tables it is in: the error kinds of
    /// `docs-site/pages/reference/json-output.md`, which `make docs-cli` writes from this
    /// (`commands::docs::kinds`). A match with no wildcard, so no kind can be added without them.
    #[cfg(test)]
    pub(crate) fn documented(self) -> (Table, &'static str) {
        use Table::{TerminalApi, Workroom};
        match self {
            Kind::InWorkroom => (
                Workroom,
                "The command ran from inside an existing workroom.",
            ),
            Kind::UnsupportedVcs => (Workroom, "No Git repository was found."),
            Kind::NotADirectory => (Workroom, "The path exists but is not a directory."),
            Kind::InvalidName => (Workroom, "The workroom name failed validation."),
            Kind::DirExists => (Workroom, "The target directory already exists."),
            Kind::WorkspaceExists => (Workroom, "The Git worktree already exists."),
            Kind::WorkspaceNotFound => (
                Workroom,
                "The Git worktree to delete doesn't exist. In the Nightly, also when the \
                 workroom's folder isn't a worktree Git registers for the project, so its \
                 teardown script won't run there.",
            ),
            Kind::ConfirmationMismatch => (
                Workroom,
                "`--confirm` didn't match the workroom's name.",
            ),
            Kind::UnsafeDeletePath => (
                Workroom,
                "Workroom refused to delete an unsafe or reserved path.",
            ),
            Kind::Cancelled => (Workroom, "The user aborted, or there was nothing to do."),
            Kind::SetupScriptFailed => (Workroom, "The setup script returned non-zero."),
            Kind::TeardownScriptFailed => (Workroom, "The teardown script returned non-zero."),
            Kind::ConfigReadFailed => (
                Workroom,
                "The config file could not be read or parsed.",
            ),
            Kind::ConfigWriteFailed => (
                Workroom,
                "The config file could not be written. After `add-project --clone`, the message \
                 says the clone is at the path but not registered; the clone is kept.",
            ),
            Kind::VcsCommandFailed => (Workroom, "An underlying `git` command failed."),
            Kind::RemoteProjectUnsupported => (
                Workroom,
                "`add-project` was given a remote path such as `host:path` or `ssh://…`.",
            ),
            Kind::RemoteWorkroomUnsupported => (
                Workroom,
                "`delete` or `delete-project` was asked to act on a remote workroom.",
            ),
            Kind::ProjectNotFound => (Workroom, "The project is not registered."),
            Kind::WorkroomNotFound => (Workroom, "The workroom is not registered."),
            Kind::InvalidHostDescriptor => (
                Workroom,
                "A host descriptor must be a JSON object.",
            ),
            Kind::WorkroomExists => (
                Workroom,
                "A workroom of that name is already registered.",
            ),
            Kind::BaseBranchNotFound => (
                Workroom,
                "A base branch exists neither on its remote nor locally, or the fetch that \
                 checks the remote failed.",
            ),
            Kind::ScriptNotTrusted => (
                Workroom,
                "A setup or teardown script this Mac has not approved.",
            ),
            Kind::LocalWorkLeftOut => (
                Workroom,
                "`create --start ask` found unpushed commits on your local base branch, or \
                 uncommitted changes on it, that the new workroom would leave out. Nothing was \
                 created. The envelope's `local_work` carries `branch`, `remote`, `ahead` (the \
                 commits not pushed), `behind` (the remote's commits the local branch lacks), \
                 `uncommitted`, `summary` and `behind_note` (a sentence saying it is behind, or \
                 `\"\"`); create again with `--start origin`, `local` or `local-with-changes`. \
                 `trust status` reports the same `local_work` when there is some.",
            ),
            Kind::StartCommitUnusable => (
                Workroom,
                "A create answering an earlier one's question was given a `start_commit` that \
                 is no longer where it starts, as when the project's base branch changed in \
                 between. Nothing was created; create again without it.",
            ),
            Kind::CloneFailed => (
                Workroom,
                "`add-project --clone` could not clone the repository. The message carries \
                 git's own error, such as `Permission denied (publickey).`; git never prompts, so \
                 missing credentials fail here. Nothing was registered.",
            ),
            Kind::DestinationNotEmpty => (
                Workroom,
                "`add-project --clone` was given a folder that already has files in it, or the \
                 folder gained files while the clone ran. No clone is left behind. Hidden \
                 staging that a crashed clone on this machine left is removed first and doesn't \
                 count. When only clone staging (`.clone-*` folders and `.clone-*.lock` files) \
                 is in the way, the message names it.",
            ),
            Kind::MacOnly => (
                Workroom,
                "A command that reads or writes the Mac's Workroom config, such as `create` or \
                 `list`, ran somewhere other than a Mac, such as a remote host.",
            ),
            Kind::ManagedInstall => (
                Workroom,
                "`update` ran in an install something else keeps up to date: the copy inside \
                 the Workroom app, the daemon the app installed on a host, or the daemon's own \
                 copy that its terminals run. Update the app instead; a host gets each newer \
                 build when the app connects.",
            ),
            Kind::TargetAmbiguous => (
                TerminalApi,
                "More than one terminal matches the target, so nothing was done.",
            ),
            Kind::TargetNotFound => (TerminalApi, "No terminal matches the target."),
            Kind::DaemonUnreachable => (
                TerminalApi,
                "No daemon answers: the command ran outside a Workroom terminal, or \
                 `WORKROOM_DAEMON` names a socket nothing listens on.",
            ),
            Kind::DaemonTooOld => (
                TerminalApi,
                "The daemon is older than the command needs. Run \
                 `\"$WORKROOM_DAEMON.bin/path/workroom\"`, the one that matches it. If that says \
                 so too, the daemon needs updating, which updating the app does.",
            ),
            Kind::WaitTimeout => (
                TerminalApi,
                "The `--timeout` passed before what was waited for happened.",
            ),
            Kind::AgentBusy => (
                TerminalApi,
                "The coding agent is working or waiting on a question, so the prompt wasn't \
                 given. `error.details` says whether the text was typed but not submitted.",
            ),
            Kind::NotAnAgent => (TerminalApi, "No coding agent runs in the terminal."),
            Kind::NotARun => (
                TerminalApi,
                "`run-control` named a terminal that is no run tab.",
            ),
            Kind::SessionEnded => (
                TerminalApi,
                "The terminal ended before or while it was asked.",
            ),
            Kind::AlternateScreen => (
                TerminalApi,
                "A full-screen program is up in the terminal.",
            ),
            Kind::NoShellIntegration => (
                TerminalApi,
                "The terminal's shell sends no shell integration marks, so a command's end can't \
                 be seen.",
            ),
            Kind::ExitCodeMismatch => (
                TerminalApi,
                "`wait --run exited --exit-code N` saw the run exit with another code, which \
                 `error.details.exit_code` holds.",
            ),
            Kind::WaitInterrupted => (
                TerminalApi,
                "A wait for output or a command's end may have missed it: the app updated the \
                 daemon in the middle, or the output came faster than the wait could read it.",
            ),
            Kind::TooLarge => (
                TerminalApi,
                "The request, or what it asked for, is more than one request or reply carries.",
            ),
            Kind::Busy => (
                TerminalApi,
                "The terminal or the daemon is busy, such as a shell running another command, \
                 so try again shortly.",
            ),
            Kind::RefusedSelf => (
                TerminalApi,
                "The command named the terminal it runs in. Pass `--allow-self` to allow it.",
            ),
            Kind::InvalidRequest => (
                TerminalApi,
                "The daemon couldn't read the request: an unknown method, or parameters it \
                 refuses.",
            ),
            Kind::InternalError => (Workroom, "Anything else."),
        }
    }
}

/// Which table of the docs' error kinds a kind is in (`Kind::documented`).
#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Table {
    /// The kinds every command may end with: the workroom lifecycle's and the CLI's own.
    Workroom,
    /// The kinds of the commands that drive terminals, the terminal API's (ADR 0079).
    TerminalApi,
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
    /// What a failed create says beside its message. Boxed, as most errors have none, so a
    /// `Result` carrying the error stays small.
    pub(crate) create: Option<Box<CreateDetails>>,
}

/// What the envelope of a failed `create` carries for the app, beside the error.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct CreateDetails {
    /// The workroom a create made before it failed (its setup script, say), as the envelope's
    /// `created` carries it, so the app can offer to delete it.
    pub(crate) created: Option<CreatePayload>,
    /// The work a `LocalWorkLeftOut` create would leave out, for the app to ask where it starts.
    pub(crate) local_work: Option<LocalWorkPayload>,
    /// The commit a create question was asked about, for the answer to pass back as
    /// `--start-commit` (ADR 0059).
    pub(crate) start_commit: Option<String>,
}

impl CliError {
    pub(crate) fn new(kind: Kind, message: impl Into<String>) -> CliError {
        CliError {
            kind,
            message: message.into(),
            matches: Vec::new(),
            details: None,
            script: None,
            create: None,
        }
    }

    /// [`CliError::create`], made empty when the error has none yet.
    pub(crate) fn create_details(&mut self) -> &mut CreateDetails {
        self.create.get_or_insert_default()
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

    /// The retired Go CLI's registry (`internal/errs/errs.go` until #682), as (code, exit code):
    /// shipped codes, which callers branch on, so frozen here.
    const SHIPPED_BY_GO: &[(&str, u8)] = &[
        ("InWorkroom", 3),
        ("UnsupportedVCS", 3),
        ("NotADirectory", 3),
        ("InvalidName", 3),
        ("DirExists", 3),
        ("WorkspaceExists", 3),
        ("WorkspaceNotFound", 3),
        ("ConfirmationMismatch", 2),
        ("UnsafeDeletePath", 2),
        ("Cancelled", 4),
        ("SetupScriptFailed", 5),
        ("TeardownScriptFailed", 5),
        ("ConfigReadFailed", 6),
        ("ConfigWriteFailed", 6),
        ("VCSCommandFailed", 1),
        ("RemoteProjectUnsupported", 3),
        ("RemoteWorkroomUnsupported", 3),
        ("ProjectNotFound", 3),
        ("WorkroomNotFound", 3),
        ("InvalidHostDescriptor", 2),
        ("WorkroomExists", 3),
        ("BaseBranchNotFound", 3),
        ("ScriptNotTrusted", 3),
        ("LocalWorkLeftOut", 3),
        ("StartCommitUnusable", 3),
        ("CloneFailed", 1),
        ("DestinationNotEmpty", 3),
    ];

    #[test]
    fn every_go_kind_has_the_same_code_and_exit_code_here() {
        let go: Vec<(String, u8)> = SHIPPED_BY_GO
            .iter()
            .map(|(code, exit)| (code.to_string(), *exit))
            .collect();
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
        // Everything here that Go doesn't have is one of the Rust binary's own kinds, each with the
        // exit code it shipped with, frozen as Go's are.
        let extra: Vec<(&str, u8)> = ours
            .iter()
            .filter(|entry| !go.contains(entry))
            .map(|(code, exit)| (code.as_str(), *exit))
            .collect();
        assert_eq!(
            extra,
            [
                ("MacOnly", 3),
                ("ManagedInstall", 3),
                ("TargetAmbiguous", 3),
                ("TargetNotFound", 3),
                ("DaemonUnreachable", 7),
                ("DaemonTooOld", 7),
                ("WaitTimeout", 8),
                ("AgentBusy", 3),
                ("NotAnAgent", 3),
                ("NotARun", 3),
                ("SessionEnded", 3),
                ("AlternateScreen", 3),
                ("NoShellIntegration", 3),
                ("ExitCodeMismatch", 3),
                ("WaitInterrupted", 3),
                ("TooLarge", 2),
                ("Busy", 3),
                ("RefusedSelf", 3),
                ("InvalidRequest", 2),
                ("InternalError", 1),
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
            (Kind::NotARun, "NotARun", 3),
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
            kind::NOT_A_RUN,
            kind::NOT_A_DIRECTORY,
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
