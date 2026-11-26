//! Program resume (ADR 0082): what a session's programs have reported, over the Program Resume
//! Protocol (OSC 7577, <https://www.superlogical.com/rex/docs/build/program-resume>), about how
//! to start them again, kept per session as its **resume record**. Nothing here starts anything:
//! a pane whose session is gone resumes from the record the app saved (#825).
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
//! The decisions in `apply` and the owner check are ported from herdr-core
//! (herdrdev/herdr-core#429, `crates/herdr-core/src/resume.rs` at
//! `0cb50d57832f3ebb69157ce7f023fbbc520181a8`), Licensed under the Apache License, Version 2.0
//! (`resume/LICENSE`). Changed from the original for Workroom: the state is a session's, not a
//! kept terminal's; each report's outcome is returned so the daemon can log why one did not count;
//! the record carries when it was reported; and launching, exit grace and the rapid-loss guard
//! are not here (#823, #825).

mod protocol;

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use protocol::{Action, Ignored, Stream};

/// The environment variable a session's token is in.
pub(crate) const TOKEN_VARIABLE: &str = "OSC7577_TOKEN";

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

impl From<crate::terminal::process::Identity> for Owner {
    fn from(identity: crate::terminal::process::Identity) -> Owner {
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
                        ancestors: vec![owner],
                        argv: vec!["claude".into(), "--resume".into(), "a-session".into()],
                        reported_cwd: Some("/work".into()),
                        owner_cwd: None,
                        reported_at: 1_795_543_200,
                    }),
                },
            )]),
            offset,
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
        let (root, uid) = (self.root, self.uid);
        reports
            .into_iter()
            .map(|(offset, body)| {
                self.apply(offset, &body, now, |pid| {
                    check_owner(root, uid, pid, crate::terminal::process::identity)
                })
            })
            .collect()
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
            // Authenticated and malformed: rejected, which removes the owner's record.
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

    /// The session's resume record, as the terminal API shows it.
    pub(crate) fn recorded(&self) -> Option<Recorded> {
        self.choice().map(|record| Recorded {
            program: program_name(&record.argv),
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
        }
    }
}

/// Checks that `pid` may own a record in a session whose first process is `root`: alive, run by
/// `uid`, and with `root` among its parents, each parent started no later than its child (so a
/// reused pid in the chain breaks it).
fn check_owner(
    root: Option<Owner>,
    uid: u32,
    pid: u32,
    lookup: impl Fn(u32) -> Option<crate::terminal::process::Identity>,
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
