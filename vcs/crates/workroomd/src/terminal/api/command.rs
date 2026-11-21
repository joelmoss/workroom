//! `terminal.command` (#691): runs one shell command in a session and answers with its exit code
//! and what it printed, once the shell's OSC 133 marks say it has ended. Answered on its own
//! stream by a thread of its own, as `terminal.wait` is, so the connection goes on reading
//! meanwhile.
//!
//! **Typed as `terminal.send` types** (`send::type_into`): the command as text, as a bracketed
//! paste when the shell has turned that on, then Enter as a key, outside the paste, which is what
//! runs it. A paste makes the line the shell's to run as given: a Tab in it completes nothing, and
//! nothing in it is read as a line editor's key. A command is one line, so a line end or any other
//! control character in it is refused, in every mode, rather than typed as keys when paste is off.
//! The typing is told as `session.input`, as every send is.
//!
//! **Paired with its own marks, race-free.** Its wait is added to the session, under the locks
//! every read holds, before anything is typed, and it counts commands from there
//! (`Waiter::begin`): the first command the shell ends after it is the one it typed. That holds
//! because a session whose shell has a command open (a C with no D since) is refused as `Busy`
//! under those locks, as is one with another `terminal.command` on it, and one with a full-screen
//! program up as `AlternateScreen`: whatever ends first is then the command typed. A prompt whose
//! input already holds text, or goes on at PS2, is `Busy` too (`Shadow::input_typed`), since the
//! command would be joined to it. Its exit code is that command's D's, as `terminal.wait`'s
//! `command_finished` reads it (null when a prompt ended it with no D: `exec zsh`), and its output
//! the bytes between its C and that end (`wait::transcript`). A full-screen program it opens ends
//! the wait as `AlternateScreen`, the program left running.
//!
//! **Without shell integration** a session's command can't be seen to end: one whose shell has
//! sent no mark is `NoShellIntegration` at once, and one younger than the marks' grace
//! (`wait::LIMITS.marks_grace`) waits for its first mark before anything is typed, so a session
//! that turns out to have none is refused with nothing run in it.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::wait::{self, Waits};
use super::{ApiError, Call, caller_schema, kind, listed, resolve, send};
use crate::daemon::rpc::SharedWriter;
use crate::terminal::keys::Key;
use crate::terminal::session::{SessionId, SessionStore};
use crate::terminal::wait::{Met, Outcome, Waiter, transcript};

pub const NAME: &str = "terminal.command";

pub const ERRORS: &[&str] = &[
    kind::TARGET_NOT_FOUND,
    kind::TARGET_AMBIGUOUS,
    kind::TOO_LARGE,
    kind::REFUSED_SELF,
    kind::NO_SHELL_INTEGRATION,
    kind::ALTERNATE_SCREEN,
    kind::BUSY,
    kind::WAIT_TIMEOUT,
    // The CLI's, `workroom command` and `api call` alike, for a hand-off mid-command: the
    // daemon never sends it.
    kind::WAIT_INTERRUPTED,
    kind::SESSION_ENDED,
    kind::INTERNAL_ERROR,
];

/// How often a young session is looked at for its shell's first mark, before anything is typed.
const MARKS_POLL: Duration = Duration::from_millis(50);

pub fn input() -> Value {
    json!({
        "type": "object",
        "required": ["target", "command"],
        "properties": {
            "target": {
                "type": "string",
                "description": "The session, as `session.resolve` takes it: its shell runs the \
                                command.",
            },
            "command": {
                "type": "string",
                "description": "One line for the session's shell to run, typed at its prompt \
                                (as a bracketed paste when the shell has turned that on) and \
                                Enter pressed. Not empty, and no control characters: a line end \
                                is refused, so join commands with `;` or `&&`. At most 1 MiB.",
            },
            "allow_self": {
                "type": "boolean",
                "default": false,
                "description": "Run it in the caller's own session, which is otherwise refused \
                                with `RefusedSelf`.",
            },
            "vt": {
                "type": "boolean",
                "default": false,
                "description": "`output` as the command printed it, escape codes and all, \
                                rather than read back as a screen: the bytes between its marks, \
                                bounded as the text is.",
            },
            "timeout_ms": {
                "type": "integer",
                "minimum": 0,
                "description": "Fail with `WaitTimeout` after this many milliseconds, leaving \
                                the command running; no limit when left out.",
            },
        },
    })
}

pub fn output() -> Value {
    json!({
        "type": "object",
        "required": ["session", "caller", "exit_code", "output", "truncated"],
        "properties": {
            "session": {"type": "string", "description": "The id of the session it ran in."},
            "caller": caller_schema(),
            "exit_code": {
                "type": ["integer", "null"],
                "description": "The command's exit code, as its shell's command-end mark (OSC \
                                133 D) gave it; null when it gave none, or when a prompt ended \
                                it with no D (`exec zsh`: a shell that replaced the one that \
                                ran it).",
            },
            "output": {
                "type": "string",
                "description": "What the command printed, between its shell's OSC 133 marks: not \
                                the command line the shell echoed, nor the prompt after it. As \
                                `terminal.capture` reads a screen with `unwrap`: plain text, a \
                                line the pane wrapped one line, a line redrawn as it last \
                                stood, trailing blanks trimmed and no final newline; with `vt`, \
                                the bytes as printed. zsh's PROMPT_SP mark (`%` after output \
                                with no final newline) is the shell's, and is left out. Its \
                                last 1 MiB, from a line's start.",
            },
            "truncated": {
                "type": "boolean",
                "description": "Whether the command printed more than `output` holds, which is \
                                then its end.",
            },
        },
    })
}

pub fn params_example() -> Value {
    json!({"target": "tests", "command": "npm test", "timeout_ms": 600_000})
}

pub fn result_example() -> Value {
    json!({
        "session": "c0ffee00-1111-4222-8333-44445555beef",
        "caller": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
        "exit_code": 1,
        "output": "> test\n> vitest run\n\n FAIL  src/login.test.ts > logs in\n\n Tests  1 failed | 41 passed (42)",
        "truncated": false,
    })
}

/// What one command asks for.
struct Asked {
    target: String,
    command: String,
    allow_self: bool,
    /// The output as printed, not read back as a screen.
    vt: bool,
    /// None: no limit.
    deadline: Option<Instant>,
}

/// `params`, or why they are refused.
fn asked(params: &Value) -> Result<Asked, ApiError> {
    let target = params
        .get("target")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid(format!("{NAME} needs a string `target`")))?
        .to_string();
    let command = params
        .get("command")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid(format!("{NAME} needs a string `command`")))?
        .to_string();
    if command.trim().is_empty() {
        return Err(ApiError::invalid(format!(
            "{NAME} has nothing to run: its `command` is empty"
        )));
    }
    if let Some(control) = command.chars().find(|c| c.is_control()) {
        return Err(ApiError::invalid(format!(
            "a command is one line of text, and this one holds a control character (U+{:04X}); \
             join commands with `;` or `&&`",
            u32::from(control)
        )));
    }
    if command.len() > send::MAX_BYTES {
        return Err(send::too_large(command.len()));
    }
    let flag = |name: &str| match params.get(name) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(on)) => Ok(*on),
        Some(_) => Err(ApiError::invalid(format!("`{name}` is a boolean"))),
    };
    let (allow_self, vt) = (flag("allow_self")?, flag("vt")?);
    let deadline = match params.get("timeout_ms") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let millis = value
                .as_u64()
                .ok_or_else(|| ApiError::invalid("`timeout_ms` is a whole number, 0 or more"))?;
            // Past what an `Instant` holds is no limit.
            Instant::now().checked_add(Duration::from_millis(millis))
        }
    };
    Ok(Asked {
        target,
        command,
        allow_self,
        vt,
        deadline,
    })
}

/// Starts the command `call` asks for, answering on `stream` now when it is refused, else from its
/// own thread once the command has ended. It holds one of the connection's and the daemon's waits
/// (`wait::admit`) and one of its session's, which a connection that closes cancels.
pub fn start(waits: &mut Waits, call: &Call, writer: &SharedWriter, stream: u32) {
    let send = {
        let writer = Arc::clone(writer);
        move |result: Result<Value, ApiError>| {
            super::send(&writer, stream, super::reply(result, false));
        }
    };
    let Prepared {
        asked,
        session,
        id,
        marks_by,
        slot,
    } = match prepare(waits, call) {
        Ok(prepared) => prepared,
        Err(error) => return send(Err(error)),
    };
    let waiter = Arc::new(Waiter::command());
    waits.held.push(Arc::clone(&waiter));
    let held = Arc::clone(&waiter);
    let (sessions, caller, most) = (
        call.sessions.clone(),
        call.caller.clone(),
        waits.limits.session,
    );
    let answer = send.clone();
    let spawned = (waits.spawn)(Box::new(move || {
        let _slot = slot;
        let ran = Ran {
            sessions: &sessions,
            session: &session,
            id,
            caller: caller.as_deref(),
            waiter: &waiter,
        };
        if let Some(result) = ran.run(&asked, marks_by, most) {
            send(result);
        }
        // Over, however it ended: a refusal on this thread left no outcome, and the connection
        // counts every waiter without one as still held (`wait::admit`).
        waiter.cancel();
    }));
    if let Err(error) = spawned {
        crate::note!("terminal API: no thread for a command: {error}");
        waits.held.retain(|waiter| !Arc::ptr_eq(waiter, &held));
        answer(Err(ApiError::new(
            kind::INTERNAL_ERROR,
            format!("the daemon could not start a thread for the command: {error}"),
        )));
    }
}

/// A command checked on the connection's reader, ready for its thread.
struct Prepared {
    asked: Asked,
    /// The session the target names, in the listing's shape.
    session: Value,
    id: SessionId,
    /// When a young session's grace for its shell's first mark ends, if it has sent none yet.
    marks_by: Option<Instant>,
    /// Its place among the daemon's waits, held until its thread ends.
    slot: super::Slot,
}

/// What `start` checks on the connection's reader: the parameters, the target, the caller's own
/// session, the shell's marks, then a place under the waits' bounds, in that order, so bad input is
/// never `Busy`. The rest is the session's to say once the command's wait is added (`Ran::run`).
fn prepare(waits: &mut Waits, call: &Call) -> Result<Prepared, ApiError> {
    let asked = asked(call.params)?;
    if !cfg!(feature = "terminal-state") {
        return Err(ApiError::invalid(format!(
            "{NAME} needs the shadow terminal, which this daemon was built without \
             (terminal-state), to see a command's end"
        )));
    }
    let session = resolve(&listed(call.sessions), &asked.target)?;
    let hyphenated = session["id"].as_str().unwrap_or_default().to_string();
    send::refused_self(
        call.caller.as_deref(),
        &hyphenated,
        &asked.target,
        asked.allow_self,
    )?;
    let id = wr_protocol::terminal::parse_session_id(std::ffi::OsStr::new(&hyphenated))
        .expect("a listed session's id parses");
    let marks_by = wait::marks_by(call.sessions, id, waits.limits, &asked.target)?;
    let slot = wait::admit(waits)?;
    Ok(Prepared {
        asked,
        session,
        id,
        marks_by,
        slot,
    })
}

/// One command, on its thread.
struct Ran<'a> {
    sessions: &'a SessionStore,
    /// In the listing's shape.
    session: &'a Value,
    id: SessionId,
    caller: Option<&'a str>,
    waiter: &'a Arc<Waiter>,
}

impl Ran<'_> {
    fn hyphenated(&self) -> &str {
        self.session["id"].as_str().unwrap_or_default()
    }

    /// The command run: its shell's first mark waited for, if it is still to come; its wait added
    /// to the session; the command typed; its end waited for. The reply, or `None` when its caller
    /// has gone, and no one is there to read one.
    fn run(
        &self,
        asked: &Asked,
        marks_by: Option<Instant>,
        most: usize,
    ) -> Option<Result<Value, ApiError>> {
        if let Some(by) = marks_by
            && let Err(error) = self.first_mark(&asked.target, by, asked.deadline)
        {
            return error.map(Err);
        }
        let size = match self.add(most) {
            Ok(size) => size,
            Err(error) => return error.map(Err),
        };
        // Out of time already (`timeout_ms: 0`, or a grace that used it up): nothing is typed, so
        // no command is left running that its caller gave up on before it started.
        if asked
            .deadline
            .is_some_and(|deadline| Instant::now() >= deadline)
        {
            self.sessions.remove_waiter(self.id, self.waiter);
            return Some(Err(ApiError::new(
                kind::WAIT_TIMEOUT,
                "the command ran out of time before it was typed, and nothing was typed",
            )));
        }
        if let Err(error) = send::type_into(
            self.sessions,
            self.session,
            self.caller,
            &asked.command,
            &[Key::ENTER],
        ) {
            self.sessions.remove_waiter(self.id, self.waiter);
            return Some(Err(error));
        }
        let outcome = self.waiter.wait(asked.deadline);
        self.sessions.remove_waiter(self.id, self.waiter);
        let hyphenated = self.hyphenated();
        Some(match outcome {
            Outcome::Met(Met::CommandFinished(exit_code)) => {
                let transcript::Output { text, truncated } = self
                    .waiter
                    .take_transcript()
                    .expect("a command's wait keeps a transcript")
                    .output(size.0, size.1, asked.vt);
                Ok(json!({
                    "session": hyphenated,
                    "caller": self.caller,
                    "exit_code": exit_code,
                    "output": text,
                    "truncated": truncated,
                }))
            }
            Outcome::TimedOut => Err(ApiError::new(
                kind::WAIT_TIMEOUT,
                format!(
                    "the command ran out of time before it ended, and is still running in session \
                     {hyphenated}; `workroom capture` reads what it has printed"
                ),
            )),
            Outcome::SessionEnded => Err(ApiError::new(
                kind::SESSION_ENDED,
                format!("session {hyphenated} ended before its command did"),
            )),
            Outcome::AlternateScreen => Err(ApiError::new(
                kind::ALTERNATE_SCREEN,
                format!(
                    "the command put a full-screen program up (a pager, an editor), which is still \
                     running in session {hyphenated} and may be waiting on a person; its screen \
                     is no output to read back, so `workroom capture` reads it, and `workroom \
                     send` can quit it"
                ),
            )),
            Outcome::Cancelled => return None,
            other => Err(ApiError::new(
                kind::INTERNAL_ERROR,
                format!("the command's wait in session {hyphenated} ended as {other:?}"),
            )),
        })
    }

    /// Waits for a young session's shell to send its first mark, by `by`, the end of its grace,
    /// and `deadline`: `Ok` once it has, else the refusal, or `Err(None)` when the caller has gone.
    fn first_mark(
        &self,
        target: &str,
        by: Instant,
        deadline: Option<Instant>,
    ) -> Result<(), Option<ApiError>> {
        loop {
            let Some(shadow) = self.sessions.shadow(self.id) else {
                return Err(Some(ApiError::new(
                    kind::SESSION_ENDED,
                    format!("session {} ended before its command ran", self.hyphenated()),
                )));
            };
            if crate::util::lock_or_recover(&shadow).has_shell_marks() {
                return Ok(());
            }
            let now = Instant::now();
            if deadline.is_some_and(|deadline| now >= deadline) {
                return Err(Some(ApiError::new(
                    kind::WAIT_TIMEOUT,
                    "the command ran out of time waiting for its session's shell to show its \
                     first prompt, and nothing was typed",
                )));
            }
            if now >= by {
                return Err(Some(wait::no_shell_integration(target)));
            }
            let until = [Some(now + MARKS_POLL), Some(by), deadline]
                .into_iter()
                .flatten()
                .min()
                .expect("a poll's end");
            if self.waiter.sleep(until).is_some() {
                // Cancelled: its caller has gone.
                return Err(None);
            }
        }
    }

    /// Adds the command's wait to its session, under the locks every read holds, refusing a
    /// session that can't take a command now: past its `most` waits, with another command on it,
    /// a full-screen program up or a command open. The session's size, which its output is
    /// rendered at; `Err(None)` when the caller has gone, and nothing is to be typed.
    fn add(&self, most: usize) -> Result<(u16, u16), Option<ApiError>> {
        let hyphenated = self.hyphenated();
        // For when the marks can't say whether a command is open: read before the locks, as it
        // takes none of them.
        let shell_in_foreground = self.sessions.shell_in_foreground(self.id);
        let added = self.sessions.add_waiter(self.id, |shadow, held| {
            if held.len() >= most {
                return Err(wait::busy(held.len(), &format!("session {hyphenated}")));
            }
            if held.iter().any(|waiter| waiter.transcribes()) {
                return Err(ApiError::new(
                    kind::BUSY,
                    format!(
                        "another command is already running in session {hyphenated} through the \
                         terminal API; try again when it has ended"
                    ),
                ));
            }
            if shadow.alternate_screen() {
                return Err(ApiError::new(
                    kind::ALTERNATE_SCREEN,
                    format!(
                        "a full-screen program has session {hyphenated}'s screen, so there is no \
                         shell prompt to type a command at"
                    ),
                ));
            }
            // By its marks, or when they can't say (no prompt since a hand-off), by whether a
            // program the shell started has the terminal. Not by that alone: a shell inside the
            // shell (`ssh`, `nix-shell`) sends marks of its own, and runs its commands so.
            let open = shadow
                .command_open()
                .unwrap_or(shell_in_foreground == Some(false));
            if open {
                return Err(ApiError::new(
                    kind::BUSY,
                    format!(
                        "session {hyphenated}'s shell is running a command, so what is typed would \
                         go to it; try again when it has ended"
                    ),
                ));
            }
            // Text already at the prompt, or a line continued at PS2, would be run with the
            // command joined to it.
            if shadow.input_typed() {
                return Err(ApiError::new(
                    kind::BUSY,
                    format!(
                        "session {hyphenated}'s prompt already holds typed text, or goes on from an \
                         unfinished line (an open quote's PS2), so the command would be joined \
                         to it; try again once it is empty"
                    ),
                ));
            }
            self.waiter.begin(&shadow.seen());
            Ok(Arc::clone(self.waiter))
        });
        let ended = || {
            Some(ApiError::new(
                kind::SESSION_ENDED,
                format!("session {hyphenated} ended before its command ran"),
            ))
        };
        match (added, self.waiter.outcome()) {
            (Some(Err(error)), _) => Err(Some(error)),
            (None, _) | (Some(Ok(_)), Some(Outcome::SessionEnded)) => Err(ended()),
            // Cancelled before it was added, which left it out.
            (Some(Ok(_)), Some(_)) => {
                self.sessions.remove_waiter(self.id, self.waiter);
                Err(None)
            }
            (Some(Ok(_)), None) => Ok(self.sessions.pty_size(self.id).unwrap_or((80, 24))),
        }
    }
}
