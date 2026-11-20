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
//! A regex is matched against the output stream the session's reader already reads, after escape
//! sequences are stripped ([`Matcher`]), on the wait's own thread ([`Waiter::wait`]): the reader
//! only copies each read into the waiter's queue, bounded at [`QUEUE`], so however many waits a
//! session has and however slow their regexes, its output reaches its clients as soon as without.
//!
//! **What a regex wait holds**, at most: [`QUEUE`] of output not yet matched, the queued and the
//! batch its thread is matching counted together, in chunks of [`CHUNK`] (one more on each side,
//! part-filled), and the window of stripped text it matches in, [`WINDOW`] and a chunk (at most
//! twice that as allocated). About 320 KiB, so 160 MiB for the daemon's 512 waits, all of it only
//! while a wait is behind a session printing flat out; besides, the screen's text once for
//! `include_screen`, and the regex, compiled and its search cache, each at most
//! [`REGEX_SIZE_LIMIT`] (a few KiB for a pattern such as `ready in \d+ ms`).

use std::collections::VecDeque;
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
    /// Whether the shell has sent an OSC 133 mark, so a command's end can be seen.
    pub shell_marks: bool,
    /// How many commands the shell has ended (OSC 133 D after a C) since the daemon started it.
    pub commands: u64,
    /// The exit codes of the last of them, oldest first, as many as the shadow keeps
    /// (`shadow::RECENT_EXITS`): the last is that of the `commands`th. Several end within one
    /// read when commands are quick, and a wait for the next to finish answers with the first's.
    pub exits: Vec<i32>,
}

impl Seen {
    /// The exit code of the `nth` command the shell ended (from 1), while it is among the recent.
    fn exit_of(&self, nth: u64) -> Option<i32> {
        let back = usize::try_from(self.commands.checked_sub(nth)?).ok()?;
        let at = self.exits.len().checked_sub(back + 1)?;
        self.exits.get(at).copied()
    }
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
    /// A `CommandFinished` wait on a young session whose shell sent no OSC 133 mark within the
    /// grace it was given (`Waiter::marks_by`).
    NoShellIntegration,
    /// A regex wait fell a [`QUEUE`] behind its session's output, so what came after was dropped
    /// unmatched, and matched nothing in what it kept: a match may have gone by unseen.
    FellBehind,
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
    /// A regex wait's matcher, used only by the thread in [`Waiter::wait`], never by the session:
    /// matching happens there, off the session's reader.
    matcher: Mutex<Option<Matcher>>,
}

/// What a waiter waits for, its regex's matcher apart (`Waiter::matcher`).
#[derive(Clone, Copy, PartialEq, Eq)]
enum Wanted {
    Status(State),
    Run(RunState),
    Output,
    Ended,
    CommandFinished,
}

struct Progress {
    wanted: Wanted,
    /// The commands the shell had ended when the wait started, for `CommandFinished`.
    commands_before: u64,
    /// A regex wait's output, handed over by the reader and not yet taken by its thread.
    queue: Queue,
    /// What the thread has taken and not matched yet: counted with `queue` against `QUEUE`.
    in_hand: usize,
    /// A regex wait's session ended: the wait matches what is queued before it says so.
    ended: bool,
    /// A `CommandFinished` wait's shell has sent no mark yet: the wait is `NoShellIntegration`
    /// if none comes by then (`Waiter::marks_by`).
    marks_by: Option<Instant>,
    /// Set once, by whatever ends the wait first.
    outcome: Option<Outcome>,
}

/// The most output a regex waiter holds that its thread has not matched yet, queued and taken
/// together. A read past it is dropped, and every read after it, never the reader made to wait:
/// the waiter has fallen behind, and once it has matched what it kept, ends `FellBehind` rather
/// than match on past a gap (`Queue::lagged`). Its thread takes all of it at once, and matches it
/// a chunk at a time, so it catches up on a session that prints in bursts faster than it matches.
pub const QUEUE: usize = 16 * WINDOW;

/// The size of the queue's chunks: a pty read's most (`session::READ_CHUNK`), so a read usually
/// fills at most two, and many small reads share one rather than take an allocation each.
pub const CHUNK: usize = 8 * 1024;

/// What the reader has handed a regex waiter and its thread has not taken yet.
#[derive(Default)]
struct Queue {
    /// The screen as plain text, matched first (`--include-screen`).
    screen: Option<Vec<u8>>,
    /// The session's output, as read, in chunks allocated at `CHUNK`: adding a read copies it
    /// alone, whatever is queued, and the thread frees each as it matches it.
    chunks: VecDeque<Vec<u8>>,
    /// The bytes in `chunks`.
    len: usize,
    /// A read was dropped: nothing after it is queued, since no match may span the gap, and the
    /// wait ends `FellBehind` unless what came before it matches.
    lagged: bool,
}

impl Queue {
    /// Whether the thread has anything to take: output, the screen, or the news that it lagged.
    fn is_empty(&self) -> bool {
        self.screen.is_none() && self.chunks.is_empty() && !self.lagged
    }

    /// Adds `bytes` while they fit beside the `in_hand` bytes the thread is matching; a read that
    /// doesn't, and every one after it, is dropped.
    fn push(&mut self, bytes: &[u8], in_hand: usize) {
        if self.lagged || bytes.is_empty() {
            return;
        }
        if self.len + in_hand + bytes.len() > QUEUE {
            self.lagged = true;
            return;
        }
        self.len += bytes.len();
        let mut rest = bytes;
        while !rest.is_empty() {
            if self.chunks.back().is_none_or(|chunk| chunk.len() == CHUNK) {
                self.chunks.push_back(Vec::with_capacity(CHUNK));
            }
            let chunk = self
                .chunks
                .back_mut()
                .expect("a chunk with room was just made");
            let (now, later) = rest.split_at(rest.len().min(CHUNK - chunk.len()));
            chunk.extend_from_slice(now);
            rest = later;
        }
    }
}

impl Waiter {
    /// A waiter for `condition`, starting from what the shadow says now: a status already reached
    /// meets it at once.
    pub fn new(condition: Condition, now: Seen) -> Waiter {
        let (wanted, matcher) = match condition {
            Condition::Status(state) => (Wanted::Status(state), None),
            Condition::Run(state) => (Wanted::Run(state), None),
            Condition::Output(matcher) => (Wanted::Output, Some(matcher)),
            Condition::Ended => (Wanted::Ended, None),
            Condition::CommandFinished => (Wanted::CommandFinished, None),
        };
        let waiter = Waiter {
            state: Mutex::new(Progress {
                wanted,
                commands_before: now.commands,
                queue: Queue::default(),
                in_hand: 0,
                ended: false,
                marks_by: None,
                outcome: None,
            }),
            wake: Condvar::new(),
            matcher: Mutex::new(matcher),
        };
        waiter.shadow(&now);
        waiter
    }

    /// How it ended, if it has.
    pub fn outcome(&self) -> Option<Outcome> {
        lock_or_recover(&self.state).outcome.clone()
    }

    /// The next bytes of the session's output, from its reader: queued for the wait's own thread,
    /// so the reader pays a copy, never a match.
    pub fn output(&self, bytes: &[u8]) {
        self.queue(|progress| {
            let in_hand = progress.in_hand;
            progress.queue.push(bytes, in_hand);
        });
    }

    /// Plain text, ahead of any output: the screen, for `--include-screen`, queued as `output` is.
    pub fn screen(&self, text: Vec<u8>) {
        self.queue(|progress| progress.queue.screen = Some(text));
    }

    /// A `CommandFinished` wait on a session too young to have shown its prompt: until `at`, a
    /// shell that has sent no OSC 133 mark yet may still send one, and only then is the wait
    /// `NoShellIntegration`. A `new` followed at once by a wait would otherwise be refused before
    /// its shell's first prompt could come.
    pub fn marks_by(&self, at: Instant) {
        let mut progress = lock_or_recover(&self.state);
        if progress.wanted == Wanted::CommandFinished {
            progress.marks_by = Some(at);
        }
    }

    /// The shadow's state after a read, or after the program status changed.
    pub fn shadow(&self, seen: &Seen) {
        self.update(|progress| {
            if seen.shell_marks {
                progress.marks_by = None;
            }
            Self::met(progress, seen)
        });
    }

    fn met(progress: &Progress, seen: &Seen) -> Option<Met> {
        match progress.wanted {
            Wanted::Status(wanted)
                if seen.agent == Some(wanted) || seen.passed.contains(&wanted) =>
            {
                Some(Met::Status(wanted))
            }
            // The first command to end after the wait started, however many ended since.
            Wanted::CommandFinished if seen.commands > progress.commands_before => Some(
                Met::CommandFinished(seen.exit_of(progress.commands_before + 1)),
            ),
            _ => None,
        }
    }

    /// A run's status line, as its supervisor last wrote it.
    pub fn run(&self, line: &str) {
        let Some((state, code)) = RunState::of_line(line) else {
            return;
        };
        self.update(|progress| match progress.wanted {
            Wanted::Run(wanted) if wanted == state => Some(Met::Run {
                state,
                exit_code: code,
            }),
            _ => None,
        });
    }

    /// The session ended, with its shell's exit code when the daemon saw it. A regex wait first
    /// matches the output it has queued, which came before the end.
    pub fn ended(&self, exit_code: Option<i32>) {
        let mut progress = lock_or_recover(&self.state);
        if progress.outcome.is_some() {
            return;
        }
        match progress.wanted {
            Wanted::Ended => progress.outcome = Some(Outcome::Met(Met::Ended(exit_code))),
            Wanted::Output => progress.ended = true,
            _ => progress.outcome = Some(Outcome::SessionEnded),
        }
        drop(progress);
        self.wake.notify_all();
    }

    /// Its caller has gone: whatever is waiting stops.
    pub fn cancel(&self) {
        let mut progress = lock_or_recover(&self.state);
        if progress.outcome.is_none() {
            progress.outcome = Some(Outcome::Cancelled);
            drop(progress);
            self.wake.notify_all();
        }
    }

    /// Blocks until the wait ends, or `deadline` passes (none: never). A regex wait's output is
    /// matched here, on the caller's thread, with no lock the session's reader takes held: the
    /// queue is taken under the waiter's lock and matched after it is released. What is queued is
    /// matched before the session's end or the deadline is believed, so output that came first
    /// still meets the wait.
    pub fn wait(&self, deadline: Option<Instant>) -> Outcome {
        let mut matcher = lock_or_recover(&self.matcher);
        loop {
            // Taken once the deadline has passed, a batch is the last: a session that prints
            // faster than it is matched would otherwise keep the queue full past any deadline.
            let (queue, last) = {
                let mut progress = lock_or_recover(&self.state);
                loop {
                    if let Some(outcome) = &progress.outcome {
                        return outcome.clone();
                    }
                    if !progress.queue.is_empty() {
                        let last = deadline.is_some_and(|deadline| Instant::now() >= deadline);
                        let queue = std::mem::take(&mut progress.queue);
                        progress.in_hand = queue.len;
                        break (queue, last);
                    }
                    // Nothing left to match from before the end.
                    if progress.ended {
                        progress.outcome = Some(Outcome::SessionEnded);
                        continue;
                    }
                    // The deadline, or the end of a shell's grace for its first mark if sooner.
                    let until = match (deadline, progress.marks_by) {
                        (Some(deadline), Some(marks_by)) => Some(deadline.min(marks_by)),
                        (deadline, marks_by) => deadline.or(marks_by),
                    };
                    match until {
                        None => progress = recover(self.wake.wait(progress)),
                        Some(until) => {
                            let now = Instant::now();
                            if now >= until {
                                let timed_out = deadline.is_some_and(|deadline| now >= deadline);
                                progress.outcome = Some(if timed_out {
                                    Outcome::TimedOut
                                } else {
                                    Outcome::NoShellIntegration
                                });
                                continue;
                            }
                            progress = recover(self.wake.wait_timeout(progress, until - now)).0;
                        }
                    }
                }
            };
            let lagged = queue.lagged;
            let found = matcher.as_mut().and_then(|matcher| {
                // Each chunk matched leaves room for the reader's next.
                matcher.take(queue, |matched| {
                    let mut progress = lock_or_recover(&self.state);
                    progress.in_hand = progress.in_hand.saturating_sub(matched);
                })
            });
            if let Some(found) = found {
                self.update(|_| Some(Met::Output(found)));
            } else if lagged || last {
                // Behind rather than out of time when both: output was dropped unmatched.
                let ended = if lagged {
                    Outcome::FellBehind
                } else {
                    Outcome::TimedOut
                };
                lock_or_recover(&self.state).outcome.get_or_insert(ended);
            }
        }
    }

    /// Queues output for a regex wait's thread, and wakes it: nothing for any other wait.
    fn queue(&self, add: impl FnOnce(&mut Progress)) {
        let mut progress = lock_or_recover(&self.state);
        if progress.wanted != Wanted::Output || progress.outcome.is_some() {
            return;
        }
        add(&mut progress);
        drop(progress);
        self.wake.notify_all();
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
}

/// The most stripped output a regex waiter keeps: the longest a match can be, and what each read
/// rescans. A match spanning reads is found because the window still holds its start; one longer
/// than this is not. It holds this much and the chunk being matched (`CHUNK`) at most, before a
/// failed search trims it back (what a waiter holds: the module's notes).
pub const WINDOW: usize = 16 * 1024;

/// The most memory a waiter's compiled regex may take, and its search cache, each, so one request
/// cannot hold the daemon's.
pub const REGEX_SIZE_LIMIT: usize = 1 << 20;

/// A regex over a session's output as a person reads it: escape sequences and control characters
/// other than `\t`, `\n` and `\r` stripped as they arrive, so neither a sequence nor a character
/// split across two reads hides a match. `^` and `$` are line anchors, and `$` also matches before
/// a `\r\n` (pty output's line end); at the end of what has arrived so far, `$` matches too, since
/// the rest of the line may never come.
pub struct Matcher {
    regex: regex::bytes::Regex,
    strip: Stripper,
    /// One byte that says what comes before the text, then the stripped output since the wait
    /// started, at most `WINDOW` bytes of it once a search fails. The byte is `\n` when the text
    /// starts a line, so `^` matches there, and `NOT_A_LINE_START` when it starts mid-line (after
    /// a resync, or a trim with no line start to cut at), where `^` must not. Searches start after
    /// it, so it is never in a match.
    window: Vec<u8>,
}

/// What `Matcher::window` starts with when its text starts mid-line: neither `\n` nor `\r`, the
/// only bytes after which `^` matches, and never in stripped output, which keeps no other control.
const NOT_A_LINE_START: u8 = 0;

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
            window: vec![b'\n'],
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
    /// escape sequence, and the stream's own parse state is left as it was. The screen's text
    /// starts at its top row's start, a line's.
    pub fn feed_plain(&mut self, text: &[u8]) -> Option<Vec<u8>> {
        if self.window.len() == 1 {
            self.window[0] = b'\n';
        }
        self.window.extend_from_slice(text);
        self.search()
    }

    /// The output from here on starts inside a sequence: a wait that starts while the session's
    /// parser is mid-sequence (a colour, a title, a kitty image's base64), whose rest is no text.
    /// `open` is the sequence so far, as the parser continuation has it, so the stripper picks up
    /// where the parser is: the rest of a CSI ends at its final byte, of a string at its BEL or ST.
    /// With none (a string too long for the parser to keep), bytes are dropped until one that ends
    /// or starts a sequence or a line: ESC, BEL, CAN, SUB or `\n`, which is kept, as a line's end.
    /// One that is no sequence (a character's first bytes) leaves the stripper at ground, where
    /// the character's rest is text. Either way the text after starts mid-line, as far as is
    /// known, so `^` doesn't match there.
    pub fn resync(&mut self, open: &[u8]) {
        self.strip = Stripper::Ground;
        if open.is_empty() {
            self.strip = Stripper::Resync;
        } else if open.first() == Some(&ESC) {
            self.strip.strip(open, &mut Vec::new());
        }
        if self.window.len() == 1 {
            self.window[0] = NOT_A_LINE_START;
        }
    }

    /// Takes what the reader queued: the screen first, then the output, a chunk at a time, each
    /// freed and its size handed to `matched` once it is in the window, so the window grows by a
    /// chunk at most before it is trimmed. What follows a dropped read (`Queue::lagged`) is never
    /// queued, so all of this is contiguous with what came before.
    fn take(&mut self, queue: Queue, mut matched: impl FnMut(usize)) -> Option<Vec<u8>> {
        if let Some(screen) = queue.screen
            && let Some(found) = self.feed_plain(&screen)
        {
            return Some(found);
        }
        for chunk in queue.chunks {
            let found = self.feed(&chunk);
            matched(chunk.len());
            if found.is_some() {
                return found;
            }
        }
        None
    }

    fn search(&mut self) -> Option<Vec<u8>> {
        // From after the byte that says what came before, which `^` looks at but no match takes.
        if let Some(found) = self.regex.find_at(&self.window, 1) {
            return Some(found.as_bytes().to_vec());
        }
        self.trim();
        None
    }

    /// Drops the oldest text past `WINDOW`, from the start of a line when one begins in the last
    /// `WINDOW` bytes, so `^` still means a line's start; cut anywhere else, the text left starts
    /// mid-line, and its first byte says so.
    fn trim(&mut self) {
        let Some(excess) = (self.window.len() - 1).checked_sub(WINDOW) else {
            return;
        };
        let from = 1 + excess;
        let cut = self.window[from..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(from, |at| from + at + 1);
        self.window[0] = match self.window[cut - 1] {
            line_end @ (b'\n' | b'\r') => line_end,
            _ => NOT_A_LINE_START,
        };
        self.window.drain(1..cut);
    }

    #[cfg(test)]
    fn window_len(&self) -> usize {
        self.window.len() - 1
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
