//! Program resume (ADR 0082): what a session's programs have reported, over the Program Resume
//! Protocol (OSC 7577, <https://www.superlogical.com/rex/docs/build/program-resume>), about how
//! to start them again, kept per session as its **resume record**. A pane whose session is gone
//! resumes from the record the app saved, which the daemon runs in the new session (`launch`,
//! #825).
//!
//! **Who may report.** Every interactive session gets its own random token in `OSC7577_TOKEN`
//! when it starts. A report counts only when its `mac` is made with that token, its `time` is
//! within a minute of the daemon's clock and not older than its owner's last accepted report, and
//! its owner (`pid`) is alive, run by the daemon's own user, and under the session's first process.
//! There are no per-program rules (ADR 0082): a process that can forge that already runs as the
//! user. A daemon running as root gives no session a token, so it accepts nothing.
//!
//! **One record per owner, one shown.** Herdr's model: every pid that has reported has an
//! `OwnerSlot` (its last accepted `time` and stream offset, and its record if it has one). The session's record
//! is chosen from the records whose owner runs under no other record's owner, and is the one among
//! them that reported last: so a program's own child that reports does not displace it.
//!
//! **When a record goes.** A `clear=1` report from its owner clears it, as does a newer accepted
//! report replacing it. A report from its owner that is rejected (authenticated, but malformed, or
//! from an owner that fails its check) removes it: the spec has a rejection remove every record
//! its owner has, and a pid here has one. Its owner exiting while the session's shell runs on
//! clears it once the owner has been gone for `EXIT_GRACE` (`watch_owners`). The session ending,
//! its tab closed or its daemon or host gone, takes the whole state with it; the app keeps the
//! record it last saw for a session that ended any way but its tab being closed (#824).
//!
//! The decisions in `apply`, the owner check and the exit grace (`check_exit`, `watch_owners`,
//! both now in `owners`) are ported from herdr-core (herdrdev/herdr-core#429, `crates/herdr-core/src/resume.rs` at
//! `0cb50d57832f3ebb69157ce7f023fbbc520181a8`), Licensed under the Apache License, Version 2.0
//! (`resume/LICENSE`). Changed from the original for Workroom: the state is a session's, not a
//! kept terminal's; each report's outcome is returned so the daemon can log why one did not count;
//! the record carries when it was reported; the grace runs on a monotonic clock and a hand-off
//! starts it again rather than carrying it; an owner that can't be read counts as gone, since
//! `process::identity` doesn't tell that from an exit; a record is never cleared while the
//! session's own shell is gone, which stands in for herdr's check that the terminal is healthy;
//! each record that clears is returned for the daemon's log; the helper's report of a resumed
//! record says its program started, and its exit, which the helper reports too, can say it
//! failed to resume, and the shell's own clear with `workroomhook=1` says Workroom's hook loaded
//! in it, each an `Event` of one resume lifecycle (`Resuming::decide`); launching is `launch`'s;
//! the reasons a report does not count are one `Reason`, and the owner check returns it;
//! `Word` is `OwnerSlot`, and the state a hand-off carries is `Carried` itself, its JSON
//! unchanged but for a resume that waits for its helper, which it carries too (`CarriedWaiting`);
//! the token is `token`'s; and there is no rapid-loss guard, since a program that fails at once
//! exits, which clears its record.

pub mod launch;
mod owners;
mod protocol;
mod token;

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::terminal::process::{Identity, Image};
use owners::{Checked, check_owner};
pub(crate) use owners::{Watch, foreground_process, watch_owners};
use protocol::{Action, Stream};
use token::daemon_user;
pub(crate) use token::{daemon_accepts_reports, give_token, scrub};

/// The environment variable a session's token is in.
pub(crate) const TOKEN_VARIABLE: &str = "OSC7577_TOKEN";

/// What an attach that creates a session sets, to `OFF`, when the app's "Resume programs after a
/// restart" is off (#827): that session gets no token, so it accepts no reports, and the attach's
/// record, if any, is not run. Per session, not the daemon's: the daemon is shared by every Mac
/// and app build. Absent is on, as for an older app or a `workroom attach` someone typed.
pub const SETTING_VARIABLE: &str = "WORKROOM_SESSION_PROGRAM_RESUME";

/// `SETTING_VARIABLE`'s value that turns resume off.
pub const OFF: &str = "off";

/// Whether an attach's environment leaves its session's programs able to resume
/// (`SETTING_VARIABLE`): any value but `OFF` is on.
pub fn turned_on(env: &[(OsString, OsString)]) -> bool {
    !env.iter()
        .any(|(key, value)| key == SETTING_VARIABLE && value == OFF)
}

/// How long a record's owner must stay gone, while its session's shell runs on, before the record
/// clears. At logout or shutdown a program can exit just before its session does, and the spec
/// would have that record kept; it says a second or two is enough.
pub(crate) const EXIT_GRACE: Duration = Duration::from_secs(2);

/// The most pids one session tracks at once. A report from a new pid past it is not accepted.
const MAX_OWNERS: usize = 256;

/// One process by pid and start time, so a reused pid is a different owner.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Owner {
    pub pid: u32,
    pub start: u64,
}

impl From<Identity> for Owner {
    fn from(identity: Identity) -> Owner {
        Owner {
            pid: identity.pid,
            start: identity.start,
        }
    }
}

/// One owner's record: what it reported, and what its check found of it. The session's resume
/// record is one of these (`Resume::choice`).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct OwnerRecord {
    owner: Owner,
    /// The owner's parents, up to and including the session's first process.
    ancestors: Vec<Owner>,
    argv: Vec<String>,
    reported_cwd: Option<String>,
    /// The owner's own folder when the report was accepted, for a report with no `cwd`.
    owner_cwd: Option<String>,
    /// The report's `time`, in Unix seconds.
    reported_at: u64,
    /// When a look first found its owner gone (`check_exit`), until it is back or the grace has
    /// passed. Not carried: the next program starts the grace again.
    #[serde(skip)]
    gone_since: Option<Instant>,
}

/// What one pid that has reported holds: the guards against a replayed or older report, and its
/// record, if it has one.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct OwnerSlot {
    /// The last accepted report's `time`: an older one is not accepted.
    time: u64,
    /// The stream offset just past the last report, accepted or not: a report at or before it is a
    /// replay.
    offset: u64,
    record: Option<OwnerRecord>,
}

/// A session's resume record as the terminal API shows it (`Whole::redacted`): never the
/// arguments, which can hold secrets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Redacted {
    /// The program the record starts (`program_name`).
    pub program: String,
    /// Where it starts: the folder it reported, else its own when it reported.
    pub cwd: Option<String>,
    /// When it reported, in milliseconds since the Unix epoch, as the terminal API gives times.
    pub reported_at_ms: u64,
}

/// A session's resume record whole, as the app saves it in the tab's saved-layout entry (#824):
/// the command with its arguments, which can hold secrets, so only the app's own ProgramStatus
/// service carries it (`program_status::Store::set_resume`), never the terminal API.
#[derive(Clone, PartialEq, Eq)]
pub struct Whole {
    /// The command, as reported.
    pub argv: Vec<String>,
    /// Where it starts: the folder it reported, else its own when it reported.
    pub cwd: Option<String>,
    /// When it reported, in milliseconds since the Unix epoch.
    pub reported_at_ms: u64,
}

impl Whole {
    /// The record as the terminal API shows it: its program, never its arguments.
    pub(crate) fn redacted(self) -> Redacted {
        Redacted {
            program: program_name(&self.argv),
            cwd: self.cwd,
            reported_at_ms: self.reported_at_ms,
        }
    }
}

impl std::fmt::Debug for Whole {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The arguments can hold secrets: only the program is printed.
        write!(f, "Whole({})", program_name(&self.argv))
    }
}

/// A session's resume state as its `Session` and reader share it: `None` for a session given no
/// token.
pub(crate) type SharedResume = std::sync::Arc<std::sync::Mutex<Option<Resume>>>;

/// What one report did, for the daemon's log. `program` is what the report would start, when it
/// got as far as saying.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Outcome {
    Accepted {
        program: String,
    },
    Cleared,
    NotAccepted {
        reason: Reason,
        program: Option<String>,
    },
    /// The record this session was started to resume (#825) was reported by its helper, and
    /// accepted: the program starts now.
    ResumeStarted {
        program: String,
    },
    /// The program this session resumed (#825) could not start, or exited with an error within
    /// `launch::FAILED_WITHIN` of starting: it could not be resumed.
    ResumeFailed {
        program: String,
        status: i32,
    },
    /// The session's shell said, as Workroom's hook loaded in it (`launch::run_hook`), that the
    /// hook runs there: a resume it waits for is not declined at a prompt or a deadline, unless
    /// `exec` replaced the shell (`Decline::stands`).
    HookLoaded,
}

/// Where a session started to resume a record (#825) is with it: one lifecycle, moved on only by
/// `Resuming::decide`, whose table is the whole of it.
///
/// ```text
/// Waiting(Unhooked) ── HookLoaded ──────────────────────────────▶ Waiting(Hooked)
/// Waiting ─────────── Reported, by its helper ──────────────────▶ Started
/// Waiting ─────────── Exited, a failure ────────────────────────▶ Failed
/// Started ─────────── Exited, a failure within FAILED_WITHIN ───▶ Failed
/// Waiting, Started ── Exited, otherwise ────────────────────────▶ Ended
/// Waiting ─────────── Claimed, its launch file a decline's ─────▶ Declined
/// ```
///
/// `Prompt` and `Tick` move nothing: they say whether to decline it (`Decision::Decline`), which
/// takes reading processes and claiming its launch file with every lock released, and only the
/// claim, once it is the daemon's, declines it (`Claimed`). `Failed`, `Ended` and `Declined` end
/// it: nothing moves any of them on.
#[derive(Clone)]
enum Resuming {
    Waiting(Waiting),
    /// Its helper's report was accepted at `at`: the program started then.
    Started {
        program: String,
        at: Instant,
    },
    Failed,
    Ended,
    Declined,
}

/// A resume whose helper has not yet reported the record, whose command and folder these are,
/// from the launch file `file` this daemon (or the one before it, for a hand-off) wrote for it at
/// `since`.
#[derive(Clone)]
struct Waiting {
    program: String,
    argv: Vec<String>,
    cwd: Option<String>,
    /// When the record was reported, as the session's status gives it until the helper reports.
    reported_at_ms: u64,
    file: std::path::PathBuf,
    since: Instant,
    /// Whether the shell said its Workroom hook loaded (`Event::HookLoaded`).
    hook: Hook,
    /// The file the session's shell was started from, when it is known (`process::image_of`).
    shell: Option<Image>,
}

/// Whether a waiting resume's shell said Workroom's hook loaded in it.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Hook {
    Unhooked,
    Hooked,
}

/// A waiting resume as a hand-off carries it (`Carried::waiting`), so the next program goes on
/// waiting, declining or starting it as this one would have: `Waiting`, with how long it had
/// waited in place of its `Instant`, which means nothing to another process, so `DECLINE_AFTER`
/// still counts from the session's start.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct CarriedWaiting {
    argv: Vec<String>,
    cwd: Option<String>,
    reported_at_ms: u64,
    /// Its launch file's path. A table is JSON, so a path that is not UTF-8 is not carried, and
    /// nor is its resume: the next program then resumes nothing, as one before this field did.
    file: String,
    waited_ms: u64,
    hooked: bool,
    shell: Option<Image>,
}

impl std::fmt::Debug for CarriedWaiting {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The arguments can hold secrets: only the program is printed.
        write!(f, "CarriedWaiting({})", program_name(&self.argv))
    }
}

impl Waiting {
    /// What a hand-off at `now` carries of it; `None` for a launch file whose path is not UTF-8.
    fn carried(&self, now: Instant) -> Option<CarriedWaiting> {
        Some(CarriedWaiting {
            argv: self.argv.clone(),
            cwd: self.cwd.clone(),
            reported_at_ms: self.reported_at_ms,
            file: self.file.to_str()?.to_string(),
            waited_ms: u64::try_from(now.saturating_duration_since(self.since).as_millis())
                .unwrap_or(u64::MAX),
            hooked: self.hook == Hook::Hooked,
            shell: self.shell,
        })
    }

    /// The resume a hand-off carried, adopted at `now`: it has waited as long as it had.
    fn adopted(carried: CarriedWaiting, now: Instant) -> Waiting {
        Waiting {
            program: program_name(&carried.argv),
            argv: carried.argv,
            cwd: carried.cwd,
            reported_at_ms: carried.reported_at_ms,
            file: carried.file.into(),
            since: now
                .checked_sub(Duration::from_millis(carried.waited_ms))
                .unwrap_or(now),
            hook: if carried.hooked {
                Hook::Hooked
            } else {
                Hook::Unhooked
            },
            shell: carried.shell,
        }
    }
}

/// What happens to a session's resume (#825), as `Resume::decide` reads it.
pub(crate) enum Event<'a> {
    /// The shell said Workroom's hook loaded in it (`protocol::workroom_hook`).
    HookLoaded,
    /// `record` was accepted, read at `at`.
    Reported {
        record: &'a OwnerRecord,
        at: Instant,
    },
    /// A resumed program's exit with `status`, read at `at` (`protocol::workroom_exit`).
    Exited { status: i32, at: Instant },
    /// A read brought the shell's prompt (OSC 133).
    Prompt,
    /// The screens tick, at its instant.
    Tick(Instant),
    /// The daemon claimed the launch file a `Decision::Decline` named (`launch::claim`).
    Claimed,
}

/// What an `Event` decided of a session's resume.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Decision {
    /// Its helper reported it, so the program starts now (`Outcome::ResumeStarted`), and runs as
    /// `launched`.
    Started {
        program: String,
        launched: Option<Launched>,
    },
    /// It could not be resumed (`Outcome::ResumeFailed`).
    Failed { program: String, status: i32 },
    /// Nothing to decline yet: the tick looks at it again.
    Wait,
    /// Decline it, when it stands (`Decline::stands`) and its launch file is claimed.
    Decline(Decline),
    /// It was declined, so `program` will not start.
    Declined { program: String },
}

/// How long after its session started a resume whose helper has not reported is declined
/// (`Event::Tick`), when its shell never said Workroom's hook loaded in it: for a shell that
/// skipped the hook and whose prompt sends no OSC 133, which would decline it at once
/// (`Event::Prompt`). A shell whose hook loaded is declined this way only once `exec` has
/// replaced it (`Decline::stands`), never however long its startup files take (an `ssh-add`
/// passphrase answered minutes later). Long enough for a login shell on a cold disk after a
/// reboot, with every restored pane's shell starting at once (oh-my-zsh and nvm can take 10 s
/// there), before it reaches the hook; a hook that loads later than this finds its file claimed
/// and starts nothing, so the outcome is the one the app was told either way.
pub(crate) const DECLINE_AFTER: Duration = Duration::from_secs(30);

/// A resume whose helper has not reported (#825), to decline at its shell's first prompt or at
/// `DECLINE_AFTER`: while the shell has not said Workroom's hook loaded in it, it is declined
/// there. Once the hook loaded, a prompt before it ran (Powerlevel10k's instant prompt prints one
/// from the top of `.zshrc`) or a startup file that waits (a passphrase) is no sign it won't run,
/// so the resume waits for the helper for as long as the session lives, unless `exec` replaced
/// the shell (a `.zshrc` that ends in `exec tmux` or `exec fish`). A hook that loads and then
/// never reaches the first prompt in the shell it was started as (a `.zshrc` that resets
/// `precmd_functions`, or `exec`s the same shell again) is the accepted cost: nothing declines
/// it, so the app keeps the record and tries it again at each restart, its own fallback saying
/// each time that the pane got a new shell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Decline {
    /// Its launch file: the one path a decline claims (`launch::claim`).
    pub file: std::path::PathBuf,
    /// Why it is declined, for the daemon's log.
    pub why: Why,
    /// The session's first process and the file its shell was started from, when both are known.
    root: Option<Owner>,
    shell: Option<Image>,
}

impl Decline {
    /// Whether it is declined now, with `image` (`process::image`) and `lookup`
    /// (`process::identity`) for the session's first process: at once when its shell never said
    /// Workroom's hook loaded, as such a shell skipped it. One whose hook loaded only on proof that
    /// `exec` replaced the shell before the hook could run (a `.zshrc` that ends in `exec tmux` or
    /// `exec fish`): the first process runs a file now, read, that is not the one its shell was
    /// started from, and is still that process, by pid and start time, once the file was read. A
    /// pid is not reused before its process is reaped, which only the session's end does, and no
    /// later process has its start time, so the file read was that process's. `exec` keeps both,
    /// and nothing but `exec` changes what a process runs. Anything unknown or unread declines
    /// nothing: the resume waits, as one whose hook loaded always did.
    pub(crate) fn stands(
        &self,
        image: impl Fn(u32) -> Option<Image>,
        lookup: impl Fn(u32) -> Option<Identity>,
    ) -> bool {
        if self.why != Why::ExecReplaced {
            return true;
        }
        let (Some(root), Some(shell)) = (self.root, self.shell) else {
            return false;
        };
        image(root.pid).is_some_and(|now| now != shell)
            && lookup(root.pid).map(Owner::from) == Some(root)
    }

    /// Whether the tick looks at it again when it does not stand, or its launch file is not
    /// claimed: one whose shell never said its hook loaded is looked at every tick; one whose
    /// hook loaded owes no look after its deadline, and is declined there, or at any later tick
    /// something else wakes, once `exec` has replaced its shell.
    pub(crate) fn looked_at_again(&self) -> bool {
        self.why != Why::ExecReplaced
    }
}

/// Why a resume was declined (`Decline`), as the daemon's log says it (`as_str`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Why {
    /// At its shell's first prompt, from a shell that never said its hook loaded.
    PromptFirst,
    /// At `DECLINE_AFTER`, from a shell that never said its hook loaded.
    NoHook,
    /// From a shell whose hook loaded, once `exec` replaced it.
    ExecReplaced,
}

impl Why {
    /// The reason as the daemon's log says it.
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Why::PromptFirst => {
                "its shell's first prompt came before its helper reported, so it ran no \
                 Workroom hook"
            }
            Why::NoHook => "its shell never loaded Workroom's hook, and its helper never reported",
            Why::ExecReplaced => {
                "its shell loaded Workroom's hook, then exec replaced the shell before its \
                 helper ran"
            }
        }
    }
}

impl Resuming {
    /// What `event` decides, in a session whose first process is `root`, and the state it moves
    /// this resume on to (the table on `Resuming`).
    fn decide(&mut self, root: Option<Owner>, event: Event<'_>) -> Option<Decision> {
        let soon = |started: Instant, at: Instant| {
            at.saturating_duration_since(started) < launch::FAILED_WITHIN
        };
        let (next, decision) = match (&mut *self, event) {
            (Resuming::Waiting(waiting), Event::HookLoaded) => {
                waiting.hook = Hook::Hooked;
                (None, None)
            }
            (Resuming::Waiting(waiting), Event::Reported { record, at })
                if record.argv == waiting.argv && record.reported_cwd == waiting.cwd =>
            {
                let program = waiting.program.clone();
                (
                    Some(Resuming::Started {
                        program: program.clone(),
                        at,
                    }),
                    Some(Decision::Started {
                        program,
                        launched: Launched::of(record),
                    }),
                )
            }
            (Resuming::Waiting(waiting), Event::Exited { status, .. })
                if launch::failed(status) =>
            {
                let program = waiting.program.clone();
                (
                    Some(Resuming::Failed),
                    Some(Decision::Failed { program, status }),
                )
            }
            (Resuming::Started { program, at }, Event::Exited { status, at: exited })
                if launch::failed(status) && soon(*at, exited) =>
            {
                let program = program.clone();
                (
                    Some(Resuming::Failed),
                    Some(Decision::Failed { program, status }),
                )
            }
            (Resuming::Waiting(_) | Resuming::Started { .. }, Event::Exited { .. }) => {
                (Some(Resuming::Ended), None)
            }
            (Resuming::Waiting(waiting), Event::Prompt) => (
                None,
                Some(Decision::Decline(waiting.decline(root, Why::PromptFirst))),
            ),
            (Resuming::Waiting(waiting), Event::Tick(now))
                if now.saturating_duration_since(waiting.since) < DECLINE_AFTER =>
            {
                (None, Some(Decision::Wait))
            }
            (Resuming::Waiting(waiting), Event::Tick(_)) => (
                None,
                Some(Decision::Decline(waiting.decline(root, Why::NoHook))),
            ),
            (Resuming::Waiting(waiting), Event::Claimed) => {
                let program = waiting.program.clone();
                (
                    Some(Resuming::Declined),
                    Some(Decision::Declined { program }),
                )
            }
            _ => (None, None),
        };
        if let Some(next) = next {
            *self = next;
        }
        decision
    }
}

impl Waiting {
    /// Its decline, `why` it is when its shell never said its hook loaded, in a session whose
    /// first process is `root`.
    fn decline(&self, root: Option<Owner>, why: Why) -> Decline {
        Decline {
            file: self.file.clone(),
            why: match self.hook {
                Hook::Unhooked => why,
                Hook::Hooked => Why::ExecReplaced,
            },
            root,
            shell: self.shell,
        }
    }
}

/// The resumed program and its helper, by pid and start time, once the program's report was
/// accepted (#825): the shell made the helper its job's process group leader, so the pty's
/// foreground group names the helper, and `foreground_process` names the program instead.
/// Carried by a hand-off, as the program runs on through it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Launched {
    helper: Owner,
    program: Owner,
}

impl Launched {
    /// The helper's report of its program's `record`: its owner is the helper's child, so its
    /// parent, the first of its ancestors, is the helper.
    fn of(record: &OwnerRecord) -> Option<Launched> {
        Some(Launched {
            helper: *record.ancestors.first()?,
            program: record.owner,
        })
    }
}

/// Why a report did not count (`Outcome::NotAccepted`), as the daemon's log names it
/// (`as_str`). `BadMac`, `StaleTime` and `NoPid` ignore it (`protocol::authenticate`), and
/// `Replayed` and `TooManyOwners` refuse it, all leaving its owner as it was; the rest reject
/// an authenticated report, which removes its owner's record (`Resume::apply`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Reason {
    /// No `mac`, or one that doesn't match the session's token.
    BadMac,
    /// A `time` outside the window, or not a number.
    StaleTime,
    /// No valid `pid`.
    NoPid,
    /// At or before its owner's last report in the stream, or older than its last accepted one.
    Replayed,
    /// From a pid not yet tracked, with `MAX_OWNERS` tracked already.
    TooManyOwners,
    /// Its owner is gone, a zombie, or can't be read (`check_owner`).
    OwnerGone,
    /// Its owner runs as another user.
    OtherUser,
    /// Its owner is not under the session's first process.
    NotDescendant,
    /// Authenticated, but malformed, or asking for something this terminal does not support.
    Malformed,
}

impl Reason {
    /// The reason as the daemon's log says it.
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Reason::BadMac => "bad_mac",
            Reason::StaleTime => "stale_time",
            Reason::NoPid => "no_pid",
            Reason::Replayed => "replayed",
            Reason::TooManyOwners => "too_many_owners",
            Reason::OwnerGone => "owner_gone",
            Reason::OtherUser => "other_user",
            Reason::NotDescendant => "not_descendant",
            Reason::Malformed => "malformed",
        }
    }
}

/// One session's resume state: what a hand-off carries of it, where its scanner is, and the
/// record it was started to resume.
#[derive(Clone)]
pub(crate) struct Resume {
    /// Its token, its first process, what its programs reported and how far into its output they
    /// were read: all a hand-off carries, as it carries it (`carried`).
    carried: Carried,
    /// Where the scanner is inside a report it has not finished: not carried, so the next program
    /// starts outside any, at the offset carried.
    stream: Stream,
    /// The record this session was started to resume (#825), until its program has ended or been
    /// running for long: its failure is said only within `launch::FAILED_WITHIN` of its start.
    /// A hand-off carries it while it waits for its helper (`Carried::waiting`), which can be
    /// minutes (a startup passphrase); once started it is not carried, as its failure window is
    /// seconds and its helper and program are carried in `Carried::launched`.
    resuming: Option<Resuming>,
}

impl std::fmt::Debug for Resume {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The token makes records, and a record's arguments can hold secrets: neither is printed.
        f.write_str("Resume([private])")
    }
}

/// What a hand-off carries of a session's resume state (`daemon::handoff`, table version 6), and
/// what a live session keeps of it (`Resume::carried`). The shell keeps its token across the
/// hand-off, so the next program must check reports with the same one, and go on from the same
/// stream offset so a report after it is not a replay. Its JSON is the table's: a field's name,
/// order and default are the table's format.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Carried {
    token: String,
    /// The daemon's user, whose processes alone may report.
    uid: u32,
    /// The session's first process, once it is known (`Resume::set_root`).
    root: Option<Owner>,
    /// Every pid that has reported.
    #[serde(rename = "words")]
    slots: BTreeMap<u32, OwnerSlot>,
    /// How many bytes of the session's output have been scanned for reports.
    offset: u64,
    /// The resumed program and its helper, once it started (`foreground_process`); absent from a
    /// table this field predates.
    #[serde(default)]
    launched: Option<Launched>,
    /// The resume this session was started for, while its helper has not reported
    /// (`Resume::carried`): set only in the state a hand-off carries, and taken out again as the
    /// next program adopts it (`Resume::adopted`), so a live session's is always `None`. Absent
    /// from a table this field predates, and from one with no resume waiting, so such a table's
    /// JSON is as it was.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    waiting: Option<CarriedWaiting>,
}

impl std::fmt::Debug for Carried {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Carried([private])")
    }
}

#[cfg(test)]
impl Carried {
    /// A carried state with `token` and one record, as far into its stream as `offset`, for
    /// tests outside this module.
    pub(crate) fn for_test(token: &str, offset: u64) -> Carried {
        let owner = Owner {
            pid: 4242,
            start: 1,
        };
        Carried {
            token: token.into(),
            uid: 501,
            root: Some(owner),
            slots: BTreeMap::from([(
                4242,
                OwnerSlot {
                    time: 1_795_543_200,
                    offset,
                    record: Some(OwnerRecord {
                        owner,
                        // The session's first process itself: no parents up to itself, as
                        // `check_owner` finds for it.
                        ancestors: Vec::new(),
                        argv: vec!["claude".into(), "--resume".into(), "a-session".into()],
                        reported_cwd: Some("/work".into()),
                        owner_cwd: None,
                        reported_at: 1_795_543_200,
                        gone_since: None,
                    }),
                },
            )]),
            offset,
            launched: None,
            waiting: None,
        }
    }

    /// What a hand-off carries of a session with `token` started to resume `record` from the
    /// launch file `file`, whose helper has not reported, for tests outside this module.
    #[cfg(feature = "terminal-state")]
    pub(crate) fn waiting_for_test(token: &str, record: &Whole, file: &str) -> Carried {
        let mut resume = Resume::with_token(token.into(), 501);
        resume.resuming(record, file.into(), None);
        resume.carried()
    }
}

impl Resume {
    /// A new session's state, for the token its environment was given (`give_token`), or `None`
    /// when it was given none.
    pub(crate) fn for_session(environment: &[(OsString, OsString)]) -> Option<Resume> {
        let token = environment
            .iter()
            .rev()
            .find(|(key, _)| key == TOKEN_VARIABLE)?
            .1
            .to_str()?
            .to_string();
        let uid = daemon_user()?;
        Some(Resume::with_token(token, uid))
    }

    fn with_token(token: String, uid: u32) -> Resume {
        Resume::adopted(Carried {
            token,
            uid,
            root: None,
            slots: BTreeMap::new(),
            offset: 0,
            launched: None,
            waiting: None,
        })
    }

    /// This session was started to resume `record` (#825), which its helper will report, from the
    /// launch file this daemon wrote at `file`, its shell started from the file `shell` when that
    /// is known (`process::image_of`).
    pub(crate) fn resuming(
        &mut self,
        record: &Whole,
        file: std::path::PathBuf,
        shell: Option<Image>,
    ) {
        self.resuming = Some(Resuming::Waiting(Waiting {
            program: program_name(&record.argv),
            argv: record.argv.clone(),
            cwd: record.cwd.clone(),
            reported_at_ms: record.reported_at_ms,
            file,
            since: Instant::now(),
            hook: Hook::Unhooked,
            shell,
        }));
    }

    /// The resume whose helper has not reported (#825), if there is one.
    fn waiting(&self) -> Option<&Waiting> {
        match &self.resuming {
            Some(Resuming::Waiting(waiting)) => Some(waiting),
            _ => None,
        }
    }

    /// The launch file of a resume whose helper has not reported (#825): the one path a decline
    /// claims (`launch::claim`), and a session's end removes.
    pub(crate) fn waiting_file(&self) -> Option<std::path::PathBuf> {
        self.waiting().map(|waiting| waiting.file.clone())
    }

    /// What `event` decides of the resume this session was started for (`Resuming::decide`),
    /// `None` for a session that resumes nothing.
    pub(crate) fn decide(&mut self, event: Event<'_>) -> Option<Decision> {
        self.resuming.as_mut()?.decide(self.carried.root, event)
    }

    /// The token the session's shell was given in `TOKEN_VARIABLE`.
    #[cfg(test)]
    pub(crate) fn token(&self) -> &str {
        &self.carried.token
    }

    /// Records the session's first process, once its shell has started.
    pub(crate) fn set_root(&mut self, pid: i32) {
        if self.carried.root.is_none()
            && let Ok(pid) = u32::try_from(pid)
            && let Some(identity) = crate::terminal::process::identity(pid)
            && identity.uid == self.carried.uid
        {
            self.carried.root = Some(identity.into());
        }
    }

    /// Every report `bytes` (raw pty output) completes, applied, with what each did.
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> Vec<Outcome> {
        let reports = self.stream.feed(&mut self.carried.offset, bytes);
        if reports.is_empty() {
            return Vec::new();
        }
        let now = crate::util::unix_seconds().unwrap_or(0);
        let at = Instant::now();
        let (root, uid) = (self.carried.root, self.carried.uid);
        reports
            .into_iter()
            .map(|(offset, body)| {
                let outcome = self.apply(offset, &body, now, |pid| {
                    check_owner(root, uid, pid, crate::terminal::process::identity)
                });
                self.after(outcome, offset, &body, at)
            })
            .collect()
    }

    /// What the report applied at `offset` did, once read at `at` for the record this session
    /// resumes: its helper's report starting it, its exit (`protocol::workroom_exit`) in a clear,
    /// or the shell's hook loading (`protocol::workroom_hook`) in one.
    /// A resumed program's failure is said once, when it failed before it started or within
    /// `launch::FAILED_WITHIN` of starting; its start, once, when the record accepted is the one
    /// the session waits for its helper to report. The hook's word is said whether or not a resume
    /// waits for it.
    fn after(&mut self, outcome: Outcome, offset: u64, body: &[u8], at: Instant) -> Outcome {
        let event = match &outcome {
            Outcome::Cleared => match protocol::workroom_exit(body) {
                Some(status) => Event::Exited { status, at },
                None if protocol::workroom_hook(body) => Event::HookLoaded,
                None => return outcome,
            },
            // Only while a resume waits for its helper is the accepted record looked for.
            Outcome::Accepted { .. } if self.waiting().is_some() => {
                let Some(record) = self
                    .carried
                    .slots
                    .values()
                    .find(|slot| slot.offset == offset)
                    .and_then(|slot| slot.record.as_ref())
                else {
                    return outcome;
                };
                Event::Reported { record, at }
            }
            _ => return outcome,
        };
        let hook = matches!(event, Event::HookLoaded);
        let decided = match self.resuming.as_mut() {
            Some(resuming) => resuming.decide(self.carried.root, event),
            None => None,
        };
        match decided {
            Some(Decision::Started { program, launched }) => {
                self.carried.launched = launched;
                Outcome::ResumeStarted { program }
            }
            Some(Decision::Failed { program, status }) => Outcome::ResumeFailed { program, status },
            _ if hook => Outcome::HookLoaded,
            _ => outcome,
        }
    }

    /// Applies one report body found at `offset`, checking its owner with `find_owner`.
    fn apply(
        &mut self,
        offset: u64,
        body: &[u8],
        now: u64,
        find_owner: impl FnOnce(u32) -> Result<Checked, Reason>,
    ) -> Outcome {
        let report = protocol::authenticate(body, &self.carried.token, now);
        let program = match &report {
            Ok(protocol::Report {
                action: Some(Action::Set { argv, .. }),
                ..
            }) => Some(program_name(argv)),
            _ => None,
        };
        let applied = match report {
            Ok(report) => self.take(offset, report, now, find_owner),
            Err(reason) => Err(reason),
        };
        match applied {
            Ok(Some(_)) => Outcome::Accepted {
                program: program.unwrap_or_default(),
            },
            Ok(None) => Outcome::Cleared,
            Err(reason) => Outcome::NotAccepted { reason, program },
        }
    }

    /// Takes one authenticated `report` found at `offset` into its owner's slot: the record it
    /// sets, `None` for a clear, or why it does not count.
    fn take(
        &mut self,
        offset: u64,
        report: protocol::Report,
        now: u64,
        find_owner: impl FnOnce(u32) -> Result<Checked, Reason>,
    ) -> Result<Option<&OwnerRecord>, Reason> {
        let slots = &mut self.carried.slots;
        // A pid that never got a record is forgotten a minute after it last reported.
        slots.retain(|_, slot| {
            slot.record.is_some() || now.saturating_sub(slot.time) <= protocol::WINDOW_SECONDS
        });
        let previous = slots.get(&report.pid);
        if let Some(slot) = previous
            && (offset <= slot.offset || report.time < slot.time)
        {
            return Err(Reason::Replayed);
        }
        if previous.is_none() && slots.len() >= MAX_OWNERS {
            return Err(Reason::TooManyOwners);
        }
        let previous_time = previous.map_or(0, |slot| slot.time);
        let record = match report.action {
            Some(Action::Set { argv, cwd }) => find_owner(report.pid).map(|checked| {
                Some(OwnerRecord {
                    owner: checked.owner,
                    ancestors: checked.ancestors,
                    argv,
                    reported_cwd: cwd,
                    owner_cwd: checked.cwd,
                    reported_at: report.time,
                    gone_since: None,
                })
            }),
            Some(Action::Clear) => Ok(None),
            // Authenticated and malformed: rejected, which removes every record the owner has, and
            // a pid has one.
            None => Err(Reason::Malformed),
        };
        // Only an accepted report moves the owner's time on; a rejection still removes its record.
        let (time, record, taken) = match record {
            Ok(record) => (report.time, record, Ok(())),
            Err(reason) => (previous_time, None, Err(reason)),
        };
        slots.insert(
            report.pid,
            OwnerSlot {
                time,
                offset,
                record,
            },
        );
        taken.map(|()| slots.get(&report.pid)?.record.as_ref())
    }

    /// Every owner's record.
    fn records(&self) -> impl Iterator<Item = &OwnerRecord> {
        self.carried
            .slots
            .values()
            .filter_map(|slot| slot.record.as_ref())
    }

    /// The record the session would resume from: among the records whose owner runs under no other
    /// record's owner, the one that reported last.
    fn choice(&self) -> Option<&OwnerRecord> {
        let records = || {
            self.carried
                .slots
                .values()
                .filter_map(|slot| Some((slot.offset, slot.record.as_ref()?)))
        };
        records()
            .filter(|(_, record)| {
                !records().any(|(_, other)| record.ancestors.contains(&other.owner))
            })
            .max_by_key(|(offset, _)| *offset)
            .map(|(_, record)| record)
    }

    /// The session's resume record, as the terminal API shows it.
    pub(crate) fn redacted(&self) -> Option<Redacted> {
        self.whole().map(Whole::redacted)
    }

    /// The session's resume record whole, arguments and all, for the app alone (#824).
    pub(crate) fn whole(&self) -> Option<Whole> {
        self.choice().map(|record| Whole {
            argv: record.argv.clone(),
            cwd: record
                .reported_cwd
                .clone()
                .or_else(|| record.owner_cwd.clone()),
            reported_at_ms: record.reported_at.saturating_mul(1000),
        })
    }

    /// The record the session's status gives the app: its own (`whole`), else, while a resume
    /// waits for its helper, the record it was started to resume, which the status was seeded
    /// with (`SessionStore::resuming`), so the app keeps it. What a hand-off's next program
    /// restores (`program_status::Store::restore_resume`).
    pub(crate) fn shown(&self) -> Option<Whole> {
        self.whole().or_else(|| {
            self.waiting().map(|waiting| Whole {
                argv: waiting.argv.clone(),
                cwd: waiting.cwd.clone(),
                reported_at_ms: waiting.reported_at_ms,
            })
        })
    }

    /// What a hand-off carries of this state: with a resume that waits for its helper, as long as
    /// it has waited (`CarriedWaiting`).
    pub(crate) fn carried(&self) -> Carried {
        Carried {
            waiting: self
                .waiting()
                .and_then(|waiting| waiting.carried(Instant::now())),
            ..self.carried.clone()
        }
    }

    /// The state a hand-off carried, going on from where its stream stopped, outside any report,
    /// and waiting for a resume's helper as the program before did, from the same start.
    pub(crate) fn adopted(mut carried: Carried) -> Resume {
        let now = Instant::now();
        let resuming = carried
            .waiting
            .take()
            .map(|waiting| Resuming::Waiting(Waiting::adopted(waiting, now)));
        Resume {
            carried,
            stream: Stream::default(),
            resuming,
        }
    }
}

/// The program a command starts, by its short name: the basename of `argv[0]`, or, for one that
/// starts with `env` (`env CLAUDE_CONFIG_DIR=… claude --resume …`, ADR 0082), of the first word
/// past `env`'s own options and assignments.
pub(crate) fn program_name(argv: &[String]) -> String {
    let base = |word: &str| {
        std::path::Path::new(word)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(word)
            .to_string()
    };
    let Some(first) = argv.first() else {
        return String::new();
    };
    if base(first) == "env"
        && let Some(command) = argv[1..]
            .iter()
            .find(|word| !word.starts_with('-') && !word.contains('='))
    {
        return base(command);
    }
    base(first)
}

#[cfg(test)]
mod tests;
