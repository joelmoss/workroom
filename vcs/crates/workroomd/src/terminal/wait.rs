//! `terminal.wait` (#690): a terminal API caller waiting, on the daemon, for one thing to happen in
//! a session. The request's side is `terminal::api`'s; this is the [`Waiter`] a session holds while
//! it waits, and what tells it what happened.
//!
//! **Where it hears.** A waiter is held in its session's attachment state, which the session's
//! reader already locks around every read, so a session nobody waits on pays one `is_empty` per
//! read, beside the shadow counting the OSC 133 marks among the program status events it already
//! collects for each read (none, mostly). With a waiter, the reader hands it each read's bytes and the shadow's
//! state ([`Seen`]) once the session's locks are released. A run's state comes from the runs
//! watcher as it reads each new status line, and the session's end from its reader as it ends.
//!
//! A regex is matched here, against the output stream the session's reader already reads, after
//! escape sequences are stripped ([`Matcher`]).

use std::sync::{Condvar, Mutex};
use std::time::Instant;

use crate::terminal::program_status::State;
use crate::util::{lock_or_recover, recover};

/// What a waiter waits for.
pub enum Condition {
    /// The session's coding agent reaching a program status: as `sessions` reports it.
    Status(State),
    /// A run session's supervisor reaching a state, `exited` with whatever code: a wait for an
    /// exit with one code answers when the run exits, and says whether it was that one
    /// (`api::wait`), rather than wait for an exit that may never come.
    Run(RunState),
    /// Output matching a regex, from what arrives after the wait starts (and the screen, when the
    /// matcher was given it first).
    Output(Matcher),
    /// The session ending.
    Ended,
    /// The shell's next command end (OSC 133 D closing a C).
    CommandFinished,
}

/// A run supervisor's state, the first word of its status line (`run_supervisor.sh`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunState {
    Starting,
    Running,
    Stopping,
    Stopped,
    Exited,
}

impl RunState {
    pub const ALL: [RunState; 5] = [
        RunState::Starting,
        RunState::Running,
        RunState::Stopping,
        RunState::Stopped,
        RunState::Exited,
    ];

    pub fn name(self) -> &'static str {
        match self {
            RunState::Starting => "starting",
            RunState::Running => "running",
            RunState::Stopping => "stopping",
            RunState::Stopped => "stopped",
            RunState::Exited => "exited",
        }
    }

    pub fn named(name: &str) -> Option<RunState> {
        RunState::ALL.into_iter().find(|state| state.name() == name)
    }

    /// A status line's state, and its exit code when it is `exited <code> …`.
    pub fn of_line(line: &str) -> Option<(RunState, Option<i32>)> {
        let mut words = line.split_whitespace();
        let state = RunState::named(words.next()?)?;
        let code = (state == RunState::Exited)
            .then(|| words.next().and_then(|code| code.parse().ok()))
            .flatten();
        Some((state, code))
    }
}

/// What the shadow says after a read, for the waiters that look at it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Seen {
    /// The coding agent's state, as `sessions` reports it; `None` with no record.
    pub agent: Option<State>,
    /// The states the read's events left the agent in, in order, when it had several
    /// (`Store::apply_read`): one reported and replaced within the read still meets a wait for it.
    /// Empty but straight after a read.
    pub passed: Vec<State>,
    /// How many commands the shell has ended (OSC 133 D after a C) since the daemon started it.
    pub commands: u64,
    /// The last of them's exit code.
    pub last_exit: Option<i32>,
}

/// How a wait ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// What it waited for happened.
    Met(Met),
    /// The session ended first.
    SessionEnded,
    /// Its deadline passed first.
    TimedOut,
    /// Its caller went away.
    Cancelled,
}

/// What a met wait saw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Met {
    Status(State),
    Run {
        state: RunState,
        exit_code: Option<i32>,
    },
    /// The text the regex matched.
    Output(Vec<u8>),
    /// The session's shell's exit code, when the daemon saw it exit.
    Ended(Option<i32>),
    /// The command's exit code.
    CommandFinished(Option<i32>),
}

/// One wait, shared by the session that tells it what happens and the request waiting on it.
pub struct Waiter {
    state: Mutex<Progress>,
    wake: Condvar,
}

struct Progress {
    condition: Condition,
    /// The commands the shell had ended when the wait started, for `CommandFinished`.
    commands_before: u64,
    /// Set once, by whatever ends the wait first.
    outcome: Option<Outcome>,
}

impl Waiter {
    /// A waiter for `condition`, starting from what the shadow says now: a status already reached
    /// meets it at once.
    pub fn new(condition: Condition, now: Seen) -> Waiter {
        let waiter = Waiter {
            state: Mutex::new(Progress {
                condition,
                commands_before: now.commands,
                outcome: None,
            }),
            wake: Condvar::new(),
        };
        waiter.shadow(&now);
        waiter
    }

    /// How it ended, if it has.
    pub fn outcome(&self) -> Option<Outcome> {
        lock_or_recover(&self.state).outcome.clone()
    }

    /// The next bytes of the session's output.
    pub fn output(&self, bytes: &[u8]) {
        self.update(|progress| match &mut progress.condition {
            Condition::Output(matcher) => matcher.feed(bytes).map(Met::Output),
            _ => None,
        });
    }

    /// Plain text, ahead of any output: the screen, for `--include-screen`.
    pub fn screen(&self, text: &[u8]) {
        self.update(|progress| match &mut progress.condition {
            Condition::Output(matcher) => matcher.feed_plain(text).map(Met::Output),
            _ => None,
        });
    }

    /// The shadow's state after a read, or after the program status changed.
    pub fn shadow(&self, seen: &Seen) {
        self.update(|progress| match progress.condition {
            Condition::Status(wanted)
                if seen.agent == Some(wanted) || seen.passed.contains(&wanted) =>
            {
                Some(Met::Status(wanted))
            }
            Condition::CommandFinished if seen.commands > progress.commands_before => {
                Some(Met::CommandFinished(seen.last_exit))
            }
            _ => None,
        });
    }

    /// A run's status line, as its supervisor last wrote it.
    pub fn run(&self, line: &str) {
        let Some((state, code)) = RunState::of_line(line) else {
            return;
        };
        self.update(|progress| match progress.condition {
            Condition::Run(wanted) if wanted == state => Some(Met::Run {
                state,
                exit_code: code,
            }),
            _ => None,
        });
    }

    /// The session ended, with its shell's exit code when the daemon saw it.
    pub fn ended(&self, exit_code: Option<i32>) {
        self.finish(|condition| match condition {
            Condition::Ended => Outcome::Met(Met::Ended(exit_code)),
            _ => Outcome::SessionEnded,
        });
    }

    /// Its caller has gone: whatever is waiting stops.
    pub fn cancel(&self) {
        self.finish(|_| Outcome::Cancelled);
    }

    /// Blocks until the wait ends, or `deadline` passes (none: never).
    pub fn wait(&self, deadline: Option<Instant>) -> Outcome {
        let mut progress = lock_or_recover(&self.state);
        loop {
            if let Some(outcome) = &progress.outcome {
                return outcome.clone();
            }
            match deadline {
                None => progress = recover(self.wake.wait(progress)),
                Some(deadline) => {
                    let now = Instant::now();
                    if now >= deadline {
                        progress.outcome = Some(Outcome::TimedOut);
                        continue;
                    }
                    progress = recover(self.wake.wait_timeout(progress, deadline - now)).0;
                }
            }
        }
    }

    /// Meets the wait with what `met` sees, unless it has already ended.
    fn update(&self, met: impl FnOnce(&mut Progress) -> Option<Met>) {
        let mut progress = lock_or_recover(&self.state);
        if progress.outcome.is_some() {
            return;
        }
        if let Some(met) = met(&mut progress) {
            progress.outcome = Some(Outcome::Met(met));
            drop(progress);
            self.wake.notify_all();
        }
    }

    fn finish(&self, outcome: impl FnOnce(&Condition) -> Outcome) {
        let mut progress = lock_or_recover(&self.state);
        if progress.outcome.is_none() {
            progress.outcome = Some(outcome(&progress.condition));
            drop(progress);
            self.wake.notify_all();
        }
    }
}

/// The most stripped output a regex waiter keeps: the longest a match can be, and what each read
/// rescans. A match spanning reads is found because the window still holds its start; one longer
/// than this is not. Each waiter holds at most this much plus one read.
pub const WINDOW: usize = 16 * 1024;

/// The most memory a waiter's compiled regex may take, so one request cannot hold the daemon's.
const REGEX_SIZE_LIMIT: usize = 1 << 20;

/// A regex over a session's output as a person reads it: escape sequences and control characters
/// other than `\t`, `\n` and `\r` stripped as they arrive, so neither a sequence nor a character
/// split across two reads hides a match. `^` and `$` are line anchors, and `$` also matches before
/// a `\r\n` (pty output's line end); at the end of what has arrived so far, `$` matches too, since
/// the rest of the line may never come.
pub struct Matcher {
    regex: regex::bytes::Regex,
    strip: Stripper,
    /// The stripped output since the wait started, at most `WINDOW` bytes once a search fails.
    window: Vec<u8>,
}

impl Matcher {
    pub fn new(pattern: &str) -> Result<Matcher, regex::Error> {
        let regex = regex::bytes::RegexBuilder::new(pattern)
            .multi_line(true)
            .crlf(true)
            .size_limit(REGEX_SIZE_LIMIT)
            .dfa_size_limit(REGEX_SIZE_LIMIT)
            .build()?;
        Ok(Matcher {
            regex,
            strip: Stripper::default(),
            window: Vec::new(),
        })
    }

    /// Takes the next bytes of output and returns the first match, if the window now holds one.
    pub fn feed(&mut self, bytes: &[u8]) -> Option<Vec<u8>> {
        let before = self.window.len();
        self.strip.strip(bytes, &mut self.window);
        if self.window.len() == before {
            return None;
        }
        self.search()
    }

    /// Takes text that is already plain (the screen, for `--include-screen`): nothing in it is an
    /// escape sequence, and the stream's own parse state is left as it was.
    pub fn feed_plain(&mut self, text: &[u8]) -> Option<Vec<u8>> {
        self.window.extend_from_slice(text);
        self.search()
    }

    /// The output from here on starts somewhere unknown, perhaps inside a sequence: a wait that
    /// starts while the session's parser is mid-sequence (a title, a kitty image's base64), whose
    /// rest is no text. Bytes are dropped until one that ends or starts a sequence or a line:
    /// ESC, BEL, CAN, SUB or `\n`, which is kept, as a line's end.
    pub fn resync(&mut self) {
        self.strip = Stripper::Resync;
    }

    fn search(&mut self) -> Option<Vec<u8>> {
        if let Some(found) = self.regex.find(&self.window) {
            return Some(found.as_bytes().to_vec());
        }
        self.trim();
        None
    }

    /// Drops the oldest text past `WINDOW`, from the start of a line when one begins in the last
    /// `WINDOW` bytes, so `^` still means a line's start.
    fn trim(&mut self) {
        let Some(excess) = self.window.len().checked_sub(WINDOW) else {
            return;
        };
        let cut = self.window[excess..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(excess, |at| excess + at + 1);
        self.window.drain(..cut);
    }

    #[cfg(test)]
    fn window_len(&self) -> usize {
        self.window.len()
    }
}

/// Where the stripper is in the stream. State carries across reads, and nothing a sequence holds is
/// kept: a string's payload (OSC, DCS, APC, PM, SOS) is dropped as it arrives.
#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum Stripper {
    #[default]
    Ground,
    Escape,
    /// `ESC` and intermediates (0x20–0x2F) waiting for a final byte, such as `ESC ( B`.
    EscapeIntermediate,
    /// `CSI`, until a final byte in 0x40–0x7E.
    ControlSequence,
    /// A string, until BEL or ST.
    String,
    /// An ESC inside a string: ST if `\` follows.
    StringEscape,
    /// Somewhere unknown ([`Matcher::resync`]), until ESC, BEL, CAN, SUB or `\n`.
    Resync,
}

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;
/// CAN and SUB cancel the sequence in progress.
const CAN: u8 = 0x18;
const SUB: u8 = 0x1a;

impl Stripper {
    fn strip(&mut self, bytes: &[u8], out: &mut Vec<u8>) {
        for &byte in bytes {
            *self = self.next(byte, out);
        }
    }

    fn next(self, byte: u8, out: &mut Vec<u8>) -> Stripper {
        use Stripper::*;
        let kept = |out: &mut Vec<u8>| {
            if matches!(byte, b'\t' | b'\n' | b'\r') {
                out.push(byte);
            }
        };
        match self {
            Ground => match byte {
                ESC => Escape,
                0x00..=0x1f | 0x7f => {
                    kept(out);
                    Ground
                }
                _ => {
                    out.push(byte);
                    Ground
                }
            },
            Escape => match byte {
                b'[' => ControlSequence,
                b']' | b'P' | b'_' | b'^' | b'X' => String,
                ESC => Escape,
                CAN | SUB => Ground,
                0x20..=0x2f => EscapeIntermediate,
                // A control inside a sequence is carried out, and the sequence goes on.
                0x00..=0x1f => {
                    kept(out);
                    Escape
                }
                _ => Ground,
            },
            EscapeIntermediate => match byte {
                ESC => Escape,
                CAN | SUB => Ground,
                0x20..=0x2f => EscapeIntermediate,
                0x00..=0x1f => {
                    kept(out);
                    EscapeIntermediate
                }
                _ => Ground,
            },
            ControlSequence => match byte {
                ESC => Escape,
                CAN | SUB => Ground,
                0x40..=0x7e => Ground,
                0x00..=0x1f => {
                    kept(out);
                    ControlSequence
                }
                _ => ControlSequence,
            },
            String => match byte {
                BEL | CAN | SUB => Ground,
                ESC => StringEscape,
                _ => String,
            },
            // Any ESC ends a string; one not followed by `\` starts the next sequence.
            StringEscape => match byte {
                b'\\' => Ground,
                _ => Escape.next(byte, out),
            },
            // An ESC may be a string's ST (`ESC \`), which `Escape` reads as a sequence of its
            // own and ends, or the next sequence's start: either way, what follows it is known.
            Resync => match byte {
                ESC => Escape,
                BEL | CAN | SUB => Ground,
                b'\n' => {
                    out.push(byte);
                    Ground
                }
                _ => Resync,
            },
        }
    }
}

#[cfg(test)]
mod tests;
