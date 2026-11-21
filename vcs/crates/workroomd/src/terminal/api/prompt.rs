//! `terminal.prompt` (#692): gives the coding agent in a session a prompt in one step, its text as
//! a bracketed paste and then Enter, typed as `terminal.send` types (`send::type_checked`), and
//! with `wait` answers once the turn the prompt starts has ended.
//!
//! **A coding-agent session** is one whose foreground program is a known coding agent
//! ([`AGENTS`], by the exec-time name `process::executable_name` reads, which a self-renaming CLI
//! can't change), or whose program status report came from the program in its foreground now,
//! not the shell: a `done` a crashed agent left over its shell is no agent. Anything else is
//! `NotAnAgent`.
//!
//! **Ready for a prompt** is decided under the session's shadow lock, as its modes are read: an
//! agent `working` is `AgentBusy`, and so is one `blocked` on the user, whose permission or question
//! a prompt's Enter would answer, and one whose program has not turned bracketed paste on (its
//! prompt isn't up: Claude Code and Codex turn it on with their prompt), where a text of several
//! lines would be submitted a line at a time.
//!
//! **Enter goes outside the paste**, [`ENTER_PAUSE`] after it, in the same turn of the pty's input
//! (`Pty::send_then`), so nothing else typed lands between them. Inside the paste it would be one
//! more newline in the agent's input, never a submit. Codex submits on an Enter right after an
//! explicit paste, which clears its paste-burst window; Claude Code drops a bracketed paste that a
//! key follows in the same read (anthropics/claude-code#91205), so the pause lets it read the paste
//! on its own first. Just before the Enter the agent is looked at again, under the shadow's lock:
//! one that started working or waiting on the user since the paste is not sent it, and the prompt
//! is `AgentBusy` with `details` `{"typed": true, "submitted": false}`, its text left in the
//! agent's input box.
//!
//! **What is submitted.** Text already in the agent's input box (a draft the user was typing) is
//! submitted with the prompt after it: clearing it would destroy the draft. A last word that
//! starts with `@` or `$` gets a space after it ([`submitted`]), so Enter submits rather than pick
//! from the completion it opens; a bare `/name` is the agent's own command, which Enter runs as
//! its command list picks it.
//!
//! **Over ssh.** A pane running `ssh` to another machine shows the remote agent's reports, which
//! come from the `ssh` process group in its foreground. Once that agent has crashed, its last
//! report stays and `ssh` is still the foreground, so the session still counts as an agent, and a
//! prompt would go to the remote shell. Unlikely: the agent must die without its `clear`, and a
//! remote shell's prompt drops a `working` or `blocked` report (OSC 133).
//!
//! **`wait`** answers when the turn the prompt starts has ended: a `working` reported after the
//! prompt's Enter, then the first status other than `working` (`Condition::Turn`). Its wait is
//! added before anything is typed, under the locks every read holds, and held (`hold_turn`) until
//! the Enter marks it, under the shadow's lock (`mark_turn`): a `working` read before the mark (the
//! agent reading the paste, or a turn it ran on its own meanwhile) is never the prompt's, and the
//! `done` its last turn left is never taken for this one's end. An agent that has never reported a
//! status (Codex before its first turn) can't be heard to end a turn: a `wait` there is
//! `NotAnAgent`. The stream says how far it has got, each a reply in the result's
//! shape: typed (`status` null, `more`), the turn started (`status` `working`, `more`), and its end
//! (`more` false), so a caller whose daemon is handed off meanwhile knows whether to wait on for
//! the next turn or the current one, and never types the prompt again.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::send::{self, Typed};
use super::wait::{self, Waits};
use super::{ApiError, Call, caller_schema, kind, listed, resolve};
use crate::daemon::rpc::SharedWriter;
use crate::terminal::keys::{self, Key};
use crate::terminal::program_status::State;
use crate::terminal::session::{SessionId, SessionStore};
use crate::terminal::shadow::Shadow;
use crate::terminal::wait::{Condition, Met, Outcome, Turn, Waiter};

pub const NAME: &str = "terminal.prompt";

/// The coding agents known by their program's name: Claude Code and Codex, as their CLIs are
/// installed (`claude`, `codex`), natively or as a script run by its interpreter.
pub const AGENTS: [&str; 2] = ["claude", "codex"];

/// How long after its paste a prompt's Enter is written: time for the agent to read the paste on
/// its own (Claude Code drops a paste a key follows in the same read). An implementation value,
/// not contract.
pub const ENTER_PAUSE: Duration = Duration::from_millis(200);

pub const ERRORS: &[&str] = &[
    kind::TARGET_NOT_FOUND,
    kind::TARGET_AMBIGUOUS,
    kind::NOT_AN_AGENT,
    kind::AGENT_BUSY,
    kind::REFUSED_SELF,
    kind::TOO_LARGE,
    kind::SESSION_ENDED,
    kind::WAIT_TIMEOUT,
    kind::BUSY,
    kind::INTERNAL_ERROR,
];

pub fn input() -> Value {
    let flag = |description: &str| json!({"type": "boolean", "default": false, "description": description});
    json!({
        "type": "object",
        "required": ["target", "text"],
        "properties": {
            "target": {
                "type": "string",
                "description": "A session's id or id suffix, its label, or its live title.",
            },
            "text": {
                "type": "string",
                "description": "The prompt, typed as a bracketed paste and then Enter. It may \
                                not hold the paste's end (ESC [ 2 0 1 ~, or its C1 form), and is \
                                at most 1 MiB. Text already in the agent's input box is \
                                submitted with it, after it. A last word starting `@` or `$` \
                                gets a space after it, so Enter submits rather than pick a \
                                completion; a bare `/name` is the agent's own command, which \
                                Enter runs.",
            },
            "wait": flag(
                "Answer once the turn the prompt starts has ended: after a `working` reported \
                 since the prompt's Enter, the first status other than `working`, in the last \
                 reply's `status`. Earlier replies say the prompt was typed and the turn started. \
                 An agent that has never reported a status is `NotAnAgent`: its turn's end \
                 can't be heard.",
            ),
            "timeout_ms": {
                "type": "integer",
                "description": "With `wait`, fail with `WaitTimeout` after this many \
                                milliseconds, counted from the request; no limit when left out. \
                                The prompt stays typed.",
            },
            "allow_self": flag(
                "Prompt the caller's own session, which is otherwise refused with \
                 `RefusedSelf`.",
            ),
        },
    })
}

pub fn output() -> Value {
    let mut statuses: Vec<Value> = ["idle", "working", "done", "blocked", "error"]
        .iter()
        .map(|state| json!(state))
        .collect();
    statuses.push(Value::Null);
    let mut modes = send::output()["properties"]["modes"].clone();
    modes["description"] = json!("The session's modes the prompt was encoded for.");
    json!({
        "type": "object",
        "required": ["session", "caller", "bytes", "modes", "status"],
        "properties": {
            "session": {"type": "string", "description": "The id of the session prompted."},
            "caller": caller_schema(),
            "bytes": {
                "type": "integer",
                "description": "How many bytes were typed: the paste, its markers included, and \
                                Enter.",
            },
            "modes": modes,
            "status": {
                "type": ["string", "null"],
                "enum": statuses,
                "description": "Without `wait`, null. With it, null in the reply that says the \
                                prompt was typed, `working` in the one that says its turn has \
                                started, and in the last (`more` false) the status its turn ended \
                                in: `done`, `blocked`, `idle` or `error`, or null when the agent's \
                                report went (it exited).",
            },
        },
    })
}

pub fn params_example() -> Value {
    json!({
        "target": "claude",
        "text": "Run the tests and fix what fails",
        "wait": true,
        "timeout_ms": 600_000,
    })
}

pub fn result_example() -> Value {
    json!({
        "session": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
        "caller": "0b9d33c1-7a44-4e1b-8f00-6c2a1d0abeef",
        "bytes": 45,
        "modes": {"kitty_keyboard_flags": 0, "application_cursor_keys": false, "bracketed_paste": true},
        "status": "done",
    })
}

/// What one prompt asks.
struct Asked {
    target: String,
    text: String,
    wait: bool,
    /// With `wait`, when it gives up; `None`: never.
    deadline: Option<Instant>,
    allow_self: bool,
}

/// `params`, or why they are refused.
fn asked(params: &Value) -> Result<Asked, ApiError> {
    let flag = |name: &str| match params.get(name) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(on)) => Ok(*on),
        Some(_) => Err(ApiError::invalid(format!("{NAME}'s `{name}` is a boolean"))),
    };
    let target = params
        .get("target")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid(format!("{NAME} needs a string `target`")))?
        .to_string();
    let text = params
        .get("text")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid(format!("{NAME} needs a string `text`")))?
        .to_string();
    if text.trim().is_empty() {
        return Err(ApiError::invalid(format!(
            "{NAME} has nothing to prompt with: its `text` is empty"
        )));
    }
    if keys::holds_paste_end(&text) {
        return Err(ApiError::invalid(
            "the text holds a bracketed paste's end (ESC [ 2 0 1 ~, or C1's CSI 2 0 1 ~), which \
             would end the paste early and type what follows it as keys",
        ));
    }
    if text.len() > send::MAX_BYTES {
        return Err(send::too_large(text.len()));
    }
    let wait = flag("wait")?;
    let deadline = match params.get("timeout_ms") {
        None | Some(Value::Null) => None,
        Some(_) if !wait => return Err(ApiError::invalid("`timeout_ms` goes with `wait`")),
        Some(value) => {
            let millis = value
                .as_u64()
                .ok_or_else(|| ApiError::invalid("`timeout_ms` is a whole number, 0 or more"))?;
            // Past what an `Instant` holds is no limit.
            Instant::now().checked_add(Duration::from_millis(millis))
        }
    };
    if wait && !cfg!(feature = "terminal-state") {
        return Err(ApiError::invalid(format!(
            "{NAME}'s `wait` needs the shadow terminal, which this daemon was built without \
             (terminal-state), to hear the agent's program status"
        )));
    }
    Ok(Asked {
        target,
        text,
        wait,
        deadline,
        allow_self: flag("allow_self")?,
    })
}

/// Whether session `id` runs a coding agent now: its foreground program is one of [`AGENTS`],
/// or the program that sent its program status report is in the foreground still, and isn't the
/// session's interactive shell. `None` when the session has gone.
fn runs_agent(sessions: &SessionStore, id: SessionId) -> Option<bool> {
    let foreground = sessions.foreground(id)?;
    if foreground
        .name
        .as_deref()
        .is_some_and(|name| AGENTS.contains(&name))
    {
        return Some(true);
    }
    let shadow = sessions.shadow(id)?;
    // The record's sender, or with none left (the app's `seen` dropped the `done`), the run
    // that reported.
    let owner = crate::util::lock_or_recover(&shadow)
        .status()
        .and_then(|status| status.coding_agent_owner().or(status.reporting_group()));
    Some(!foreground.shell && owner.is_some() && owner == foreground.group)
}

/// Whether the agent in session `hyphenated`, as `shadow` holds it, can take a prompt now:
/// `AgentBusy` while it is working, waiting on the user, or has no prompt up (bracketed paste
/// off). A shadow that keeps no modes says nothing here: typing refuses it, as it does keys.
fn ready(shadow: &mut Shadow, hyphenated: &str) -> Result<(), ApiError> {
    let busy = |why: &str| {
        Err(ApiError::new(
            kind::AGENT_BUSY,
            format!("the coding agent in session {hyphenated} {why}; try again when it has"),
        ))
    };
    match shadow.seen().agent {
        Some(State::Working) => return busy("is working, so a prompt would interrupt it"),
        Some(State::Blocked) => {
            return busy(
                "is waiting on the user (a permission or a question), which a prompt's Enter \
                 would answer; `workroom send` types an answer as given, or answer it in its \
                 pane",
            );
        }
        _ => {}
    }
    if shadow
        .input_modes()
        .is_some_and(|modes| !modes.bracketed_paste)
    {
        return busy(
            "has not turned bracketed paste on, so its prompt isn't up (it is starting, or \
             showing a screen of its own), and a prompt of several lines would be submitted a \
             line at a time",
        );
    }
    Ok(())
}

/// The pause before a prompt's Enter: [`ENTER_PAUSE`], but for a test, which may stretch it
/// (`WORKROOMD_TEST_ENTER_PAUSE_MS`) so its stand-in agent reports between the paste and the
/// Enter however busy its machine is. Only a build with `test-support` reads it.
fn enter_pause() -> Duration {
    #[cfg(feature = "test-support")]
    if let Some(millis) = std::env::var("WORKROOMD_TEST_ENTER_PAUSE_MS")
        .ok()
        .and_then(|millis| millis.parse().ok())
    {
        return Duration::from_millis(millis);
    }
    ENTER_PAUSE
}

/// The text a prompt pastes: as given, but for a last word that starts with `@` or `$`, which
/// gets one space after it. Codex completes such a word as it is typed (`@` a file, a plugin or a
/// skill, `$` a skill or an app), and its Enter would pick the popup's first entry rather than
/// submit; Claude Code's `@` opens a file list too. With the space the word is done, and both
/// submit. Codex trims what it submits (`trim_submission`, on by default), so the space goes
/// nowhere; Claude Code's handling could not be read (its package is a native binary), and at
/// worst its model is sent one trailing space.
pub fn submitted(text: &str) -> std::borrow::Cow<'_, str> {
    let ends_open = !text.ends_with(char::is_whitespace)
        && text
            .split_whitespace()
            .last()
            .is_some_and(|word| word.starts_with(['@', '$']));
    if ends_open {
        format!("{text} ").into()
    } else {
        text.into()
    }
}

#[cfg(test)]
#[test]
fn a_last_word_that_opens_a_completion_gets_a_space() {
    for (text, want) in [
        ("look at @src/main.rs", "look at @src/main.rs "),
        ("use $deploy", "use $deploy "),
        ("@a", "@a "),
        ("fix @src/main.rs please", "fix @src/main.rs please"),
        ("look at @src/main.rs ", "look at @src/main.rs "),
        ("@a\n", "@a\n"),
        ("costs 5$", "costs 5$"),
        ("/review", "/review"),
        ("plain", "plain"),
    ] {
        assert_eq!(submitted(text), want, "{text:?}");
    }
}

/// The error for a prompt whose agent, in session `hyphenated`, went to `state` between its paste
/// and its Enter: the Enter wasn't sent, so the text is in the agent's input box, unsubmitted.
fn not_submitted(hyphenated: &str, state: State) -> ApiError {
    let why = if state == State::Working {
        "started working"
    } else {
        "began waiting on the user"
    };
    let mut error = ApiError::new(
        kind::AGENT_BUSY,
        format!(
            "the coding agent in session {hyphenated} {why} after the prompt's text was pasted, \
             so Enter was not pressed: the text is in its input box, unsubmitted"
        ),
    );
    error.details = Some(json!({"typed": true, "submitted": false}));
    error
}

/// A prompt checked, ready to type.
struct Prepared {
    asked: Asked,
    /// In the listing's shape.
    session: Value,
    id: SessionId,
}

impl Prepared {
    fn hyphenated(&self) -> &str {
        self.session["id"].as_str().unwrap_or_default()
    }

    /// The prompt typed, as a request from `caller`, refused by [`ready`] under the shadow's lock.
    /// Just before its Enter, the agent is looked at again under that lock: one that started
    /// working, or waits on the user, since the paste (by itself, or reading it) is not sent the
    /// Enter, and the text stays in its input box. Otherwise `waiter`, the prompt's turn, is marked
    /// there, so only a `working` read after it starts the prompt's turn.
    fn type_prompt(
        &self,
        sessions: &SessionStore,
        caller: Option<&str>,
        waiter: Option<&Waiter>,
    ) -> Result<Typed, ApiError> {
        let shadow = sessions.shadow(self.id);
        let hyphenated = self.hyphenated();
        let mut before_enter = || -> Result<(), ApiError> {
            // Gone: the Enter's write says so.
            let Some(shadow) = &shadow else {
                return Ok(());
            };
            let seen = crate::util::lock_or_recover(shadow).seen();
            if let Some(state @ (State::Working | State::Blocked)) = seen.agent {
                return Err(not_submitted(hyphenated, state));
            }
            if let Some(waiter) = waiter {
                waiter.mark_turn(seen.reads);
            }
            Ok(())
        };
        send::type_checked(
            sessions,
            &self.session,
            caller,
            &submitted(&self.asked.text),
            &[Key::ENTER],
            Some(send::KeysAfter {
                pause: enter_pause(),
                check: &mut before_enter,
            }),
            |shadow| ready(shadow, hyphenated),
        )
    }

    /// One reply's result: what was typed, and `status`.
    fn result(&self, caller: Option<&str>, typed: &Typed, status: Value) -> Value {
        json!({
            "session": self.hyphenated(),
            "caller": caller,
            "bytes": typed.bytes,
            "modes": send::modes_json(typed.modes),
            "status": status,
        })
    }
}

/// What every prompt checks first, in order: the parameters, the target, the caller's own
/// session, and that the session runs a coding agent.
fn prepare(call: &Call) -> Result<Prepared, ApiError> {
    let asked = asked(call.params)?;
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
    match runs_agent(call.sessions, id) {
        None => Err(ApiError::new(
            kind::SESSION_ENDED,
            format!("session {hyphenated} ended before it could be prompted"),
        )),
        Some(false) => Err(ApiError::new(
            kind::NOT_AN_AGENT,
            format!(
                "{:?} runs no coding agent: its foreground program is not one of {} and has \
                 reported no program status; `workroom send` types into any session",
                asked.target,
                AGENTS.join(" or ")
            ),
        )),
        Some(true) => Ok(Prepared { asked, session, id }),
    }
}

/// Answers the prompt `call` asks for on `stream`: typed at once, on the connection's reader, as
/// a send is; with `wait`, its turn's wait added first, then typed and waited on by a thread of
/// its own, which a connection that closes cancels, holding one of its connection's, its
/// session's and the daemon's waits (`wait::admit`).
pub fn start(waits: &mut Waits, call: &Call, writer: &SharedWriter, stream: u32) {
    let send = {
        let writer = Arc::clone(writer);
        move |result: Result<Value, ApiError>, more: bool| {
            super::send(&writer, stream, super::reply(result, more))
        }
    };
    let prepared = match prepare(call) {
        Ok(prepared) => prepared,
        Err(error) => {
            send(Err(error), false);
            return;
        }
    };
    let caller = call.caller.clone();
    if !prepared.asked.wait {
        let typed = prepared.type_prompt(call.sessions, caller.as_deref(), None);
        send(
            typed.map(|typed| prepared.result(caller.as_deref(), &typed, Value::Null)),
            false,
        );
        return;
    }
    let (waiter, slot) = match add(waits, call.sessions, &prepared) {
        Ok(added) => added,
        Err(error) => {
            send(Err(error), false);
            return;
        }
    };
    waits.held.push(Arc::clone(&waiter));
    let (id, held) = (prepared.id, Arc::clone(&waiter));
    let sessions = call.sessions.clone();
    let answer = send.clone();
    let spawned = (waits.spawn)(Box::new(move || {
        let _slot = slot;
        let last = run(&sessions, &prepared, caller.as_deref(), &waiter, &send);
        sessions.remove_waiter(prepared.id, &waiter);
        // Over, however it ended, so the connection no longer counts it among its waits.
        waiter.cancel();
        if let Some(last) = last {
            send(last, false);
        }
    }));
    if let Err(error) = spawned {
        crate::note!("terminal API: no thread for a prompt: {error}");
        call.sessions.remove_waiter(id, &held);
        held.cancel();
        waits.held.retain(|waiter| !Arc::ptr_eq(waiter, &held));
        answer(
            Err(ApiError::new(
                kind::INTERNAL_ERROR,
                format!(
                    "the daemon could not start a thread for the prompt, and typed nothing: {error}"
                ),
            )),
            false,
        );
    }
}

/// Whether a prompt in session `hyphenated`, as `shadow` holds it, can be waited on: [`ready`],
/// and the program in its foreground, process group `foreground`, has itself reported a program
/// status, or no turn of its could be heard to end: it is the run that reported
/// (`Store::reporting_group`), which its records going doesn't change (the app's `seen` drops the
/// `done` a turn left once the user has looked), or it sent the record the session reports. An
/// agent known only by its name that has never reported, or a new program since the one that did
/// (whose `done` may linger), is `NotAnAgent` for a wait.
fn waitable(
    shadow: &mut Shadow,
    hyphenated: &str,
    foreground: Option<libc::pid_t>,
) -> Result<(), ApiError> {
    let ours = |group: Option<libc::pid_t>| group.is_some() && group == foreground;
    let reported = shadow
        .status()
        .is_some_and(|status| ours(status.reporting_group()) || ours(status.coding_agent_owner()));
    if !reported {
        return Err(ApiError::new(
            kind::NOT_AN_AGENT,
            format!(
                "the coding agent in session {hyphenated} doesn't report its program status, so \
                 `wait` can't tell when its turn ends; prompt it without `wait`"
            ),
        ));
    }
    ready(shadow, hyphenated)
}

/// Adds the wait for the turn the prompt will start to its session, under the locks every read
/// holds, refusing a session past its waits or not [`waitable`]; and takes a place among the
/// connection's and the daemon's waits. The session first, as a precondition always comes before
/// `Busy`, then again as the wait is added, where it decides. The wait hears no `working` until
/// the prompt's Enter marks it (`Waiter::hold_turn`).
fn add(
    waits: &mut Waits,
    sessions: &SessionStore,
    prepared: &Prepared,
) -> Result<(Arc<Waiter>, super::Slot), ApiError> {
    let hyphenated = prepared.hyphenated();
    let ended = || {
        ApiError::new(
            kind::SESSION_ENDED,
            format!("session {hyphenated} ended before it could be prompted"),
        )
    };
    let shadow = sessions.shadow(prepared.id).ok_or_else(ended)?;
    // Read before the locks, as it takes none of them.
    let foreground = sessions.foreground(prepared.id).ok_or_else(ended)?.group;
    waitable(
        &mut crate::util::lock_or_recover(&shadow),
        hyphenated,
        foreground,
    )?;
    let slot = wait::admit(waits)?;
    let most = waits.limits.session;
    let added = sessions.add_waiter(prepared.id, |shadow, held| {
        if held.len() >= most {
            return Err(wait::busy(held.len(), &format!("session {hyphenated}")));
        }
        waitable(shadow, hyphenated, foreground)?;
        let waiter = Waiter::new(Condition::Turn(Turn::Next), shadow.seen());
        waiter.hold_turn();
        Ok(Arc::new(waiter))
    });
    match added {
        None => Err(ended()),
        Some(Err(error)) => Err(error),
        Some(Ok(waiter)) if waiter.outcome().is_some() => Err(ended()),
        Some(Ok(waiter)) => Ok((waiter, slot)),
    }
}

/// The prompt typed and its turn waited on, `send` telling each step as it is reached (typed,
/// then the turn started), each with `more`: the last reply, or `None` when the caller has gone
/// and nobody is there to read one.
fn run(
    sessions: &SessionStore,
    prepared: &Prepared,
    caller: Option<&str>,
    waiter: &Waiter,
    send: &impl Fn(Result<Value, ApiError>, bool) -> bool,
) -> Option<Result<Value, ApiError>> {
    let deadline = prepared.asked.deadline;
    let hyphenated = prepared.hyphenated();
    // Out of time already (`timeout_ms: 0`): nothing is typed, so no agent is left working on
    // a prompt its caller gave up on before it was typed.
    if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        return Some(Err(ApiError::new(
            kind::WAIT_TIMEOUT,
            "the prompt ran out of time before it was typed, and nothing was typed",
        )));
    }
    let typed = match prepared.type_prompt(sessions, caller, Some(waiter)) {
        Ok(typed) => typed,
        Err(error) => return Some(Err(error)),
    };
    if !send(Ok(prepared.result(caller, &typed, Value::Null)), true) {
        return None;
    }
    let started = waiter.turn_started_by(deadline);
    if started && !send(Ok(prepared.result(caller, &typed, json!("working"))), true) {
        return None;
    }
    Some(match waiter.wait(deadline) {
        Outcome::Met(Met::Turn(state)) => Ok(prepared.result(caller, &typed, json!(state))),
        Outcome::TimedOut => Err(ApiError::new(
            kind::WAIT_TIMEOUT,
            format!(
                "the prompt was typed into session {hyphenated}, and the turn it starts had not \
                 {} when the wait ran out of time",
                if started { "ended" } else { "started" }
            ),
        )),
        Outcome::SessionEnded => Err(ApiError::new(
            kind::SESSION_ENDED,
            format!("session {hyphenated} ended after the prompt was typed, before its turn did"),
        )),
        Outcome::Cancelled => return None,
        other => Err(ApiError::new(
            kind::INTERNAL_ERROR,
            format!("the prompt's wait in session {hyphenated} ended as {other:?}"),
        )),
    })
}
