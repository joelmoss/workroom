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
//! **One record per owner, one shown.** Herdr's model: every pid that has reported has a `Word`
//! (its last accepted `time` and stream offset, and its record if it has one). The session's record
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
//! The decisions in `apply`, the owner check and the exit grace (`check_exit`, `watch_owners`) are
//! ported from herdr-core (herdrdev/herdr-core#429, `crates/herdr-core/src/resume.rs` at
//! `0cb50d57832f3ebb69157ce7f023fbbc520181a8`), Licensed under the Apache License, Version 2.0
//! (`resume/LICENSE`). Changed from the original for Workroom: the state is a session's, not a
//! kept terminal's; each report's outcome is returned so the daemon can log why one did not count;
//! the record carries when it was reported; the grace runs on a monotonic clock and a hand-off
//! starts it again rather than carrying it; an owner that can't be read counts as gone, since
//! `process::identity` doesn't tell that from an exit; a record is never cleared while the
//! session's own shell is gone, which stands in for herdr's check that the terminal is healthy;
//! each record that clears is returned for the daemon's log; the helper's report of a resumed
//! record says its program started (`started`), and its exit, which the helper reports too, can
//! say it failed to resume (`exited`); the shell's own clear with `workroomhook=1` says Workroom's
//! hook loaded in it (`hook_loaded`); launching is `launch`'s;
//! and there is no rapid-loss guard, since a program that fails at once exits, which clears its
//! record.

pub mod launch;
mod protocol;

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::terminal::process::Identity;
use protocol::{Action, Ignored, Stream};

/// The environment variable a session's token is in.
pub(crate) const TOKEN_VARIABLE: &str = "OSC7577_TOKEN";

/// How long a record's owner must stay gone, while its session's shell runs on, before the record
/// clears. At logout or shutdown a program can exit just before its session does, and the spec
/// would have that record kept; it says a second or two is enough.
pub(crate) const EXIT_GRACE: Duration = Duration::from_secs(2);

/// The most pids one session tracks at once. A report from a new pid past it is not accepted.
const MAX_OWNERS: usize = 256;

/// The most parents the owner check walks from an owner to the session's first process.
const MAX_ANCESTORS: usize = 128;

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

#[derive(Clone, PartialEq, Serialize, Deserialize)]
struct Record {
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

#[derive(Clone, PartialEq, Serialize, Deserialize)]
struct Word {
    /// The last accepted report's `time`: an older one is not accepted.
    time: u64,
    /// The stream offset just past the last report, accepted or not: a report at or before it is a
    /// replay.
    offset: u64,
    record: Option<Record>,
}

/// A session's resume record as the terminal API shows it: never the arguments, which can hold
/// secrets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recorded {
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
        reason: &'static str,
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
    /// hook runs there: a resume it waits for is not declined at a prompt or a deadline.
    HookLoaded,
}

/// Where a session started to resume a record (#825) is with it.
#[derive(Clone, Debug)]
enum Resuming {
    /// Its helper has not yet reported the record, whose command and folder these are, from the
    /// launch file `file` this daemon wrote for it at `since`. `hooked` once the shell said its
    /// Workroom hook loaded (`Outcome::HookLoaded`).
    Waiting {
        program: String,
        argv: Vec<String>,
        cwd: Option<String>,
        file: std::path::PathBuf,
        since: Instant,
        hooked: bool,
    },
    /// Its helper's report was accepted at `at`: the program started then.
    Started { program: String, at: Instant },
}

/// How long after its session started a resume whose helper has not reported is declined
/// (`Resume::overdue`), when its shell never said Workroom's hook loaded in it: for a shell that
/// skipped the hook and whose prompt sends no OSC 133, which would decline it at once
/// (`Resume::unhooked_file`). A shell whose hook loaded is never declined this way, however long
/// its startup files take (an `ssh-add` passphrase answered minutes later). Long enough for a
/// login shell on a cold disk after a reboot, with every restored pane's shell starting at once
/// (oh-my-zsh and nvm can take 10 s there), before it reaches the hook; a hook that loads later
/// than this finds its file claimed and starts nothing, so the outcome is the one the app was told
/// either way.
pub(crate) const DECLINE_AFTER: Duration = Duration::from_secs(30);

/// The resumed program and its helper, by pid and start time, once the program's report was
/// accepted (#825): the shell made the helper its job's process group leader, so the pty's
/// foreground group names the helper, and `foreground_process` names the program instead.
/// Carried by a hand-off, as the program runs on through it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Launched {
    helper: Owner,
    program: Owner,
}

/// What one look at a record's owner did (`Resume::check_exit`).
#[derive(Debug, Clone, PartialEq, Eq)]
enum Exit {
    /// Nothing: the owner runs, its grace has not passed, or the record is another owner's now.
    Unchanged,
    /// The owner was found gone, which starts its grace.
    Gone,
    /// The owner was found running again before its grace passed.
    Back,
    /// The owner stayed gone for the grace, so its record, which started `program`, cleared.
    Cleared { program: String },
}

/// Why an owner check failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NotOwner {
    /// The owner is gone, a zombie, or can't be read.
    Gone,
    /// It runs as another user.
    OtherUser,
    /// It is not under the session's first process.
    NotDescendant,
}

impl NotOwner {
    fn reason(self) -> &'static str {
        match self {
            NotOwner::Gone => "owner_gone",
            NotOwner::OtherUser => "other_user",
            NotOwner::NotDescendant => "not_descendant",
        }
    }
}

/// An owner that passed its check.
pub(crate) struct Checked {
    owner: Owner,
    ancestors: Vec<Owner>,
    cwd: Option<String>,
}

/// One session's resume state: its token, its first process, and what its programs reported.
#[derive(Clone)]
pub(crate) struct Resume {
    token: String,
    /// The daemon's user, whose processes alone may report.
    uid: u32,
    /// The session's first process, once it is known (`set_root`).
    root: Option<Owner>,
    words: BTreeMap<u32, Word>,
    stream: Stream,
    /// The record this session was started to resume (#825), until its program has ended or been
    /// running for long: its failure is said only within `launch::FAILED_WITHIN` of its start.
    /// Not carried by a hand-off, which outlasts that.
    resuming: Option<Resuming>,
    /// The resumed program and its helper, once it started (`foreground_process`).
    launched: Option<Launched>,
}

impl std::fmt::Debug for Resume {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The token makes records, and a record's arguments can hold secrets: neither is printed.
        f.write_str("Resume([private])")
    }
}

/// What a hand-off carries of a session's resume state (`daemon::handoff`, table version 6). The
/// shell keeps its token across the hand-off, so the next program must check reports with the
/// same one, and go on from the same stream offset so a report after it is not a replay.
#[derive(Clone, Serialize, Deserialize)]
pub struct Carried {
    token: String,
    uid: u32,
    root: Option<Owner>,
    words: BTreeMap<u32, Word>,
    offset: u64,
    /// `Resume::launched`; absent from a table this field predates.
    #[serde(default)]
    launched: Option<Launched>,
}

impl std::fmt::Debug for Carried {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Carried([private])")
    }
}

impl PartialEq for Carried {
    fn eq(&self, other: &Carried) -> bool {
        self.token == other.token
            && self.uid == other.uid
            && self.root == other.root
            && self.words == other.words
            && self.offset == other.offset
            && self.launched == other.launched
    }
}

impl Eq for Carried {}

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
            words: BTreeMap::from([(
                4242,
                Word {
                    time: 1_795_543_200,
                    offset,
                    record: Some(Record {
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
        }
    }
}

impl Resume {
    /// A new session's state, for the token its environment was given (`new_token`), or `None`
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
        Resume {
            token,
            uid,
            root: None,
            words: BTreeMap::new(),
            stream: Stream::default(),
            resuming: None,
            launched: None,
        }
    }

    /// This session was started to resume `record` (#825), which its helper will report, from the
    /// launch file this daemon wrote at `file`.
    pub(crate) fn resuming(&mut self, record: &Whole, file: std::path::PathBuf) {
        self.resuming = Some(Resuming::Waiting {
            program: program_name(&record.argv),
            argv: record.argv.clone(),
            cwd: record.cwd.clone(),
            file,
            since: Instant::now(),
            hooked: false,
        });
    }

    /// The launch file of a resume whose helper has not reported (#825): the one path a decline
    /// claims (`launch::claim`), and a session's end removes.
    pub(crate) fn waiting_file(&self) -> Option<std::path::PathBuf> {
        match &self.resuming {
            Some(Resuming::Waiting { file, .. }) => Some(file.clone()),
            _ => None,
        }
    }

    /// `waiting_file`, while the shell has not said Workroom's hook loaded in it: only such a
    /// resume is declined at the shell's first prompt or at `DECLINE_AFTER`. Once the hook loaded,
    /// a prompt before it ran (Powerlevel10k's instant prompt prints one from the top of
    /// `.zshrc`) or a startup file that waits (a passphrase) is no sign it won't run, so the
    /// resume waits for the helper for as long as the session lives. A hook that loads and then
    /// never reaches the first prompt (a `.zshrc` that ends in `exec fish`, or that resets
    /// `precmd_functions`) is the accepted cost: nothing declines it, so the app keeps the record
    /// and tries it again at each restart, its own fallback saying each time that the pane got a
    /// new shell.
    pub(crate) fn unhooked_file(&self) -> Option<std::path::PathBuf> {
        match &self.resuming {
            Some(Resuming::Waiting {
                file,
                hooked: false,
                ..
            }) => Some(file.clone()),
            _ => None,
        }
    }

    /// `unhooked_file`, once it has waited `DECLINE_AFTER` at `now`.
    pub(crate) fn overdue(&self, now: Instant) -> Option<std::path::PathBuf> {
        match &self.resuming {
            Some(Resuming::Waiting {
                file,
                since,
                hooked: false,
                ..
            }) if now.saturating_duration_since(*since) >= DECLINE_AFTER => Some(file.clone()),
            _ => None,
        }
    }

    /// The session's shell said Workroom's hook loaded in it (`Outcome::HookLoaded`): a resume it
    /// waits for is no longer declined at a prompt or a deadline (`unhooked_file`).
    fn hook_loaded(&mut self) -> Outcome {
        if let Some(Resuming::Waiting { hooked, .. }) = &mut self.resuming {
            *hooked = true;
        }
        Outcome::HookLoaded
    }

    /// The resume still waiting is declined, its launch file claimed by the daemon: the program it
    /// would have started, `None` when it is not waiting any more.
    pub(crate) fn decline(&mut self) -> Option<String> {
        match self.resuming.take() {
            Some(Resuming::Waiting { program, .. }) => Some(program),
            other => {
                self.resuming = other;
                None
            }
        }
    }

    /// The resumed program and its helper, once it started, for `foreground_process`.
    fn launched(&self) -> Option<Launched> {
        self.launched
    }

    /// What a resumed program's exit with `status`, said at `at`, means: its failure to resume
    /// when it failed before it started, or within `launch::FAILED_WITHIN` of starting, said
    /// once; else a plain clear.
    fn exited(&mut self, status: i32, at: Instant) -> Outcome {
        let soon = |started: Instant| at.saturating_duration_since(started) < launch::FAILED_WITHIN;
        match self.resuming.take() {
            Some(Resuming::Waiting { program, .. }) if launch::failed(status) => {
                Outcome::ResumeFailed { program, status }
            }
            Some(Resuming::Started { program, at }) if launch::failed(status) && soon(at) => {
                Outcome::ResumeFailed { program, status }
            }
            _ => Outcome::Cleared,
        }
    }

    /// What an accepted `record` means, accepted at `at`: the resumed program starting when it is
    /// the record the session waits for its helper to report, said once; else just accepted.
    fn started(&mut self, outcome: Outcome, record: Option<&Record>, at: Instant) -> Outcome {
        let reported = |argv: &Vec<String>, cwd: &Option<String>| {
            record.is_some_and(|record| record.argv == *argv && record.reported_cwd == *cwd)
        };
        match self.resuming.take() {
            Some(Resuming::Waiting {
                program, argv, cwd, ..
            }) if reported(&argv, &cwd) => {
                self.resuming = Some(Resuming::Started {
                    program: program.clone(),
                    at,
                });
                // The report's owner is the helper's child, so its parent, the first of its
                // ancestors, is the helper.
                self.launched = record.and_then(|record| {
                    Some(Launched {
                        helper: *record.ancestors.first()?,
                        program: record.owner,
                    })
                });
                Outcome::ResumeStarted { program }
            }
            other => {
                self.resuming = other;
                outcome
            }
        }
    }

    /// The token the session's shell was given in `TOKEN_VARIABLE`.
    #[cfg(test)]
    pub(crate) fn token(&self) -> &str {
        &self.token
    }

    /// Records the session's first process, once its shell has started.
    pub(crate) fn set_root(&mut self, pid: i32) {
        if self.root.is_none()
            && let Ok(pid) = u32::try_from(pid)
            && let Some(identity) = crate::terminal::process::identity(pid)
            && identity.uid == self.uid
        {
            self.root = Some(identity.into());
        }
    }

    /// Every report `bytes` (raw pty output) completes, applied, with what each did.
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> Vec<Outcome> {
        let reports = self.stream.feed(bytes);
        if reports.is_empty() {
            return Vec::new();
        }
        let now = unix_now();
        let at = Instant::now();
        let (root, uid) = (self.root, self.uid);
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
    fn after(&mut self, outcome: Outcome, offset: u64, body: &[u8], at: Instant) -> Outcome {
        match (&outcome, protocol::workroom_exit(body)) {
            (Outcome::Cleared, Some(status)) => self.exited(status, at),
            (Outcome::Cleared, None) if protocol::workroom_hook(body) => self.hook_loaded(),
            (Outcome::Accepted { .. }, _) => {
                let record = self
                    .words
                    .values()
                    .find(|word| word.offset == offset)
                    .and_then(|word| word.record.clone());
                self.started(outcome, record.as_ref(), at)
            }
            _ => outcome,
        }
    }

    /// Applies one report body found at `offset`, checking its owner with `find_owner`.
    fn apply(
        &mut self,
        offset: u64,
        body: &[u8],
        now: u64,
        find_owner: impl FnOnce(u32) -> Result<Checked, NotOwner>,
    ) -> Outcome {
        let report = match protocol::authenticate(body, &self.token, now) {
            Ok(report) => report,
            Err(ignored) => {
                return Outcome::NotAccepted {
                    reason: match ignored {
                        Ignored::BadMac => "bad_mac",
                        Ignored::StaleTime => "stale_time",
                        Ignored::NoPid => "no_pid",
                    },
                    program: None,
                };
            }
        };
        let program = match &report.action {
            Some(Action::Set { argv, .. }) => Some(program_name(argv)),
            _ => None,
        };
        // A pid that never got a record is forgotten a minute after it last reported.
        self.words.retain(|_, word| {
            word.record.is_some() || now.saturating_sub(word.time) <= protocol::WINDOW_SECONDS
        });
        let previous = self.words.get(&report.pid);
        if let Some(word) = previous
            && (offset <= word.offset || report.time < word.time)
        {
            return Outcome::NotAccepted {
                reason: "replayed",
                program,
            };
        }
        if previous.is_none() && self.words.len() >= MAX_OWNERS {
            return Outcome::NotAccepted {
                reason: "too_many_owners",
                program,
            };
        }
        let previous_time = previous.map_or(0, |word| word.time);
        let (record, outcome) = match report.action {
            Some(Action::Set { argv, cwd }) => match find_owner(report.pid) {
                Ok(checked) => (
                    Some(Record {
                        owner: checked.owner,
                        ancestors: checked.ancestors,
                        argv,
                        reported_cwd: cwd,
                        owner_cwd: checked.cwd,
                        reported_at: report.time,
                        gone_since: None,
                    }),
                    Outcome::Accepted {
                        program: program.clone().unwrap_or_default(),
                    },
                ),
                Err(not) => (
                    None,
                    Outcome::NotAccepted {
                        reason: not.reason(),
                        program,
                    },
                ),
            },
            Some(Action::Clear) => (None, Outcome::Cleared),
            // Authenticated and malformed: rejected, which removes every record the owner has, and
            // a pid has one.
            None => (
                None,
                Outcome::NotAccepted {
                    reason: "malformed",
                    program: None,
                },
            ),
        };
        // Only an accepted report moves the owner's time on; a rejection still removes its record.
        let accepted = matches!(outcome, Outcome::Accepted { .. } | Outcome::Cleared);
        let time = if accepted { report.time } else { previous_time };
        self.words.insert(
            report.pid,
            Word {
                time,
                offset,
                record,
            },
        );
        outcome
    }

    /// The record the session would resume from: among the records whose owner runs under no other
    /// record's owner, the one that reported last.
    fn choice(&self) -> Option<&Record> {
        let records = || {
            self.words
                .values()
                .filter_map(|word| Some((word.offset, word.record.as_ref()?)))
        };
        records()
            .filter(|(_, record)| {
                !records().any(|(_, other)| record.ancestors.contains(&other.owner))
            })
            .max_by_key(|(offset, _)| *offset)
            .map(|(_, record)| record)
    }

    /// Whether a record's owner was found gone and is still inside its grace.
    fn in_grace(&self) -> bool {
        self.words
            .values()
            .filter_map(|word| word.record.as_ref())
            .any(|record| record.gone_since.is_some())
    }

    /// Every record's owner.
    fn owners(&self) -> Vec<Owner> {
        self.words
            .values()
            .filter_map(|word| word.record.as_ref().map(|record| record.owner))
            .collect()
    }

    /// One look at `owner`, found `gone` (or its pid now another process's) at `now`: starts its
    /// record's grace, ends it if the owner is back, and clears the record once it has been gone
    /// for `EXIT_GRACE`. A record that is no longer `owner`'s (a newer report replaced it, or its
    /// pid was reused) is left alone. The `Word` stays, so a replay is still refused.
    fn check_exit(&mut self, owner: Owner, gone: bool, now: Instant) -> Exit {
        let Some(word) = self.words.get_mut(&owner.pid) else {
            return Exit::Unchanged;
        };
        let Some(record) = word.record.as_mut().filter(|record| record.owner == owner) else {
            return Exit::Unchanged;
        };
        match record.gone_since {
            Some(since) if gone && now.saturating_duration_since(since) >= EXIT_GRACE => {
                let program = program_name(&record.argv);
                word.record = None;
                Exit::Cleared { program }
            }
            Some(_) if !gone => {
                record.gone_since = None;
                Exit::Back
            }
            None if gone => {
                record.gone_since = Some(now);
                Exit::Gone
            }
            _ => Exit::Unchanged,
        }
    }

    /// The session's resume record, as the terminal API shows it.
    pub(crate) fn recorded(&self) -> Option<Recorded> {
        self.whole().map(|whole| Recorded {
            program: program_name(&whole.argv),
            cwd: whole.cwd,
            reported_at_ms: whole.reported_at_ms,
        })
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

    /// What a hand-off carries of this state.
    pub(crate) fn carried(&self) -> Carried {
        Carried {
            token: self.token.clone(),
            uid: self.uid,
            root: self.root,
            words: self.words.clone(),
            offset: self.stream.offset,
            launched: self.launched,
        }
    }

    /// The state a hand-off carried, going on from where its stream stopped.
    pub(crate) fn adopted(carried: Carried) -> Resume {
        Resume {
            token: carried.token,
            uid: carried.uid,
            root: carried.root,
            words: carried.words,
            stream: Stream::at(carried.offset),
            resuming: None,
            launched: carried.launched,
        }
    }
}

/// The process whose name, folder and Claude profile stand for a session's foreground process
/// group `group` (#825): the group's leader, except where it is the helper that runs a resumed
/// program (`launch`), which the shell made its job's leader, so the program would read as
/// `workroom`. There it is the program. Proof, looked up with `lookup` (`process::identity`): the
/// session resumed a program whose report the daemon accepted, from a process under the session's
/// shell with the leader as its parent (`Launched`), and both are still those processes (pid and
/// start time), the program still the leader's child. The group itself is left as it is: program
/// status and `terminal.prompt` compare groups.
pub(crate) fn foreground_process(
    shared: &SharedResume,
    group: i32,
    lookup: impl Fn(u32) -> Option<Identity>,
) -> i32 {
    let Some(launched) = crate::util::lock_or_recover(shared)
        .as_ref()
        .and_then(Resume::launched)
    else {
        return group;
    };
    if u32::try_from(group).ok() != Some(launched.helper.pid) {
        return group;
    }
    let helper = lookup(launched.helper.pid).map(Owner::from) == Some(launched.helper);
    let program = lookup(launched.program.pid).is_some_and(|program| {
        Owner::from(program) == launched.program && program.parent == launched.helper.pid
    });
    match i32::try_from(launched.program.pid) {
        Ok(pid) if helper && program => pid,
        _ => group,
    }
}

/// Checks that `pid` may own a record in a session whose first process is `root`: alive, run by
/// `uid`, and with `root` among its parents, each parent started no later than its child (so a
/// reused pid in the chain breaks it).
fn check_owner(
    root: Option<Owner>,
    uid: u32,
    pid: u32,
    lookup: impl Fn(u32) -> Option<Identity>,
) -> Result<Checked, NotOwner> {
    let root = root.ok_or(NotOwner::NotDescendant)?;
    let owner = lookup(pid).ok_or(NotOwner::Gone)?;
    if owner.uid != uid {
        return Err(NotOwner::OtherUser);
    }
    let mut ancestors = Vec::new();
    let mut process = owner;
    while Owner::from(process) != root {
        if process.pid == root.pid || process.parent == 0 || ancestors.len() == MAX_ANCESTORS {
            return Err(NotOwner::NotDescendant);
        }
        let parent = lookup(process.parent).ok_or(NotOwner::NotDescendant)?;
        if parent.start > process.start || parent.pid == process.pid {
            return Err(NotOwner::NotDescendant);
        }
        ancestors.push(Owner::from(parent));
        process = parent;
    }
    Ok(Checked {
        owner: owner.into(),
        ancestors,
        cwd: crate::terminal::process::working_directory(pid as i32),
    })
}

/// What one look at a session's record owners found (`watch_owners`).
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Watched {
    /// The programs whose records cleared, their owners gone for `EXIT_GRACE`.
    pub cleared: Vec<String>,
    /// Whether an owner is inside its grace, so another look is owed whether or not more output
    /// comes. A running owner owes none: its exit prints its shell's prompt, which wakes the next
    /// look, so an idle daemon still sleeps while its programs hold records.
    pub watching: bool,
}

/// One look, at `now`, at whether each record's owner in `shared` still runs, with `lookup`
/// (`process::identity`): an owner gone, or whose pid now names another process, starts its
/// grace, and its record clears once it has stayed gone for `EXIT_GRACE` (`Resume::check_exit`).
/// While the session's own shell is gone nothing clears: the session is ending, and its records
/// must outlast it (#824).
///
/// The lookups run with the state's lock released, so a read waits on it only while the owners are
/// copied and while what was found is applied. A report accepted meanwhile is safe: it replaces
/// its pid's record with one `check_exit` sees is not the owner it looked up, or is the same owner
/// again, which is then running.
pub(crate) fn watch_owners(
    shared: &SharedResume,
    now: Instant,
    lookup: impl Fn(u32) -> Option<Identity>,
) -> Watched {
    let (root, owners) = {
        let state = crate::util::lock_or_recover(shared);
        let Some(state) = state.as_ref() else {
            return Watched::default();
        };
        (state.root, state.owners())
    };
    if owners.is_empty() {
        return Watched::default();
    }
    let running = |owner: Owner| lookup(owner.pid).map(Owner::from) == Some(owner);
    // A record is only accepted once the first process is known, so `root` is set here.
    if !root.is_some_and(running) {
        // The session is ending, and its end wakes the thread itself.
        return Watched::default();
    }
    let found: Vec<(Owner, bool)> = owners
        .into_iter()
        .map(|owner| (owner, !running(owner)))
        .collect();
    let mut state = crate::util::lock_or_recover(shared);
    let Some(state) = state.as_mut() else {
        return Watched::default();
    };
    let cleared = found
        .into_iter()
        .filter_map(|(owner, gone)| match state.check_exit(owner, gone, now) {
            Exit::Cleared { program } => Some(program),
            _ => None,
        })
        .collect();
    Watched {
        cleared,
        watching: state.in_grace(),
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

/// The daemon's user, whose processes alone may report, or `None` when it runs as root or setuid:
/// such a daemon accepts no reports (ADR 0082).
fn daemon_user() -> Option<u32> {
    // SAFETY: neither call has preconditions.
    let (euid, uid) = unsafe { (libc::geteuid(), libc::getuid()) };
    (euid != 0 && euid == uid).then_some(euid)
}

/// Whether this daemon accepts reports at all (`daemon_user`): a root one gives no session a
/// token, so no session of its resumes either, and a remote pane's gone session stays ended
/// (#826).
pub(crate) fn daemon_accepts_reports() -> bool {
    daemon_user().is_some()
}

/// A new random token for an interactive session's `TOKEN_VARIABLE`, or `None` when the daemon
/// accepts no reports (`daemon_user`) or the system's randomness fails: that session then gets no
/// token, never a predictable one.
pub(crate) fn new_token() -> Option<String> {
    daemon_user()?;
    let mut bytes = [0u8; 16];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes).ok()?;
    Some(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// Gives a new session's environment its own token, or none, in place of any it was forwarded:
/// a token from the pane an attach client was typed in belongs to that pane (ADR 0082).
pub(crate) fn give_token(environment: &mut Vec<(OsString, OsString)>, interactive: bool) {
    environment.retain(|(key, _)| key != TOKEN_VARIABLE);
    if !interactive {
        return;
    }
    match new_token() {
        Some(token) => environment.push((TOKEN_VARIABLE.into(), token.into())),
        None if daemon_user().is_none() => {
            // Said once: every shell of a root daemon is refused the same way.
            static SAID: std::sync::Once = std::sync::Once::new();
            SAID.call_once(|| {
                crate::note!(
                    "resume: this daemon runs as root, so no session accepts reports (root)"
                )
            });
        }
        None => crate::note!("resume: no token for a new session: the system's randomness failed"),
    }
}

/// Keeps a pane's resume token out of a process the daemon starts that isn't a session's shell
/// (`workroom exec`, the daemon itself, an attach client's fallback shell): a token in the
/// environment it was handed belongs to another pane, and nothing it runs may report for it
/// (ADR 0082).
pub(crate) fn scrub(command: &mut std::process::Command) {
    command.env_remove(TOKEN_VARIABLE);
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

#[cfg(test)]
mod tests;
